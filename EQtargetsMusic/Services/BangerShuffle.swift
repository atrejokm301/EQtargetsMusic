//
//  BangerShuffle.swift
//  EQtargetsMusic
//
//  Pure, seeded Banger shuffle: tempo-aware graph walk with diversity guardrails.
//  Selection / order only — no beat-matching, no audio engine.
//

import Foundation

// MARK: - Seeded RNG

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xDEAD_BEEF_CAFE_BABE : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Banger algorithm

enum BangerShuffle {
    private static let danceLow: Double = 78
    private static let danceHigh: Double = 165

    /// Build a full queue order. `anchor` is first.
    /// `recentIDs` — prior openers / session history (hard-avoid when alternatives exist).
    static func orderedQueue(
        from tracks: [Track],
        anchor: Track,
        salt: UInt64,
        recentIDs: Set<UUID> = []
    ) -> [Track] {
        guard tracks.count > 1 else { return tracks }

        var rng = SplitMix64(
            seed: salt ^ UInt64(truncatingIfNeeded: tracks.count) &* 0x9E37_79B9_7F4A_7C15
        )

        let anchorID = anchor.id
        var remaining = tracks.filter { $0.id != anchorID }
        if remaining.count == tracks.count, let key = anchor.fileKey {
            remaining = tracks.filter { $0.fileKey != key }
        }

        var ordered: [Track] = [anchor]
        var lastBPM: Double? = TempoFeel.feltBPM(anchor.bpm) ?? canonicalBPM(anchor.bpm)
        var lastArtist = normalized(anchor.artist)
        var lastAlbum = normalized(anchor.album)
        var lastDuration = max(anchor.duration, 1)
        var recentArtists: [String] = [lastArtist]
        var recentAlbums: [String] = [lastAlbum]

        if lastBPM == nil {
            let known = remaining.compactMap { canonicalBPM($0.bpm) }.sorted()
            if !known.isEmpty {
                lastBPM = known[known.count / 2]
            }
        }

        let total = max(remaining.count, 1)

        while !remaining.isEmpty {
            let placed = ordered.count
            let phase = Double(placed) / Double(total + 1)
            let energyTarget = energyArcTarget(phase: phase, seedBPM: lastBPM)
            let last = ordered[ordered.count - 1]

            // External recent only for hard exclude (placed tracks already out of remaining).
            let elig = ShuffleDiversity.eligibleCandidates(
                library: remaining,
                currentID: nil,
                hardExclude: recentIDs.intersection(Set(remaining.map(\.id)))
            )
            var pool = elig.candidates
            if pool.isEmpty { pool = remaining }

            // Prefer different artist than last few when enough options.
            let artistWindow = recentArtists.suffix(ShuffleCooldownPolicy.artistCooldownCount)
            if pool.count > ShuffleCooldownPolicy.minCandidatesPreferred {
                let diversArt = pool.filter { t in
                    let art = normalized(t.artist)
                    if art == "unknown artist" { return true }
                    return !artistWindow.contains(art)
                }
                if diversArt.count >= ShuffleCooldownPolicy.minCandidatesPreferred {
                    pool = diversArt
                }
            }

            let scored: [(Track, Double)] = pool.map { candidate in
                (
                    candidate,
                    score(
                        candidate: candidate,
                        last: last,
                        lastBPM: lastBPM,
                        energyTarget: energyTarget,
                        lastArtist: lastArtist,
                        lastAlbum: lastAlbum,
                        lastDuration: lastDuration,
                        recentArtists: recentArtists,
                        recentAlbums: recentAlbums,
                        recentIDs: recentIDs,
                        rng: &rng
                    )
                )
            }

            guard let picked = ShuffleDiversity.pickWeighted(scored: scored, rng: &rng)
                    ?? pool.randomElement(using: &rng)
                    ?? remaining.first else { break }

            if let idx = remaining.firstIndex(where: { $0.id == picked.id }) {
                remaining.remove(at: idx)
            } else {
                remaining.removeFirst()
            }

            ordered.append(picked)
            if let cb = TempoFeel.feltBPM(picked.bpm) ?? canonicalBPM(picked.bpm) { lastBPM = cb }
            lastArtist = normalized(picked.artist)
            lastAlbum = normalized(picked.album)
            lastDuration = max(picked.duration, 1)
            recentArtists.append(lastArtist)
            recentAlbums.append(lastAlbum)
            if recentArtists.count > 12 {
                recentArtists.removeFirst(recentArtists.count - 12)
            }
            if recentAlbums.count > 8 {
                recentAlbums.removeFirst(recentAlbums.count - 8)
            }

            #if DEBUG
            if elig.relaxation != .none, ordered.count <= 4 {
                print("banger diversity relaxation: \(elig.relaxation.rawValue)")
            }
            #endif
        }

        return ordered
    }

    private static func score(
        candidate: Track,
        last: Track,
        lastBPM: Double?,
        energyTarget: Double,
        lastArtist: String,
        lastAlbum: String,
        lastDuration: Double,
        recentArtists: [String],
        recentAlbums: [String],
        recentIDs: Set<UUID>,
        rng: inout SplitMix64
    ) -> Double {
        var score = Double.random(in: 0 ... 12, using: &rng)

        // Worship-aware: prefer same TempoLane so adoración doesn't chain into júbilo.
        let lastLane = TempoFeel.lane(bpm: lastBPM)
        let candLane = TempoFeel.lane(for: candidate)
        if lastLane != .unknown, candLane != .unknown {
            if candLane == lastLane {
                score += 14
            } else if lastLane.neighbors.contains(candLane) {
                score += 2
            } else if lastLane.clashes(with: candLane) {
                score -= 28
            }
        }

        if let lb = TempoFeel.feltBPM(lastBPM), let cb = TempoFeel.feltBPM(candidate.bpm) {
            let d = abs(cb - lb) // absolute feel — no half/double
            score += ShuffleDiversity.cappedBPMBoost(max(0, 40 - d * 1.6), cap: 18)
            let energyFelt = TempoFeel.feltBPM(energyTarget) ?? energyTarget
            score += ShuffleDiversity.cappedBPMBoost(max(0, 18 - abs(cb - energyFelt) * 0.9), cap: 12)
            if cb + 4 < lb { score -= 4 }
            if d > 28 { score -= 10 }
        } else if candidate.hasBPM {
            score += 5
        } else {
            score += Double.random(in: 2 ... 10, using: &rng)
        }

        let art = normalized(candidate.artist)
        if art == lastArtist, art != "unknown artist" {
            score -= 40
        } else if recentArtists.suffix(5).contains(art), art != "unknown artist" {
            score -= 18
        }

        let alb = normalized(candidate.album)
        if alb == lastAlbum, alb != "unknown album" {
            score -= 16
        } else if recentAlbums.suffix(3).contains(alb), alb != "unknown album" {
            score -= 8
        }

        let dur = max(candidate.duration, 1)
        if lastDuration < 150, dur < 150 { score -= 6 }
        if lastDuration > 360, dur > 360 { score -= 4 }

        if candidate.title.caseInsensitiveCompare(last.title) == .orderedSame {
            score -= 28
        }
        if recentIDs.contains(candidate.id) {
            score -= 8
        }

        return score
    }

    static func canonicalBPM(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, raw > 20, raw < 400 else { return nil }
        var b = raw
        while b < danceLow { b *= 2 }
        while b > danceHigh { b /= 2 }
        if b * 2 <= danceHigh, abs(b * 2 - 120) < abs(b - 120) { b *= 2 }
        if b / 2 >= danceLow, abs(b / 2 - 120) < abs(b - 120) { b /= 2 }
        return b
    }

    static func tempoDistance(_ a: Double, _ b: Double) -> Double {
        [abs(a - b), abs(a * 2 - b), abs(a - b * 2), abs(a / 2 - b), abs(a - b / 2)].min() ?? abs(a - b)
    }

    private static func energyArcTarget(phase: Double, seedBPM: Double?) -> Double {
        let base = seedBPM ?? 120
        let shape: Double
        if phase < 0.55 {
            shape = (phase / 0.55) * 8
        } else {
            shape = 8 - ((phase - 0.55) / 0.45) * 12
        }
        return min(danceHigh, max(danceLow, base + shape))
    }

    static func normalized(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.isEmpty ? "unknown artist" : t
    }
}
