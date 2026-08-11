//
//  BassProcessor.swift
//  EQtargetsMusic
//
//  Independent Bass Style stage.
//  NEVER mutates Target / Fine-Tune DualEQState.
//
//  Chain position:
//    Player → Target PEQ → Fine-Tune PEQ → Bass Processor → Output
//
//  Implementation choice: **Option A — static multi-curve AVAudioUnitEQ**
//  (low-shelf + peaking). Chosen over full dynamic envelope followers because:
//  - Dual-deck crossfade already runs two EQ chains; per-deck envelope DSP
//    would cost battery/thermals on long worship tracks.
//  - Static curves still sound professional when style-shaped carefully.
//  - Zero click risk vs modulating gains on the render thread.
//  - Easy to extend later (swap UnitParams for a true dynamic AU if desired).
//

import Foundation
import AVFoundation

// MARK: - Style

/// Independent bass stage styles. Does **not** live inside Target / Fine-Tune.
enum BassStyle: String, CaseIterable, Identifiable, Codable {
    case none
    case transientPunch
    case sustainRumble
    case naturalClean

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .transientPunch: return "Transient Punch"
        case .sustainRumble: return "Sustain / Rumble"
        case .naturalClean: return "Natural Clean"
        }
    }

    /// Short chip label so all styles fit one row without horizontal scroll.
    /// `.none` is icon-only in the UI (`compactTitle` is empty).
    var compactTitle: String {
        switch self {
        case .none: return ""
        case .transientPunch: return "Punch"
        case .sustainRumble: return "Rumble"
        case .naturalClean: return "Clean"
        }
    }

    var subtitle: String {
        switch self {
        case .none: return "Bass processor off"
        case .transientPunch: return "Tight attack, controlled sub"
        case .sustainRumble: return "Deep shelf, long low end"
        case .naturalClean: return "Gentle lift, clean headroom"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "hifispeaker.slash"
        case .transientPunch: return "waveform.path"
        case .sustainRumble: return "water.waves"
        case .naturalClean: return "leaf"
        }
    }

    /// Auto-profile cutoff (Hz) applied when the user picks this style chip.
    /// Slider remains free afterward for manual override.
    /// - `none`: leave the user’s last cutoff alone (processor is bypassed).
    var recommendedCutoffHz: Double? {
        switch self {
        case .none:
            return nil
        case .transientPunch:
            // Kick / slap attack zone — slightly above deep sub so punch stays tight.
            return 85
        case .sustainRumble:
            // Deep shelf corner — sub body and long sustain.
            return 55
        case .naturalClean:
            // Gentle full-low lift, classic “hi-fi” shelf region.
            return 120
        }
    }
}

// MARK: - State

/// User-facing bass processor state. Never written into DualEQState / AutoEQ import.
struct BassProcessorState: Codable, Equatable {
    var style: BassStyle = .none
    /// 0…1 overall intensity.
    var strength: Double = 0.6
    /// Shelf / punch corner in Hz.
    var cutoff: Double = 120
    /// Explicit makeup / cut after bass stage (dB). Added on top of mild style headroom.
    var postGain: Double = 0.0

    static let flat = BassProcessorState()

    static let strengthRange: ClosedRange<Double> = 0 ... 1
    static let cutoffRange: ClosedRange<Double> = 40 ... 250
    static let postGainRange: ClosedRange<Double> = -12 ... 6

    /// Hardware bands on the post-PEQ `AVAudioUnitEQ` (shelf + peaking helpers).
    static let bandCount = 4

    /// Fully inactive → hardware unit bypass (None or zero strength).
    var isActive: Bool { style != .none && strength > 0.001 }

    /// True when cutoff still matches this style’s auto-profile (within 0.5 Hz).
    var cutoffMatchesStyleRecommendation: Bool {
        guard let rec = style.recommendedCutoffHz else { return false }
        return abs(cutoff - rec) < 0.5
    }

    mutating func sanitize() {
        strength = min(max(strength, Self.strengthRange.lowerBound), Self.strengthRange.upperBound)
        cutoff = min(max(cutoff, Self.cutoffRange.lowerBound), Self.cutoffRange.upperBound)
        postGain = min(max(postGain, Self.postGainRange.lowerBound), Self.postGainRange.upperBound)
        if BassStyle(rawValue: style.rawValue) == nil {
            style = .none
        }
    }

    func sanitized() -> BassProcessorState {
        var c = self
        c.sanitize()
        return c
    }

    /// Select a style chip: sets style and snaps cutoff to the style’s recommended Hz
    /// (unless `applyRecommendedCutoff` is false). Strength / post gain stay as the user left them.
    mutating func selectStyle(_ newStyle: BassStyle, applyRecommendedCutoff: Bool = true) {
        style = newStyle
        if applyRecommendedCutoff, let hz = newStyle.recommendedCutoffHz {
            cutoff = hz
        }
        sanitize()
    }
}

// MARK: - DSP (pure mapping — no DualEQ, no engine)

/// Pure mapping from `BassProcessorState` → AVAudioUnitEQ parameters.
/// Target / Fine-Tune paths never call this.
enum BassProcessorDSP {
    struct BandParams: Equatable {
        var filterType: AVAudioUnitEQFilterType
        var frequency: Float
        var gain: Float
        /// Bandwidth in octaves (AVAudioUnitEQ peaking / shelf shape).
        var bandwidth: Float
        var bypass: Bool
    }

    struct UnitParams: Equatable {
        var globalGain: Float
        var unitBypass: Bool
        var bands: [BandParams]
    }

    /// Map style + strength + cutoff into 4 EQ bands + post gain.
    /// - Important: never reads DualEQState.
    static func unitParams(from state: BassProcessorState, sampleRate: Double) -> UnitParams {
        let s = state.sanitized()
        let nyq = Float(max(sampleRate / 2 - 200, 1_000))
        let idle = UnitParams(
            globalGain: 0,
            unitBypass: true,
            bands: (0 ..< BassProcessorState.bandCount).map { _ in
                BandParams(filterType: .parametric, frequency: 100, gain: 0, bandwidth: 1, bypass: true)
            }
        )

        // None / zero strength → full unit bypass (effect disappears completely).
        guard s.isActive else { return idle }

        let str = Float(s.strength)
        let fc = Float(min(max(s.cutoff, 40), min(250, Double(nyq) * 0.4)))
        let post = Float(s.postGain)

        var bands: [BandParams] = idle.bands
        /// Mild automatic headroom so loud styles don't clip before the user touches Post gain.
        /// Only a few dB; user Post gain is additive.
        var styleHeadroom: Float = 0

        switch s.style {
        case .none:
            return idle

        case .transientPunch:
            // Punch: less deep sub, tighter peak around kick attack.
            // Low shelf kept modest so the hit stays controlled.
            let shelfG = 1.6 * str
            let punchG = 6.0 * str
            let punchF = max(55, min(fc * 0.68, 95))
            styleHeadroom = -1.0 * str

            bands[0] = BandParams(
                filterType: .lowShelf,
                frequency: max(45, fc * 0.80),
                gain: shelfG,
                bandwidth: 0.55,
                bypass: abs(shelfG) < 0.05
            )
            bands[1] = BandParams(
                filterType: .parametric,
                frequency: punchF,
                gain: punchG,
                bandwidth: EQBand.bandwidthOctaves(fromQ: 2.2),
                bypass: abs(punchG) < 0.05
            )
            // Soft sub cut so punch doesn't turn into boom.
            let subTrim = -1.4 * str
            bands[2] = BandParams(
                filterType: .parametric,
                frequency: max(32, min(fc * 0.32, 48)),
                gain: subTrim,
                bandwidth: EQBand.bandwidthOctaves(fromQ: 0.85),
                bypass: abs(subTrim) < 0.05
            )
            // Mild mud control above the punch zone.
            let mudG = -1.0 * str
            bands[3] = BandParams(
                filterType: .parametric,
                frequency: min(260, nyq - 100),
                gain: mudG,
                bandwidth: EQBand.bandwidthOctaves(fromQ: 1.0),
                bypass: abs(mudG) < 0.05
            )

        case .sustainRumble:
            // Long, deep shelf + sub body — “sustain” feel without a compressor.
            let shelfG = 6.8 * str
            let subG = 3.4 * str
            let bodyG = 2.0 * str
            let subF = max(30, min(fc * 0.35, 52))
            styleHeadroom = -1.8 * str

            bands[0] = BandParams(
                filterType: .lowShelf,
                frequency: fc,
                gain: shelfG,
                bandwidth: 1.15,
                bypass: abs(shelfG) < 0.05
            )
            bands[1] = BandParams(
                filterType: .parametric,
                frequency: Float(subF),
                gain: subG,
                bandwidth: EQBand.bandwidthOctaves(fromQ: 0.65),
                bypass: abs(subG) < 0.05
            )
            bands[2] = BandParams(
                filterType: .parametric,
                frequency: max(70, min(fc * 0.88, 105)),
                gain: bodyG,
                bandwidth: EQBand.bandwidthOctaves(fromQ: 0.85),
                bypass: abs(bodyG) < 0.05
            )
            // Keep upper bass from smearing midrange clarity.
            let airCut = -0.8 * str
            bands[3] = BandParams(
                filterType: .parametric,
                frequency: min(300, nyq - 100),
                gain: airCut,
                bandwidth: EQBand.bandwidthOctaves(fromQ: 0.9),
                bypass: abs(airCut) < 0.05
            )

        case .naturalClean:
            // Gentle, hi-fi lift — minimal coloration.
            let shelfG = 3.2 * str
            let bodyG = 0.9 * str
            styleHeadroom = -0.5 * str

            bands[0] = BandParams(
                filterType: .lowShelf,
                frequency: fc,
                gain: shelfG,
                bandwidth: 0.80,
                bypass: abs(shelfG) < 0.05
            )
            bands[1] = BandParams(
                filterType: .parametric,
                frequency: max(58, min(fc * 0.72, 95)),
                gain: bodyG,
                bandwidth: EQBand.bandwidthOctaves(fromQ: 0.9),
                bypass: abs(bodyG) < 0.05
            )
            // Remaining bands stay bypassed (idle defaults).
        }

        let global = post + styleHeadroom
        return UnitParams(globalGain: global, unitBypass: false, bands: bands)
    }
}
