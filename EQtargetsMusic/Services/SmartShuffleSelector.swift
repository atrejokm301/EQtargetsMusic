//
//  SmartShuffleSelector.swift
//  EQtargetsMusic
//
//  Smart Tempo Up Next — library / queue selection ONLY.
//  Picks at most one upcoming track when Up Next is empty.
//  Does not touch AVAudioEngine, crossfade, silence-skip, PEQ, or decks.
//
//  v3 (worship-aware):
//  Prefer same TempoLane (Adoración / Mid / Júbilo) so slow worship
//  does not chain into upbeat alabanza. Uses felt BPM (no half/double fold).
//

import Foundation
import os

private let smartTempoLog = Logger(subsystem: "com.eqtargets.music", category: "SmartTempo")

// MARK: - Public queue surface

@MainActor
protocol SmartShuffleQueueWriting: AnyObject {
    var currentTrack: Track? { get }
    var upNext: [Track] { get }
    var isTransitioning: Bool { get }
    var queueTrackIDs: Set<UUID> { get }
    var queueFileKeys: Set<String> { get }
    /// Tracks the user removed from Up Next — never auto-requeue these.
    var smartUpNextBannedIDs: Set<UUID> { get }
    /// User cleared/edited Up Next — don't instant-refill until they play something new.
    var smartUpNextAutoFillSuppressed: Bool { get }
    func playNext(_ track: Track)
}

// MARK: - Selector

enum SmartShuffleSelector {
    /// Keep the same UserDefaults key so existing toggle state survives rename.
    static let enabledDefaultsKey = "eqtargets.smartBPMShuffleEnabled"

    private static let recentHistoryLimit = 28
    private static let minDurationSeconds: TimeInterval = 12
    private static let topPickCount = 8
    /// Within the same lane, prefer absolute BPM within this window.
    private static let tightBPMMax: Double = 10
    private static let mediumBPMMax: Double = 18

    /// Pick a single next track, or nil if nothing usable.
    static func selectNext(
        current: Track,
        library: [Track],
        excludeIDs: Set<UUID>,
        excludeFileKeys: Set<String> = [],
        salt: UInt64 = UInt64.random(in: 1 ... .max)
    ) -> Track? {
        guard library.count > 1 else { return nil }

        let resolved = resolveFromLibrary(current, library: library)
        let currentLane = TempoFeel.lane(for: resolved)
        let currentBPM = TempoFeel.feltBPM(resolved.bpm)
        let currentArtist = normalized(resolved.artist)
        let currentAlbum = normalized(resolved.album)
        let currentTitle = resolved.title.trimmingCharacters(in: .whitespacesAndNewlines)

        var hardIDs = excludeIDs
        hardIDs.insert(resolved.id)
        hardIDs.insert(current.id)

        var hardKeys = excludeFileKeys
        if let k = resolved.fileKey { hardKeys.insert(k) }

        let base = library.filter { t in
            if hardIDs.contains(t.id) { return false }
            if let k = t.fileKey, hardKeys.contains(k) { return false }
            if t.duration > 0, t.duration < minDurationSeconds { return false }
            return true
        }
        guard !base.isEmpty else { return nil }

        let history = ShuffleHistoryStore.snapshot()
        let recentIDs = recentTrackIDRanks(history: history, limit: recentHistoryLimit)
        let recentArtists = recentArtistRanks(history: history, limit: 10)
        let recentAlbums = recentAlbumKeys(history: history, library: library, limit: 8)

        var rng = SplitMix64(
            seed: salt
                ^ UInt64(bitPattern: Int64(resolved.id.hashValue))
                &* 0x9E37_79B9_7F4A_7C15
                ^ UInt64(currentLane.rawValue)
        )

        // --- Lane-first pools (never prefer opposite energy when same-lane exists) ---
        let annotated: [(Track, TempoLane, Double?)] = base.map { t in
            (t, TempoFeel.lane(for: t), TempoFeel.feltBPM(t.bpm))
        }

        let sameLane = annotated.filter { $0.1 == currentLane && currentLane != .unknown }.map(\.0)
        let adjacent = annotated.filter {
            currentLane != .unknown && $0.1 != .unknown && currentLane.neighbors.contains($0.1)
        }.map(\.0)
        // Explicitly exclude hard clash (adoración ↔ júbilo) until last resort.
        let nonClash = annotated.filter {
            currentLane == .unknown || $0.1 == .unknown || !currentLane.clashes(with: $0.1)
        }.map(\.0)

        // Within same lane, tighten by absolute BPM when both known.
        var sameTight: [Track] = []
        var sameMedium: [Track] = []
        if let cb = currentBPM, !sameLane.isEmpty {
            for t in sameLane {
                if let d = TempoFeel.absoluteDistance(cb, t.bpm) {
                    if d <= tightBPMMax { sameTight.append(t) }
                    if d <= mediumBPMMax { sameMedium.append(t) }
                } else {
                    sameMedium.append(t) // same lane, no BPM number
                }
            }
        }

        let knownTempo = annotated.filter { $0.1 != .unknown }.map(\.0)

        let tiers: [[Track]]
        if currentLane != .unknown {
            tiers = [
                sameTight,
                sameMedium,
                sameLane,
                adjacent,
                nonClash,
                knownTempo,
                base
            ]
        } else {
            // Cold start: prefer anything with a lane/BPM, then whole library.
            tiers = [knownTempo, base]
        }

        guard let pool = tiers.first(where: { !$0.isEmpty }) else { return nil }

        let scored: [(Track, Double)] = pool.map { track in
            (
                track,
                score(
                    candidate: track,
                    currentLane: currentLane,
                    currentBPM: currentBPM,
                    currentTitle: currentTitle,
                    currentArtist: currentArtist,
                    currentAlbum: currentAlbum,
                    currentDuration: resolved.duration,
                    recentIDs: recentIDs,
                    recentArtists: recentArtists,
                    recentAlbums: recentAlbums,
                    rng: &rng
                )
            )
        }

        let pick = pickSoftmaxTopK(scored: scored, k: topPickCount, rng: &rng)
            ?? pool.randomElement(using: &rng)

        if let pick {
            let pLane = TempoFeel.lane(for: pick)
            let pb = TempoFeel.feltBPM(pick.bpm).map { String(format: "%.0f", $0) } ?? "?"
            let cb = currentBPM.map { String(format: "%.0f", $0) } ?? "?"
            smartTempoLog.info(
                "pick “\(pick.title, privacy: .public)” lane=\(pLane.title, privacy: .public) bpm=\(pb, privacy: .public) vs \(currentLane.title, privacy: .public)/\(cb, privacy: .public) pool=\(pool.count)"
            )
        }
        return pick
    }

    // MARK: Scoring

    private static func score(
        candidate: Track,
        currentLane: TempoLane,
        currentBPM: Double?,
        currentTitle: String,
        currentArtist: String,
        currentAlbum: String,
        currentDuration: TimeInterval,
        recentIDs: [UUID: Int],
        recentArtists: [String: Int],
        recentAlbums: Set<String>,
        rng: inout SplitMix64
    ) -> Double {
        var s: Double = Double.random(in: 0 ... 0.3, using: &rng)

        let candLane = TempoFeel.lane(for: candidate)
        let candBPM = TempoFeel.feltBPM(candidate.bpm)

        // --- Lane (primary for worship flow) ---
        if currentLane != .unknown, candLane != .unknown {
            if candLane == currentLane {
                s += 36
            } else if currentLane.neighbors.contains(candLane) {
                s += 8
            } else if currentLane.clashes(with: candLane) {
                s -= 40 // hard avoid adoración ↔ júbilo
            } else {
                s -= 8
            }
        } else if candLane != .unknown {
            s += 6
        }

        // --- Absolute felt BPM (secondary; no half/double) ---
        if let a = currentBPM, let b = candBPM {
            let d = abs(a - b)
            let gauss = exp(-0.5 * pow(d / 9.0, 2))
            s += 22.0 * gauss
            if d > 24 { s -= min(16, (d - 24) * 0.45) }
        } else if currentBPM != nil, candBPM == nil {
            s -= 4
        } else if candBPM != nil {
            s += 3
        }

        // --- Artist / album diversity ---
        let art = normalized(candidate.artist)
        let alb = albumKey(artist: candidate.artist, album: candidate.album)

        if art == currentArtist, art != "unknown artist" {
            s -= 20
        } else if let rank = recentArtists[art], art != "unknown artist" {
            s -= max(4, 14 - Double(rank) * 1.4)
        }

        if alb == albumKey(artistKey: currentArtist, albumKey: currentAlbum),
           currentAlbum != "unknown album" {
            s -= 9
        } else if recentAlbums.contains(alb), !alb.hasSuffix("|unknown album") {
            s -= 4
        }

        let nt = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentTitle.isEmpty, currentTitle.caseInsensitiveCompare(nt) == .orderedSame {
            s -= 16
        }

        if let rank = recentIDs[candidate.id] {
            s -= max(3, 22 - Double(rank) * 1.0)
        }

        if currentDuration > 0, candidate.duration > 0 {
            let ratio = candidate.duration / max(currentDuration, 1)
            if ratio > 0.65, ratio < 1.55 { s += 2.5 }
            else if ratio < 0.35 || ratio > 2.8 { s -= 3 }
        }

        return s
    }

    private static func pickSoftmaxTopK(
        scored: [(Track, Double)],
        k: Int,
        rng: inout SplitMix64,
        temperature: Double = 2.2
    ) -> Track? {
        guard !scored.isEmpty else { return nil }
        let sorted = scored.sorted { $0.1 > $1.1 }
        let pool = Array(sorted.prefix(min(k, sorted.count)))
        if pool.count == 1 { return pool[0].0 }

        let maxS = pool.map(\.1).max() ?? 0
        let temp = max(temperature, 0.4)
        let weights = pool.map { exp(($0.1 - maxS) / temp) }
        let sum = weights.reduce(0, +)
        guard sum > 0, sum.isFinite else { return pool[0].0 }

        var r = Double.random(in: 0 ..< sum, using: &rng)
        for (i, w) in weights.enumerated() {
            r -= w
            if r <= 0 { return pool[i].0 }
        }
        return pool[0].0
    }

    // MARK: Library resolve / helpers

    static func resolveFromLibrary(_ track: Track, library: [Track]) -> Track {
        if let live = library.first(where: { $0.id == track.id }) {
            return mergeMetadata(player: track, library: live)
        }
        if let key = track.fileKey,
           let live = library.first(where: { $0.fileKey == key }) {
            return mergeMetadata(player: track, library: live)
        }
        if let live = library.first(where: {
            $0.title == track.title
                && $0.artist == track.artist
                && abs($0.duration - track.duration) < 0.75
        }) {
            return mergeMetadata(player: track, library: live)
        }
        return track
    }

    private static func mergeMetadata(player: Track, library: Track) -> Track {
        var t = player
        if library.hasBPM {
            t.bpm = library.bpm
            t.bpmChecked = true
        } else if player.hasBPM {
            t.bpm = player.bpm
            t.bpmChecked = player.bpmChecked || library.bpmChecked
        } else {
            t.bpmChecked = player.bpmChecked || library.bpmChecked
        }
        if !library.artist.isEmpty { t.artist = library.artist }
        if !library.album.isEmpty { t.album = library.album }
        if library.duration > 0 { t.duration = library.duration }
        return t
    }

    private static func recentTrackIDRanks(
        history: [ShuffleHistoryEntry],
        limit: Int
    ) -> [UUID: Int] {
        var ranks: [UUID: Int] = [:]
        var i = 0
        for e in history.suffix(max(0, limit)).reversed() {
            if ranks[e.trackID] == nil {
                ranks[e.trackID] = i
                i += 1
            }
        }
        return ranks
    }

    private static func recentArtistRanks(
        history: [ShuffleHistoryEntry],
        limit: Int
    ) -> [String: Int] {
        var ranks: [String: Int] = [:]
        var i = 0
        for e in history.suffix(max(0, limit * 2)).reversed() {
            guard let art = e.artistKey, art != "unknown artist" else { continue }
            if ranks[art] == nil {
                ranks[art] = i
                i += 1
                if i >= limit { break }
            }
        }
        return ranks
    }

    private static func recentAlbumKeys(
        history: [ShuffleHistoryEntry],
        library: [Track],
        limit: Int
    ) -> Set<String> {
        let ids = history.suffix(40).map(\.trackID)
        var keys = Set<String>()
        let byID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        for id in ids.reversed() {
            guard let t = byID[id] else { continue }
            keys.insert(albumKey(artist: t.artist, album: t.album))
            if keys.count >= limit { break }
        }
        return keys
    }

    private static func albumKey(artist: String, album: String) -> String {
        albumKey(artistKey: normalized(artist), albumKey: normalized(album))
    }

    private static func albumKey(artistKey: String, albumKey: String) -> String {
        "\(artistKey)|\(albumKey.isEmpty ? "unknown album" : albumKey)"
    }

    private static func normalized(_ raw: String) -> String {
        BangerShuffle.normalized(raw)
    }
}

// MARK: - Host

@MainActor
enum SmartShuffleHost {
    private static var lastAttemptCurrentID: UUID?
    private static var lastSuccessfulPickID: UUID?

    @discardableResult
    static func ensureAutomaticUpNextIfNeeded(
        enabled: Bool,
        queue: SmartShuffleQueueWriting,
        library: [Track]
    ) -> Bool {
        guard enabled else { return false }
        guard !queue.isTransitioning else { return false }
        guard let current = queue.currentTrack else { return false }
        // User deleted/cleared Up Next — respect that until they start a new play path.
        guard !queue.smartUpNextAutoFillSuppressed else { return false }
        guard queue.upNext.isEmpty else {
            if lastAttemptCurrentID != current.id {
                lastAttemptCurrentID = nil
            }
            return false
        }
        guard library.count > 1 else { return false }

        if lastAttemptCurrentID == current.id,
           let pickID = lastSuccessfulPickID,
           queue.queueTrackIDs.contains(pickID) {
            return false
        }

        var excludeIDs = queue.queueTrackIDs
        excludeIDs.formUnion(queue.smartUpNextBannedIDs)
        excludeIDs.insert(current.id)

        let resolved = SmartShuffleSelector.resolveFromLibrary(current, library: library)

        guard let pick = SmartShuffleSelector.selectNext(
            current: resolved,
            library: library,
            excludeIDs: excludeIDs,
            excludeFileKeys: queue.queueFileKeys
        ) else {
            lastAttemptCurrentID = current.id
            smartTempoLog.debug("no candidate for “\(current.title, privacy: .public)”")
            return false
        }

        guard pick.id != current.id else { return false }
        if let ck = current.fileKey, let pk = pick.fileKey, ck == pk { return false }
        guard !queue.upNext.contains(where: { $0.id == pick.id }) else { return false }

        let before = queue.upNext.first?.id
        queue.playNext(pick)
        let after = queue.upNext.first?.id

        lastAttemptCurrentID = current.id

        if after == pick.id {
            lastSuccessfulPickID = pick.id
            ShuffleHistoryStore.record(
                trackID: pick.id,
                artist: pick.artist,
                mode: .smartBPM
            )
            let from = TempoFeel.lane(for: resolved).title
            let to = TempoFeel.lane(for: pick).title
            smartTempoLog.info(
                "queued “\(pick.title, privacy: .public)” [\(to, privacy: .public)] after “\(current.title, privacy: .public)” [\(from, privacy: .public)]"
            )
            return true
        }
        if before == after {
            smartTempoLog.debug("playNext no-op for “\(pick.title, privacy: .public)”")
        }
        return false
    }

    static func resetSessionState() {
        lastAttemptCurrentID = nil
        lastSuccessfulPickID = nil
    }
}

extension AudioPlayerEngine: SmartShuffleQueueWriting {
    var queueTrackIDs: Set<UUID> {
        Set(queue.map(\.id))
    }

    var queueFileKeys: Set<String> {
        Set(queue.compactMap(\.fileKey))
    }
}
