//
//  CrossfadeEngine.swift
//  EQtargetsMusic
//
//  Crossfade v2 — settings + pure planning/math for dual-deck volume fades.
//  Not beat-matched AutoMix: volumes only (no time-stretch), optional BPM scale.
//
//  Goals vs v1:
//  - Honor long durations (15–60s) on long tracks instead of over-capping at 45%.
//  - Milder adaptive-BPM shortening (still helps muddy clashes).
//  - Explicit FadePlan (requested vs effective + reasons) for logs / honesty.
//  - Clean gain curves; smooth knees on long equal-power fades.
//

import Foundation

// MARK: - Fade curve

enum CrossfadeCurve: String, Codable, CaseIterable, Identifiable {
    /// Constant power — loudness stays even through the middle.
    case equalPower
    /// Softer knees — better on long overlaps (12s+).
    case smooth
    /// Straight amplitude swap (can dip in the middle).
    case linear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .equalPower: return "Equal Power"
        case .smooth: return "Smooth"
        case .linear: return "Linear"
        }
    }
}

// MARK: - Settings

/// Crossfade only (not beat-matched AutoMix). Off = 0s; otherwise 1…60 seconds.
struct CrossfadeSettings: Codable, Equatable {
    static let maxSeconds: Int = 60

    var durationSeconds: Int = 3
    /// When true, gently shorten fade if tempos clash (needs BPM on both tracks).
    var adaptiveBPM: Bool = true
    var curve: CrossfadeCurve = .equalPower
    /// Skip leading/trailing low-energy (live alabanzas: applause, room tone).
    var skipSilence: Bool = true

    var isEnabled: Bool { durationSeconds > 0 }
    var duration: TimeInterval {
        TimeInterval(max(0, min(durationSeconds, Self.maxSeconds)))
    }

    static let choices: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12,
        15, 20, 25, 30, 45, 60
    ]

    static var off: CrossfadeSettings { CrossfadeSettings(durationSeconds: 0) }

    enum CodingKeys: String, CodingKey {
        case durationSeconds, isEnabled, duration, startOffset, endOffset
        case adaptiveBPM, curve, skipSilence
    }

    init(
        durationSeconds: Int = 3,
        adaptiveBPM: Bool = true,
        curve: CrossfadeCurve = .equalPower,
        skipSilence: Bool = true
    ) {
        self.durationSeconds = max(0, min(durationSeconds, Self.maxSeconds))
        self.adaptiveBPM = adaptiveBPM
        self.curve = curve
        self.skipSilence = skipSilence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try c.decodeIfPresent(Int.self, forKey: .durationSeconds) {
            durationSeconds = max(0, min(s, Self.maxSeconds))
        } else {
            let oldDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 3
            let oldEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? (oldDuration > 0)
            if !oldEnabled || oldDuration <= 0 {
                durationSeconds = 0
            } else {
                durationSeconds = max(1, min(Self.maxSeconds, Int(oldDuration.rounded())))
            }
        }
        adaptiveBPM = try c.decodeIfPresent(Bool.self, forKey: .adaptiveBPM) ?? true
        curve = try c.decodeIfPresent(CrossfadeCurve.self, forKey: .curve) ?? .equalPower
        skipSilence = try c.decodeIfPresent(Bool.self, forKey: .skipSilence) ?? true
        let oldStart = try c.decodeIfPresent(TimeInterval.self, forKey: .startOffset) ?? 0
        let oldEnd = try c.decodeIfPresent(TimeInterval.self, forKey: .endOffset) ?? 0
        if !skipSilence, oldStart > 0 || oldEnd > 0 {
            skipSilence = true
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(adaptiveBPM, forKey: .adaptiveBPM)
        try c.encode(curve, forKey: .curve)
        try c.encode(skipSilence, forKey: .skipSilence)
    }

    func withDurationSeconds(_ seconds: Int) -> CrossfadeSettings {
        CrossfadeSettings(
            durationSeconds: seconds,
            adaptiveBPM: adaptiveBPM,
            curve: curve,
            skipSilence: skipSilence
        )
    }
}

// MARK: - Fade plan (honest requested vs effective)

struct CrossfadePlan: Equatable {
    var requested: TimeInterval
    var effective: TimeInterval
    var curve: CrossfadeCurve
    /// Human-readable caps applied (for logs / debugging).
    var notes: [String]

    var isEnabled: Bool { effective > 0.01 }

    var summary: String {
        if !isEnabled { return "off" }
        let req = Int(requested.rounded())
        let eff = String(format: "%.1f", effective)
        if abs(requested - effective) < 0.35 {
            return "\(eff)s \(curve.rawValue)"
        }
        return "\(eff)s (asked \(req)s) \(curve.rawValue)"
    }
}

// MARK: - Pure math + planner

enum CrossfadeMath {
    /// v2 caps: long fades on long tracks are allowed.
    /// Keep some body on each song so a track is never “only fade.”
    private static let outgoingFadeFraction: Double = 0.75   // was 0.45
    private static let incomingFadeFraction: Double = 0.70   // was 0.50
    private static let minFade: TimeInterval = 0.40
    private static let minBodySeconds: TimeInterval = 6.0

    /// progress 0…1 → (outgoing, incoming) mixer gains.
    static func gains(progress: Double, curve: CrossfadeCurve) -> (out: Float, inn: Float) {
        let p = min(max(progress, 0), 1)
        switch curve {
        case .equalPower:
            return (Float(cos(p * .pi / 2)), Float(sin(p * .pi / 2)))
        case .smooth:
            // Smootherstep on the equal-power angle — softer knees on long fades.
            let s = p * p * p * (p * (p * 6 - 15) + 10)
            return (Float(cos(s * .pi / 2)), Float(sin(s * .pi / 2)))
        case .linear:
            return (Float(1 - p), Float(p))
        }
    }

    static func equalPowerGains(progress: Double) -> (out: Float, inn: Float) {
        gains(progress: progress, curve: .equalPower)
    }

    /// Full plan: settings + track lengths + optional live remaining + BPMs.
    static func plan(
        settings: CrossfadeSettings,
        outgoingPlayable: TimeInterval,
        incomingPlayable: TimeInterval,
        outgoingRemaining: TimeInterval? = nil,
        outgoingBPM: Double? = nil,
        incomingBPM: Double? = nil
    ) -> CrossfadePlan {
        let requested = settings.duration
        guard settings.isEnabled, requested > 0 else {
            return CrossfadePlan(requested: 0, effective: 0, curve: settings.curve, notes: ["off"])
        }

        var fade = requested
        var notes: [String] = []

        // --- Outgoing body protection ---
        if outgoingPlayable > 0 {
            let byFraction = outgoingPlayable * outgoingFadeFraction
            // Also leave at least minBodySeconds of non-fade when the track is long enough.
            let byBody = max(0, outgoingPlayable - minBodySeconds)
            let outCap = max(minFade, min(byFraction, byBody > minFade ? byBody : byFraction))
            if fade > outCap + 0.05 {
                notes.append(String(format: "out_cap→%.1f", outCap))
            }
            fade = min(fade, outCap)
        }

        // --- Incoming: don't eat the whole next song as fade-in ---
        if incomingPlayable > 0 {
            let inCap = max(minFade, incomingPlayable * incomingFadeFraction)
            if fade > inCap + 0.05 {
                notes.append(String(format: "in_cap→%.1f", inCap))
            }
            fade = min(fade, inCap)
        }

        // --- Adaptive tempo (worship-aware: no half/double fold) ---
        // Prevents treating 70 BPM adoración as “close” to 140 BPM júbilo.
        if settings.adaptiveBPM {
            let scale = TempoFeel.crossfadeClashScale(
                outgoingBPM: outgoingBPM,
                incomingBPM: incomingBPM
            )
            if scale < 0.98 {
                let outL = TempoFeel.lane(bpm: outgoingBPM).title
                let inL = TempoFeel.lane(bpm: incomingBPM).title
                notes.append(String(format: "tempo %@→%@ ×%.2f", outL, inL, scale))
            }
            fade *= scale
        }

        // --- Live remaining (Next pressed late / natural end window) ---
        if let rem = outgoingRemaining, rem.isFinite {
            let remCap = max(0, rem - 0.08)
            if remCap < minFade {
                // Too late — caller should hard-cut.
                return CrossfadePlan(
                    requested: requested,
                    effective: 0,
                    curve: settings.curve,
                    notes: notes + [String(format: "rem_too_short(%.2f)", rem)]
                )
            }
            if fade > remCap + 0.05 {
                notes.append(String(format: "rem→%.1f", remCap))
            }
            fade = min(fade, remCap)
        }

        if fade > 0 {
            fade = max(minFade, fade)
        }

        // Curve: long equal-power → smooth knees automatically.
        var curve = settings.curve
        if curve == .equalPower, fade >= 12 {
            curve = .smooth
            notes.append("auto_smooth")
        }

        if notes.isEmpty { notes.append("full") }

        return CrossfadePlan(
            requested: requested,
            effective: fade,
            curve: curve,
            notes: notes
        )
    }

    /// Plan from live player settings (preferred entry point).
    static func planFromSettings(
        _ settings: CrossfadeSettings,
        outgoingPlayable: TimeInterval,
        incomingPlayable: TimeInterval,
        outgoingRemaining: TimeInterval? = nil,
        outgoingBPM: Double? = nil,
        incomingBPM: Double? = nil
    ) -> CrossfadePlan {
        plan(
            settings: settings,
            outgoingPlayable: outgoingPlayable,
            incomingPlayable: incomingPlayable,
            outgoingRemaining: outgoingRemaining,
            outgoingBPM: outgoingBPM,
            incomingBPM: incomingBPM
        )
    }

    /// Backward-compatible alias — prefer `EQBand.bandwidthOctaves(fromQ:)`.
    static func bandwidthOctaves(fromQ q: Double) -> Float {
        EQBand.bandwidthOctaves(fromQ: q)
    }

    // MARK: - Interrupted fade resolution

    /// Which deck should remain after a soft mid-fade abort (settings change, seek, …).
    ///
    /// During a fade, `active` is still the outgoing deck and `inactive` the incoming one
    /// until progress hits 1 and roles swap. Soft-abort must **not** leave the louder deck
    /// EQ-bypassed (that used to kill Target+Fine-Tune until force-quit).
    enum AbortWinner: Equatable {
        /// Keep playing the outgoing deck; silence incoming.
        case keepOutgoing
        /// Commit to the incoming deck (swap roles); silence outgoing.
        case commitIncoming
    }

    /// - Parameters:
    ///   - outgoingVolume / incomingVolume: deck mixer volumes at abort time.
    ///   - uiTrackIsIncoming: `true` when Now Playing already shows the next track
    ///     (normal for crossfade v2 after fade start); `nil` if unknown.
    static func abortWinner(
        outgoingVolume: Float,
        incomingVolume: Float,
        uiTrackIsIncoming: Bool?
    ) -> AbortWinner {
        if let uiIsIncoming = uiTrackIsIncoming {
            return uiIsIncoming ? .commitIncoming : .keepOutgoing
        }
        // Prefer the louder deck; tiny bias keeps equal-power midpoint on outgoing.
        if incomingVolume > outgoingVolume + 0.02 {
            return .commitIncoming
        }
        return .keepOutgoing
    }

    #if DEBUG
    /// Lightweight self-check for abort winner rules (no XCTest target yet).
    static func debugAssertAbortWinnerRules() {
        precondition(
            abortWinner(outgoingVolume: 1, incomingVolume: 0, uiTrackIsIncoming: true)
                == .commitIncoming,
            "UI already on next track must commit incoming"
        )
        precondition(
            abortWinner(outgoingVolume: 0.1, incomingVolume: 0.9, uiTrackIsIncoming: true)
                == .commitIncoming,
            "Loud incoming + UI next → commit"
        )
        precondition(
            abortWinner(outgoingVolume: 0.9, incomingVolume: 0.1, uiTrackIsIncoming: false)
                == .keepOutgoing,
            "UI still on current → keep outgoing"
        )
        precondition(
            abortWinner(outgoingVolume: 0.2, incomingVolume: 0.8, uiTrackIsIncoming: nil)
                == .commitIncoming,
            "Volume-only late fade → commit incoming"
        )
        precondition(
            abortWinner(outgoingVolume: 0.8, incomingVolume: 0.2, uiTrackIsIncoming: nil)
                == .keepOutgoing,
            "Volume-only early fade → keep outgoing"
        )
    }
    #endif

}
