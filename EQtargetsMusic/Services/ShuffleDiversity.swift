//
//  ShuffleDiversity.swift
//  EQtargetsMusic
//
//  Selection-only diversity: history, hard cooldowns, weighted top-pool pick.
//  No AVFoundation, no audio engine, no crossfade/silence-skip.
//

import Foundation

// MARK: - History

enum ShuffleModeTag: String, Codable, Equatable {
    case banger
    case smartBPM
    case standard
}

struct ShuffleHistoryEntry: Codable, Equatable {
    let trackID: UUID
    let selectedAt: Date
    let mode: ShuffleModeTag
    /// Optional artist for same-artist cooldown (never used as identity).
    let artistKey: String?
}

/// Bounded recent-selection store (session + UserDefaults). Track.ID only for identity.
enum ShuffleHistoryStore {
    private static let defaultsKey = "eqtargets.shuffleSelectionHistory.v1"
    private static let maxEntries = 80
    private static let lock = NSLock()
    private static var memory: [ShuffleHistoryEntry] = load()

    static func snapshot() -> [ShuffleHistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return memory
    }

    /// Record only after a successful selection / queue insertion.
    static func record(trackID: UUID, artist: String?, mode: ShuffleModeTag, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        appendLocked(trackID: trackID, artist: artist, mode: mode, at: date)
        persistLocked()
    }

    /// Record a full Banger order (typically excluding the anchor already playing).
    static func recordBangerOrder(_ tracks: [Track], skipFirst: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        let slice = skipFirst ? Array(tracks.dropFirst()) : tracks
        let now = Date()
        for (i, t) in slice.enumerated() {
            let at = now.addingTimeInterval(TimeInterval(i) * 0.001)
            appendLocked(trackID: t.id, artist: t.artist, mode: .banger, at: at)
        }
        persistLocked()
    }

    static func recentTrackIDs(limit: Int) -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return memory.suffix(max(0, limit)).map(\.trackID).reversed()
    }

    private static func appendLocked(trackID: UUID, artist: String?, mode: ShuffleModeTag, at date: Date) {
        let key = artist.map { BangerShuffle.normalized($0) }
        memory.append(ShuffleHistoryEntry(trackID: trackID, selectedAt: date, mode: mode, artistKey: key))
        if memory.count > maxEntries {
            memory.removeFirst(memory.count - maxEntries)
        }
    }

    private static func load() -> [ShuffleHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([ShuffleHistoryEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func persistLocked() {
        if let data = try? JSONEncoder().encode(memory) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

// MARK: - Cooldown policy

struct ShuffleCooldownPolicy {
    static func trackCooldownCount(eligibleCount: Int) -> Int {
        max(10, min(20, max(eligibleCount, 6) - 5))
    }

    static let artistCooldownCount = 3
    static let timeCooldown: TimeInterval = 60 * 60
    static let minCandidatesPreferred = 5
    static let maxSamplePool = 25
}

enum ShuffleRelaxation: String {
    case none
    case timeCooldown
    case artistCooldown
    case countCooldownOldest
}

struct ShuffleEligibility {
    let candidates: [Track]
    let relaxation: ShuffleRelaxation
}

enum ShuffleDiversity {
    /// Hard exclusions + gradual relaxation.
    /// Never includes `currentID` or IDs in `hardExclude` (queue / already placed).
    static func eligibleCandidates(
        library: [Track],
        currentID: UUID?,
        hardExclude: Set<UUID>,
        history: [ShuffleHistoryEntry] = ShuffleHistoryStore.snapshot()
    ) -> ShuffleEligibility {
        let base = library.filter { t in
            if let currentID, t.id == currentID { return false }
            if hardExclude.contains(t.id) { return false }
            return true
        }
        guard !base.isEmpty else {
            return ShuffleEligibility(candidates: [], relaxation: .none)
        }

        let eligibleN = base.count
        let trackWindow = ShuffleCooldownPolicy.trackCooldownCount(eligibleCount: eligibleN)
        let recentTrackOrder = history.map(\.trackID) // oldest → newest
        var recentTrackSet = Set(recentTrackOrder.suffix(trackWindow))
        let recentArtists = Array(history.compactMap(\.artistKey).suffix(ShuffleCooldownPolicy.artistCooldownCount))
        let timeCutoff = Date().addingTimeInterval(-ShuffleCooldownPolicy.timeCooldown)
        let recentTimeIDs = Set(history.filter { $0.selectedAt >= timeCutoff }.map(\.trackID))

        func apply(
            trackCooldown: Set<UUID>,
            applyTime: Bool,
            applyArtist: Bool
        ) -> [Track] {
            base.filter { t in
                if trackCooldown.contains(t.id) { return false }
                if applyTime,
                   recentTimeIDs.contains(t.id),
                   eligibleN > ShuffleCooldownPolicy.minCandidatesPreferred {
                    return false
                }
                if applyArtist {
                    let art = BangerShuffle.normalized(t.artist)
                    if art != "unknown artist",
                       recentArtists.contains(art),
                       eligibleN > ShuffleCooldownPolicy.minCandidatesPreferred {
                        return false
                    }
                }
                return true
            }
        }

        var pool = apply(trackCooldown: recentTrackSet, applyTime: true, applyArtist: true)
        if pool.count >= ShuffleCooldownPolicy.minCandidatesPreferred {
            return ShuffleEligibility(candidates: pool, relaxation: .none)
        }

        pool = apply(trackCooldown: recentTrackSet, applyTime: false, applyArtist: true)
        if pool.count >= ShuffleCooldownPolicy.minCandidatesPreferred {
            return ShuffleEligibility(candidates: pool, relaxation: .timeCooldown)
        }

        pool = apply(trackCooldown: recentTrackSet, applyTime: false, applyArtist: false)
        if pool.count >= ShuffleCooldownPolicy.minCandidatesPreferred {
            return ShuffleEligibility(candidates: pool, relaxation: .artistCooldown)
        }

        // Drop oldest count-based exclusions first.
        let orderedRecent = Array(recentTrackOrder.suffix(trackWindow))
        for id in orderedRecent {
            recentTrackSet.remove(id)
            pool = apply(trackCooldown: recentTrackSet, applyTime: false, applyArtist: false)
            if pool.count >= ShuffleCooldownPolicy.minCandidatesPreferred {
                return ShuffleEligibility(candidates: pool, relaxation: .countCooldownOldest)
            }
        }

        if !pool.isEmpty {
            return ShuffleEligibility(candidates: pool, relaxation: .countCooldownOldest)
        }
        return ShuffleEligibility(candidates: base, relaxation: .countCooldownOldest)
    }

    static func pickWeighted(
        scored: [(Track, Double)],
        rng: inout some RandomNumberGenerator
    ) -> Track? {
        guard !scored.isEmpty else { return nil }
        let sorted = scored.sorted { $0.1 > $1.1 }
        let n = sorted.count
        let topCount = min(
            ShuffleCooldownPolicy.maxSamplePool,
            max(ShuffleCooldownPolicy.minCandidatesPreferred, Int(ceil(Double(n) * 0.20)))
        )
        let pool = Array(sorted.prefix(min(topCount, n)))
        guard let best = pool.first else { return nil }
        if pool.count == 1 { return best.0 }

        let scores = pool.map(\.1)
        let minS = scores.min() ?? 0
        let maxS = scores.max() ?? 1
        let span = max(maxS - minS, 1e-6)
        let weights = pool.map { item -> Double in
            let norm = (item.1 - minS) / span
            return max(exp(norm / 0.85), 0.08)
        }
        let sum = weights.reduce(0, +)
        var r = Double.random(in: 0 ..< sum, using: &rng)
        for (i, w) in weights.enumerated() {
            r -= w
            if r <= 0 { return pool[i].0 }
        }
        return pool[0].0
    }

    static func cappedBPMBoost(_ raw: Double, cap: Double = 22) -> Double {
        min(max(raw, -cap), cap)
    }
}
