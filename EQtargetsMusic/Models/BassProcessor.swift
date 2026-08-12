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
//  Levels are **derived, not authored**: each style declares a shape, and
//  `BassProcessorDSP` measures the summed response to normalize every style to
//  the same net peak. See the note on `BassProcessorDSP`.
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
        case .none: return "Off"
        case .transientPunch: return "Transient Punch"
        case .sustainRumble: return "Sustain / Rumble"
        case .naturalClean: return "Natural Clean"
        }
    }

    /// Short chip label so all styles fit one row without horizontal scroll.
    var compactTitle: String {
        switch self {
        case .none: return "Off"
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
        // Reliable SF Symbols only — avoid missing names that render as a blank chip.
        case .none: return "speaker.slash.fill"
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
            // Anchors the punch peak at ~98 Hz (fc × 1.15) — the kick body /
            // attack region, well clear of the sub range the style trims.
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

// MARK: - Loudness weighting

/// ITU-R BS.1770 K-weighting — the frequency weighting used for loudness
/// measurement (LUFS). Two stages: a ~+4 dB high shelf approximating head
/// diffraction, and a 38 Hz high-pass approximating the ear's insensitivity to
/// deep sub. Used only to level-match Bass Styles; nothing here touches audio.
///
/// The high shelf reuses `EQBiquad`; the high-pass is local because `EQFilterType`
/// models only peak / shelf shapes.
private enum KWeighting {
    private static let shelfFrequency = 1_681.97
    private static let shelfGainDB = 3.999
    private static let shelfQ = 0.7071
    private static let hpFrequency = 38.13
    private static let hpQ = 0.5003

    /// RBJ high-pass magnitude, in dB.
    private static func highPassMagnitudeDB(at f: Double, sampleRate: Double) -> Double {
        let w0 = 2 * Double.pi * hpFrequency / sampleRate
        let cosW0 = cos(w0), sinW0 = sin(w0)
        let alpha = sinW0 / (2 * hpQ)
        let b0 = (1 + cosW0) / 2, b1 = -(1 + cosW0), b2 = (1 + cosW0) / 2
        let a0 = 1 + alpha, a1 = -2 * cosW0, a2 = 1 - alpha

        let w = 2 * Double.pi * f / sampleRate
        let cosW = cos(w), cos2W = cos(2 * w), sinW = sin(w), sin2W = sin(2 * w)
        let numRe = b0 + b1 * cosW + b2 * cos2W
        let numIm = -(b1 * sinW + b2 * sin2W)
        let denRe = a0 + a1 * cosW + a2 * cos2W
        let denIm = -(a1 * sinW + a2 * sin2W)
        let n2 = numRe * numRe + numIm * numIm
        let d2 = denRe * denRe + denIm * denIm
        guard d2 > 1e-30, n2 > 0 else { return 0 }
        return 10 * log10(n2 / d2)
    }

    static func magnitudeDB(at f: Double, sampleRate: Double) -> Double {
        let shelf = EQBiquad(
            type: .highShelf,
            frequency: shelfFrequency,
            gainDB: shelfGainDB,
            q: shelfQ,
            sampleRate: sampleRate
        )
        return shelf.magnitudeDB(at: f, sampleRate: sampleRate)
            + highPassMagnitudeDB(at: f, sampleRate: sampleRate)
    }

    /// Engine graph rate (see `AudioPlayerEngine.playbackSampleRate`). Weights are
    /// precomputed here; any other rate falls back to computing them per call.
    static let referenceSampleRate: Double = 48_000

    /// Analysis grid: log-spaced, 2% steps, 20 Hz → 20 kHz. Uniform spacing in
    /// log-f carries the pink (1/f) music-average measure implicitly.
    static let frequencies: [Double] = {
        var grid: [Double] = []
        var f = 20.0
        while f <= 20_000 {
            grid.append(f)
            f *= 1.02
        }
        return grid
    }()

    /// Linear-power K weights on `frequencies`, precomputed at the graph rate.
    private static let referenceWeights: [Double] = frequencies.map {
        pow(10, magnitudeDB(at: $0, sampleRate: referenceSampleRate) / 10)
    }

    static func weights(sampleRate: Double) -> [Double] {
        sampleRate == referenceSampleRate
            ? referenceWeights
            : frequencies.map { pow(10, magnitudeDB(at: $0, sampleRate: sampleRate) / 10) }
    }
}

// MARK: - DSP (pure mapping — no DualEQ, no engine)

/// Pure mapping from `BassProcessorState` → AVAudioUnitEQ parameters.
/// Target / Fine-Tune paths never call this.
///
/// **Gain staging:** styles are authored purely as *shapes*. The output level is
/// not hand-guessed per style — `unitParams` measures the authored bands and
/// derives `globalGain` so every style is **perceptually level-matched**
/// (K-weighted, see `loudnessDeltaDB`), subject to a peak ceiling for clipping
/// safety (`peakCeilingDB`). Two consequences:
/// 1. Switching style chips compares **character**, not loudness.
/// 2. Peak boost is bounded, so the stage stays clear of clipping on its own.
enum BassProcessorDSP {
    struct BandParams: Equatable {
        var filterType: AVAudioUnitEQFilterType
        var frequency: Float
        var gain: Float
        /// Bandwidth in octaves. **Peaking bands only** — `AVAudioUnitEQ` ignores
        /// this for shelf filter types (they use a fixed slope), so shelf specs
        /// carry `shelfQ` for the response math and emit a nominal value here.
        var bandwidth: Float
        var bypass: Bool
    }

    struct UnitParams: Equatable {
        var globalGain: Float
        var unitBypass: Bool
        var bands: [BandParams]
    }

    /// Authored band, carrying Q so the response math and the AU parameters come
    /// from one source of truth (bandwidth is derived, never hand-authored).
    private struct BandSpec {
        var type: EQFilterType
        var frequency: Double
        var gainDB: Double
        var q: Double
    }

    /// RBJ shelf slope S = 1 → Q = 1/√2. Matches the fixed slope `AVAudioUnitEQ`
    /// uses for shelves, so the measured response reflects what actually renders.
    private static let shelfQ = 1.0 / 2.0.squareRoot()

    /// Hard ceiling on the net *peak* boost, in dB. Only engages when a shape is
    /// so bass-heavy that loudness-neutral gain would push the peak into clipping
    /// territory — in practice Sustain / Rumble at high strength.
    ///
    /// This is the one place the two goals genuinely conflict: you cannot add
    /// bass without either raising the peak or lowering everything else. Below
    /// the ceiling we choose loudness-neutral; above it, clipping safety wins and
    /// the style goes quiet by exactly as much as it must.
    static let peakCeilingDB = 7.0

    /// Perceived loudness change the band shape produces, in dB.
    ///
    /// **Why not peak.** Peak-matching was tried first and measured wrong on
    /// device: it made Sustain / Rumble 3.8 dB quieter than Natural Clean, because
    /// normalizing a low-frequency peak to a fixed level drags the midrange —
    /// where nearly all perceived loudness lives — down with it. This integrates
    /// the gain in the energy domain, weighted by ITU-R BS.1770 K-weighting over a
    /// pink (music-average) spectrum, which is what the ear actually reports.
    private static func loudnessDeltaDB(specs: [BandSpec], sampleRate: Double) -> Double {
        let biquads = specs.map {
            EQBiquad(type: $0.type, frequency: $0.frequency, gainDB: $0.gainDB, q: $0.q, sampleRate: sampleRate)
        }
        guard !biquads.isEmpty else { return 0 }

        // Full-band sweep: the unboosted region above the bass is exactly what
        // makes the average meaningful, so it must be included.
        let grid = KWeighting.frequencies
        let weights = KWeighting.weights(sampleRate: sampleRate)
        var weightedGain = 0.0
        var weightTotal = 0.0
        for (i, f) in grid.enumerated() {
            let weight = weights[i]
            let gain = biquads.reduce(0.0) { $0 + $1.magnitudeDB(at: f, sampleRate: sampleRate) }
            weightedGain += weight * pow(10, gain / 10)
            weightTotal += weight
        }
        guard weightTotal > 0 else { return 0 }
        return 10 * log10(weightedGain / weightTotal)
    }

    /// Peak of the summed magnitude response across the bass region, in dB.
    /// Floored at 0 so a net-cut shape is never gain-compensated upward.
    private static func measuredPeakDB(specs: [BandSpec], sampleRate: Double) -> Double {
        let biquads = specs.map {
            EQBiquad(type: $0.type, frequency: $0.frequency, gainDB: $0.gainDB, q: $0.q, sampleRate: sampleRate)
        }
        guard !biquads.isEmpty else { return 0 }
        var peak = 0.0
        // Log sweep, 2% steps, 20 Hz → 1 kHz. EQ peaks here are broad; this
        // resolution is within ~0.02 dB of a fine sweep at negligible cost.
        var f = 20.0
        while f <= 1_000 {
            let sum = biquads.reduce(0.0) { $0 + $1.magnitudeDB(at: f, sampleRate: sampleRate) }
            if sum > peak { peak = sum }
            f *= 1.02
        }
        return peak
    }

    /// Map style + strength + cutoff into 4 EQ bands + post gain.
    /// - Important: never reads DualEQState.
    static func unitParams(from state: BassProcessorState, sampleRate: Double) -> UnitParams {
        let s = state.sanitized()
        let nyq = max(sampleRate / 2 - 200, 1_000)
        let idle = UnitParams(
            globalGain: 0,
            unitBypass: true,
            bands: (0 ..< BassProcessorState.bandCount).map { _ in
                BandParams(filterType: .parametric, frequency: 100, gain: 0, bandwidth: 1, bypass: true)
            }
        )

        // None / zero strength → full unit bypass (effect disappears completely).
        guard s.isActive else { return idle }

        let str = s.strength
        let fc = min(max(s.cutoff, 40), min(250, nyq * 0.4))

        let specs = bandSpecs(style: s.style, strength: str, cutoff: fc, nyquist: nyq)
        guard !specs.isEmpty else { return idle }

        // Level-match by perceived loudness, then let the clipping ceiling win if
        // the shape is too bass-heavy to stay neutral. Whichever is lower.
        let loudnessNeutral = -loudnessDeltaDB(specs: specs, sampleRate: sampleRate)
        let ceilingLimited = peakCeilingDB - measuredPeakDB(specs: specs, sampleRate: sampleRate)
        let headroom = min(loudnessNeutral, ceilingLimited)

        var bands = idle.bands
        for (i, spec) in specs.prefix(BassProcessorState.bandCount).enumerated() {
            bands[i] = BandParams(
                filterType: spec.type.avFilterType,
                frequency: Float(spec.frequency),
                gain: Float(spec.gainDB),
                // Shelves ignore bandwidth in AVAudioUnitEQ; emit a nominal value.
                bandwidth: spec.type == .peak ? EQBand.bandwidthOctaves(fromQ: spec.q) : 1.0,
                bypass: abs(spec.gainDB) < 0.05
            )
        }

        return UnitParams(
            globalGain: Float(s.postGain + headroom),
            unitBypass: false,
            bands: bands
        )
    }

    /// Style shapes. Author tone here only — never level; normalization handles that.
    private static func bandSpecs(
        style: BassStyle,
        strength str: Double,
        cutoff fc: Double,
        nyquist nyq: Double
    ) -> [BandSpec] {
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

        switch style {
        case .none:
            return []

        case .transientPunch:
            // Kick-forward and tight: the peak sits in the punch region (80–120 Hz),
            // with the deep sub pulled back so weight reads as impact, not boom.
            return [
                BandSpec(type: .lowShelf, frequency: max(45, fc * 0.60), gainDB: 1.0 * str, q: shelfQ),
                BandSpec(type: .peak, frequency: clamp(fc * 1.15, 80, 120), gainDB: 6.0 * str, q: 2.2),
                // Sub trim keeps the hit from smearing into rumble.
                BandSpec(type: .peak, frequency: clamp(fc * 0.42, 32, 50), gainDB: -2.6 * str, q: 0.70),
                // Mud control above the punch zone.
                BandSpec(type: .peak, frequency: min(250, nyq - 100), gainDB: -1.5 * str, q: 1.0),
            ]

        case .sustainRumble:
            // Long, deep shelf + sub body — “sustain” feel without a compressor.
            return [
                BandSpec(type: .lowShelf, frequency: fc, gainDB: 6.8 * str, q: shelfQ),
                BandSpec(type: .peak, frequency: clamp(fc * 0.35, 30, 52), gainDB: 3.4 * str, q: 0.65),
                BandSpec(type: .peak, frequency: clamp(fc * 0.88, 70, 105), gainDB: 2.0 * str, q: 0.85),
                // Keep upper bass from smearing midrange clarity.
                BandSpec(type: .peak, frequency: min(300, nyq - 100), gainDB: -0.8 * str, q: 0.9),
            ]

        case .naturalClean:
            // Gentle, hi-fi lift — minimal coloration, broad and even.
            return [
                BandSpec(type: .lowShelf, frequency: fc, gainDB: 3.2 * str, q: shelfQ),
                BandSpec(type: .peak, frequency: clamp(fc * 0.72, 58, 95), gainDB: 0.9 * str, q: 0.9),
            ]
        }
    }
}
