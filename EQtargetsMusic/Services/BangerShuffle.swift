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

    /// Candidates scored per position. The weighted pick only ever draws from the
    /// top ~25 (`ShuffleCooldownPolicy.maxSamplePool`), so scoring the entire
    /// remaining library was work thrown away. Bounding it is what turns the queue
    /// build from quadratic into linear.
    ///
    /// 160 chosen by measurement over 12 trials: album separation holds near the
    /// full-scan value (0.68% adjacent vs 0.50%) while a 2,000-track build drops
    /// from 8.1 s to 0.25 s. Smaller caps are faster but let album clustering
    /// creep up (1.2% at 48–96). Libraries at or below this size are still scored
    /// exhaustively, so small collections are unaffected.
    private static let candidateSampleCap = 160

    /// Per-track values that never change during a build. Recomputing these inside
    /// the scoring loop meant string folding, lowercasing, and two UserDefaults
    /// reads per candidate per position.
    private struct TrackFacts {
        let lane: TempoLane
        let artist: String
        let album: String
        let title: String
        let felt: Double?
        let duration: Double
    }

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

        // Hoisted once per build: tempo cutoffs, selection history, and every
        // per-track derived value. All of these were previously recomputed inside
        // the candidate loop, which is what made the build quadratic in practice.
        let tempoThresholds = TempoFeel.thresholds
        let history = ShuffleHistoryStore.snapshot()
        var facts: [UUID: TrackFacts] = Dictionary(minimumCapacity: tracks.count)
        for t in tracks {
            facts[t.id] = TrackFacts(
                lane: TempoFeel.lane(for: t, thresholds: tempoThresholds),
                artist: normalized(t.artist),
                album: normalizedAlbum(t.album),
                title: t.title.lowercased(),
                felt: TempoFeel.feltBPM(t.bpm),
                duration: max(t.duration, 1)
            )
        }
        let anchorFacts = facts[anchorID]

        var ordered: [Track] = [anchor]
        var lastBPM: Double? = TempoFeel.feltBPM(anchor.bpm) ?? canonicalBPM(anchor.bpm)
        var lastArtist = anchorFacts?.artist ?? normalized(anchor.artist)
        var lastTitle = anchorFacts?.title ?? anchor.title.lowercased()
        var lastAlbum = anchorFacts?.album ?? normalizedAlbum(anchor.album)
        var lastDuration = anchorFacts?.duration ?? max(anchor.duration, 1)
        var recentArtists: [String] = [lastArtist]
        var recentAlbums: [String] = [lastAlbum]

        if lastBPM == nil {
            let known = remaining.compactMap { canonicalBPM($0.bpm) }.sorted()
            if !known.isEmpty {
                lastBPM = known[known.count / 2]
            }
        }

        // Arc references are fixed for the whole build (see EnergyArc).
        let arc = makeEnergyArc(
            tempos: tracks.compactMap { facts[$0.id]?.felt },
            anchorBPM: TempoFeel.feltBPM(anchor.bpm)
        )

        let total = max(remaining.count, 1)

        while !remaining.isEmpty {
            let placed = ordered.count
            let phase = Double(placed) / Double(total + 1)
            let energyTarget = arc.target(phase: phase)
            let last = ordered[ordered.count - 1]
            let lastLane = TempoFeel.lane(bpm: lastBPM, thresholds: tempoThresholds)

            // Bounded candidate sample. Partial Fisher-Yates over `remaining`,
            // which is unordered, so this costs O(sample) rather than O(n).
            let sampleSize = min(candidateSampleCap, remaining.count)
            if remaining.count > sampleSize {
                for i in 0 ..< sampleSize {
                    let j = Int.random(in: i ..< remaining.count, using: &rng)
                    if i != j { remaining.swapAt(i, j) }
                }
            }
            let sample = Array(remaining.prefix(sampleSize))

            // `recentIDs` is already a hard exclude inside eligibleCandidates —
            // intersecting it against a freshly built Set of every remaining ID
            // was an O(n) allocation per position for no behavioural gain.
            let elig = ShuffleDiversity.eligibleCandidates(
                library: sample,
                currentID: nil,
                hardExclude: recentIDs,
                history: history
            )
            var pool = elig.candidates
            if pool.isEmpty { pool = sample }

            // Prefer different artist than last few when enough options.
            let artistWindow = recentArtists.suffix(ShuffleCooldownPolicy.artistCooldownCount)
            if pool.count > ShuffleCooldownPolicy.minCandidatesPreferred {
                let diversArt = pool.filter { t in
                    let art = facts[t.id]?.artist ?? normalized(t.artist)
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
                        candidateFacts: facts[candidate.id],
                        last: last,
                        lastBPM: lastBPM,
                        lastLane: lastLane,
                        lastTitle: lastTitle,
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

            // The pick came from `sample`, i.e. the head of `remaining`; look there
            // first and fall back to a full scan only if that assumption breaks.
            let idx = remaining.prefix(sampleSize).firstIndex(where: { $0.id == picked.id })
                ?? remaining.firstIndex(where: { $0.id == picked.id })
            if let idx {
                // Order within `remaining` is irrelevant, so swap-with-last is safe
                // and avoids an O(n) shift on every position.
                remaining.swapAt(idx, remaining.count - 1)
                remaining.removeLast()
            } else {
                remaining.removeLast()
            }

            ordered.append(picked)
            if let cb = TempoFeel.feltBPM(picked.bpm) ?? canonicalBPM(picked.bpm) { lastBPM = cb }
            let pf = facts[picked.id]
            lastArtist = pf?.artist ?? normalized(picked.artist)
            lastTitle = pf?.title ?? picked.title.lowercased()
            lastAlbum = pf?.album ?? normalizedAlbum(picked.album)
            lastDuration = pf?.duration ?? max(picked.duration, 1)
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
        candidateFacts: TrackFacts?,
        last: Track,
        lastBPM: Double?,
        lastLane: TempoLane,
        lastTitle: String,
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
        let candLane = candidateFacts?.lane ?? TempoFeel.lane(for: candidate)
        if lastLane != .unknown, candLane != .unknown {
            if candLane == lastLane {
                score += 14
            } else if lastLane.neighbors.contains(candLane) {
                score += 2
            } else if lastLane.clashes(with: candLane) {
                score -= 28
            }
        }

        if let lb = TempoFeel.feltBPM(lastBPM), let cb = candidateFacts?.felt ?? TempoFeel.feltBPM(candidate.bpm) {
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

        let art = candidateFacts?.artist ?? normalized(candidate.artist)
        if art == lastArtist, art != "unknown artist" {
            score -= 40
        } else if recentArtists.suffix(5).contains(art), art != "unknown artist" {
            score -= 18
        }

        let alb = candidateFacts?.album ?? normalizedAlbum(candidate.album)
        if alb == unknownAlbum {
            // Untagged albums are not one album. Previously `normalized()` mapped
            // them to "unknown artist" while the guard tested for "unknown album",
            // so every untagged track was penalised against every other one.
        } else if alb == lastAlbum {
            score -= 16
        } else if recentAlbums.suffix(3).contains(alb) {
            score -= 8
        }

        let dur = candidateFacts?.duration ?? max(candidate.duration, 1)
        if lastDuration < 150, dur < 150 { score -= 6 }
        if lastDuration > 360, dur > 360 { score -= 4 }

        // Precomputed lowercased titles: `caseInsensitiveCompare` is a
        // locale-aware Foundation call, far too heavy for the candidate loop.
        let candTitle = candidateFacts?.title ?? candidate.title.lowercased()
        if candTitle == lastTitle {
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

    /// Set-long energy arc: gather where the anchor sits, build toward the
    /// library's high end, then come back down to land soft.
    ///
    /// Computed **once per build** from fixed references. The previous version was
    /// passed `lastBPM`, which is reassigned every position, so its shape rode a
    /// drifting anchor and the set's profile was emergent rather than designed.
    /// Its amplitude was also ±8 BPM against libraries spanning 60–160, small
    /// enough to be invisible next to the other tempo terms.
    ///
    /// Targets come from the library's own tempo distribution rather than fixed
    /// constants, so a set never chases a tempo the library cannot supply.
    struct EnergyArc {
        /// Where the set starts — the anchor's felt tempo.
        let start: Double
        /// Build target, near the library's upper range.
        let peak: Double
        /// Landing target, near the library's lower range.
        let close: Double
        /// Phase at which the build tops out.
        let peakPhase: Double
        /// False when the library has too few tempos to shape anything honestly.
        let isShaped: Bool

        static let flat = EnergyArc(start: 120, peak: 120, close: 120, peakPhase: 0.55, isShaped: false)

        /// Smoothstep so the build and descent ease rather than kink at the peak.
        private static func ease(_ t: Double) -> Double {
            let x = min(max(t, 0), 1)
            return x * x * (3 - 2 * x)
        }

        func target(phase: Double) -> Double {
            guard isShaped else { return start }
            if phase <= peakPhase {
                let t = peakPhase <= 0 ? 1 : phase / peakPhase
                return start + (peak - start) * Self.ease(t)
            }
            let t = (phase - peakPhase) / max(1 - peakPhase, 1e-6)
            return peak + (close - peak) * Self.ease(t)
        }
    }

    /// Build the arc from the library's tempo spread and the anchor's position in it.
    private static func makeEnergyArc(tempos: [Double], anchorBPM: Double?) -> EnergyArc {
        // Too few known tempos to claim a shape — stay neutral rather than invent one.
        guard tempos.count >= 8 else {
            return EnergyArc(
                start: anchorBPM ?? 120, peak: anchorBPM ?? 120,
                close: anchorBPM ?? 120, peakPhase: 0.55, isShaped: false
            )
        }
        let sorted = tempos.sorted()
        func percentile(_ p: Double) -> Double {
            let idx = Int((Double(sorted.count - 1) * p).rounded())
            return sorted[min(max(idx, 0), sorted.count - 1)]
        }
        let peak = percentile(0.85)
        let close = percentile(0.20)
        let start = anchorBPM ?? percentile(0.50)

        // A library clustered in one tempo band has no arc to describe.
        guard peak - close >= 12 else {
            return EnergyArc(start: start, peak: start, close: start, peakPhase: 0.55, isShaped: false)
        }
        return EnergyArc(
            start: min(max(start, danceLow), danceHigh),
            peak: min(max(peak, danceLow), danceHigh),
            close: min(max(close, danceLow), danceHigh),
            peakPhase: 0.55,
            isShaped: true
        )
    }

    static let unknownAlbum = "unknown album"

    static func normalized(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.isEmpty ? "unknown artist" : t
    }

    /// Album-side counterpart of `normalized`. Separate sentinel so a missing
    /// album tag is recognisable as *absent* rather than colliding with every
    /// other untagged track under the artist placeholder.
    static func normalizedAlbum(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.isEmpty ? unknownAlbum : t
    }
}
