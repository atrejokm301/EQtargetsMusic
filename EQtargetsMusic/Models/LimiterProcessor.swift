//
//  LimiterProcessor.swift
//  EQtargetsMusic
//
//  Dynamics / limiter stage — independent of DualEQ / Bass Style.
//
//  Chain position:
//    Player → Target PEQ → Fine-Tune PEQ → Bass → Limiter → deck mixer
//
//  IMPLEMENTATION (v2 — replaces the AUDynamicsProcessor wrapper)
//  ------------------------------------------------------------------
//  The old stage was Apple's AUDynamicsProcessor with user "ratio" faked by
//  mapping onto the AU's HeadRoom parameter. That is a *compressor*: it has no
//  lookahead, so every transient overshoots the threshold before gain reduction
//  engages, and the HeadRoom curve did not correspond to any real ratio.
//
//  This is a true lookahead brickwall limiter, written as an in-process
//  AUAudioUnit (v3) so we own the render path:
//
//    • Lookahead delay line — audio is delayed while the detector runs ahead of
//      it, so gain reduction is already fully engaged when the peak arrives.
//    • Sliding-maximum peak detector over the lookahead window (monotonic
//      deque, amortised O(1)) — the gain target reflects the loudest sample
//      still to come, not the one that already passed.
//    • Soft-knee gain computer with a real N:1 ratio.
//    • Program-dependent release: the release coefficient interpolates between
//      fast and slow based on how much reduction has been *sustained*, so brief
//      transients recover quickly while loud passages release slowly. This is
//      what stops the pumping a single fixed release produces.
//    • Hard output ceiling in dBFS, enforced as part of the gain computation
//      and backed by a final clamp so the ceiling cannot be exceeded.
//
//  Stereo is **linked** — one shared gain across channels — so limiting never
//  shifts the stereo image.
//
//  Real-time safety: the render path allocates nothing, takes no blocking lock
//  (parameter hand-off uses `os_unfair_lock_trylock`, falling back to the last
//  good coefficients), and calls no Objective-C.
//

import Foundation
import AudioToolbox
import AVFoundation
import os.lock

// MARK: - State

/// User-facing limiter. Never mutates DualEQState or BassProcessorState.
struct LimiterState: Codable, Equatable, Hashable {
    /// Master enable. When false the stage passes audio through at unity.
    var isEnabled: Bool = false
    /// Absolute output ceiling in dBFS. Output never exceeds this.
    var ceilingDB: Double = -1.0
    /// Level above which gain reduction engages (dBFS). User: −30…−1.
    var thresholdDB: Double = -8
    /// Compression strength as classic ratio N:1. Values ≥ 20 display as "∞".
    var ratio: Double = 8
    /// Soft-knee width in dB centred on the threshold. 0 = hard knee.
    var kneeDB: Double = 6
    /// Attack time in milliseconds. Clamped to the lookahead window at render.
    var attackMs: Double = 3
    /// Baseline release time in milliseconds (the *fast* end of the
    /// program-dependent range; sustained reduction stretches it up to 8×).
    var releaseMs: Double = 120
    /// Lookahead window in milliseconds. Larger = more transparent, more latency.
    var lookaheadMs: Double = 3
    /// Derive makeup gain from threshold + ratio instead of using `postGainDB`.
    var autoMakeup: Bool = true
    /// Manual makeup gain after dynamics (dB). Used when `autoMakeup` is false.
    var postGainDB: Double = 0

    static let flat = LimiterState()

    static let ceilingRange: ClosedRange<Double> = -6 ... 0
    static let thresholdRange: ClosedRange<Double> = -30 ... -1
    static let ratioRange: ClosedRange<Double> = 1.5 ... 20
    static let kneeRange: ClosedRange<Double> = 0 ... 12
    static let attackMsRange: ClosedRange<Double> = 0.1 ... 50
    static let releaseMsRange: ClosedRange<Double> = 10 ... 1000
    static let lookaheadMsRange: ClosedRange<Double> = 0.5 ... 10
    static let postGainRange: ClosedRange<Double> = -12 ... 12

    /// Largest lookahead the kernel allocates for — the delay line is sized once.
    static let maxLookaheadMs: Double = 10

    /// Brickwall / near-infinite ratio threshold for UI labeling.
    static let infiniteRatioDisplay: Double = 20

    var isActive: Bool { isEnabled }

    mutating func sanitize() {
        ceilingDB = Self.clamp(ceilingDB, to: Self.ceilingRange)
        thresholdDB = Self.clamp(thresholdDB, to: Self.thresholdRange)
        ratio = Self.clamp(ratio, to: Self.ratioRange)
        kneeDB = Self.clamp(kneeDB, to: Self.kneeRange)
        attackMs = Self.clamp(attackMs, to: Self.attackMsRange)
        releaseMs = Self.clamp(releaseMs, to: Self.releaseMsRange)
        lookaheadMs = Self.clamp(lookaheadMs, to: Self.lookaheadMsRange)
        postGainDB = Self.clamp(postGainDB, to: Self.postGainRange)
        // A threshold above the ceiling can never engage — pull it under.
        if thresholdDB > ceilingDB {
            thresholdDB = Self.clamp(ceilingDB, to: Self.thresholdRange)
        }
    }

    func sanitized() -> LimiterState {
        var c = self
        c.sanitize()
        return c
    }

    /// Makeup gain actually applied, honouring `autoMakeup`.
    ///
    /// Auto mode compensates a *fraction* of the theoretical reduction at 0 dBFS
    /// rather than all of it: fully restoring peak level would make every preset
    /// audibly louder than bypass, which reads as "better" for the wrong reason.
    /// The ceiling still clamps the result, so this can never push past it.
    var effectiveMakeupDB: Double {
        guard autoMakeup else { return postGainDB }
        let s = sanitized()
        // Reduction the static curve applies to a 0 dBFS peak.
        let theoretical = (1.0 / s.ratio - 1.0) * (0 - s.thresholdDB)   // negative dB
        return Self.clamp(-theoretical * 0.6, to: 0 ... 12)
    }

    /// Compact chip / tile subtitle.
    var summaryLabel: String {
        guard isEnabled else { return "Off" }
        let ceil = String(format: "%.1f dB", ceilingDB)
        let r: String
        if ratio >= Self.infiniteRatioDisplay - 0.05 {
            r = "∞:1"
        } else {
            r = String(format: "%.1f:1", ratio)
        }
        return "\(ceil) ceiling · \(r)"
    }

    private static func clamp(_ v: Double, to range: ClosedRange<Double>) -> Double {
        min(max(v, range.lowerBound), range.upperBound)
    }

    // MARK: Codable

    // Hand-written so state persisted by the v1 limiter (threshold / ratio /
    // attack / release / postGain only) still decodes. Missing keys take the
    // v2 defaults, and v1 users are moved to manual makeup so their saved
    // postGainDB keeps its meaning instead of being silently overridden.
    private enum CodingKeys: String, CodingKey {
        case isEnabled, ceilingDB, thresholdDB, ratio, kneeDB
        case attackMs, releaseMs, lookaheadMs, autoMakeup, postGainDB
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LimiterState.flat
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled
        ceilingDB = try c.decodeIfPresent(Double.self, forKey: .ceilingDB) ?? d.ceilingDB
        thresholdDB = try c.decodeIfPresent(Double.self, forKey: .thresholdDB) ?? d.thresholdDB
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? d.ratio
        kneeDB = try c.decodeIfPresent(Double.self, forKey: .kneeDB) ?? d.kneeDB
        attackMs = try c.decodeIfPresent(Double.self, forKey: .attackMs) ?? d.attackMs
        releaseMs = try c.decodeIfPresent(Double.self, forKey: .releaseMs) ?? d.releaseMs
        lookaheadMs = try c.decodeIfPresent(Double.self, forKey: .lookaheadMs) ?? d.lookaheadMs
        postGainDB = try c.decodeIfPresent(Double.self, forKey: .postGainDB) ?? d.postGainDB
        // v1 payloads have no `autoMakeup` key but do carry a meaningful postGainDB.
        if let auto = try c.decodeIfPresent(Bool.self, forKey: .autoMakeup) {
            autoMakeup = auto
        } else {
            autoMakeup = false
        }
        sanitize()
    }
}

// MARK: - Genre presets

/// Built-in starting points. Values follow how each genre is actually mastered:
/// dense, already-limited material needs a lower threshold and a harder ratio;
/// dynamic material needs a high threshold so the stage only catches peaks.
enum LimiterGenre: String, CaseIterable, Identifiable, Codable {
    case hipHop
    case edm
    case rock
    case pop
    case podcast
    case jubilo
    case adoracion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hipHop: return "Hip-Hop / Trap"
        case .edm: return "EDM / Dance"
        case .rock: return "Rock / Metal"
        case .pop: return "Pop / R&B"
        case .podcast: return "Podcast / Spoken"
        case .jubilo: return "Alabanza de Júbilo"
        case .adoracion: return "Alabanza de Adoración"
        }
    }

    /// Short chip label for the preset grid.
    var compactTitle: String {
        switch self {
        case .hipHop: return "Hip-Hop"
        case .edm: return "EDM"
        case .rock: return "Rock"
        case .pop: return "Pop"
        case .podcast: return "Spoken"
        case .jubilo: return "Júbilo"
        case .adoracion: return "Adoración"
        }
    }

    var subtitle: String {
        switch self {
        case .hipHop: return "808 control, transients kept intact"
        case .edm: return "Loud and sustained, long glue release"
        case .rock: return "Dense mixes, wide knee for guitars"
        case .pop: return "Balanced and mostly transparent"
        case .podcast: return "Strong leveling for speech"
        case .jubilo: return "Live praise — claps, drums, full band"
        case .adoracion: return "Intimate worship — quiet stays quiet"
        }
    }

    var systemImage: String {
        switch self {
        case .hipHop: return "waveform.path.ecg"
        case .edm: return "bolt.fill"
        case .rock: return "guitars.fill"
        case .pop: return "music.note"
        case .podcast: return "mic.fill"
        case .jubilo: return "hands.clap.fill"
        case .adoracion: return "hands.and.sparkles.fill"
        }
    }

    var state: LimiterState {
        var s = LimiterState()
        s.isEnabled = true
        s.autoMakeup = true
        s.ceilingDB = -1.0
        switch self {
        case .hipHop:
            // Attack deliberately not the fastest available: letting the first
            // ~2 ms of a kick through is what keeps 808s punchy rather than flat.
            s.thresholdDB = -8; s.ratio = 12; s.kneeDB = 3
            s.attackMs = 2.0; s.releaseMs = 80; s.lookaheadMs = 3
        case .edm:
            // Already-loud masters: catch early, hold the reduction, release slow.
            s.thresholdDB = -10; s.ratio = 16; s.kneeDB = 2
            s.attackMs = 1.0; s.releaseMs = 150; s.lookaheadMs = 4
        case .rock:
            // Wide knee so dense guitar walls compress gradually, not in steps.
            s.thresholdDB = -7; s.ratio = 8; s.kneeDB = 6
            s.attackMs = 3.0; s.releaseMs = 120; s.lookaheadMs = 3
        case .pop:
            // Mostly a safety net — high threshold, gentle ratio, widest knee.
            s.thresholdDB = -6; s.ratio = 6; s.kneeDB = 8
            s.attackMs = 5.0; s.releaseMs = 100; s.lookaheadMs = 2
        case .podcast:
            // Speech: low threshold + slow release evens out delivery distance.
            s.thresholdDB = -18; s.ratio = 10; s.kneeDB = 10
            s.attackMs = 8.0; s.releaseMs = 250; s.lookaheadMs = 5
        case .jubilo:
            // Live congregational praise: claps, tambourine and snare sit on top
            // of a dense band, so this catches transients fairly quickly but
            // keeps a medium knee — hard-kneeing a live room sounds squashed.
            s.thresholdDB = -9; s.ratio = 10; s.kneeDB = 4
            s.attackMs = 2.5; s.releaseMs = 100; s.lookaheadMs = 3
        case .adoracion:
            // Worship is about the build, so the quiet passages are the point.
            // The threshold sits high on purpose — a low one would engage on
            // the intimate verses and flatten exactly what should breathe.
            // Gentlest preset here: only the swells get touched (≈4 dB at full
            // scale, under 1 dB at −6, nothing at −12).
            s.thresholdDB = -6; s.ratio = 3; s.kneeDB = 10
            s.attackMs = 10.0; s.releaseMs = 300; s.lookaheadMs = 5
        }
        s.sanitize()
        return s
    }
}

/// A saved limiter setting — either one of the built-in genres or the
/// user's own. Mirrors `EQPreset` so the store and UI stay symmetrical.
struct LimiterPreset: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var state: LimiterState
    /// True for a shipped genre preset — cannot be renamed or deleted.
    var isBuiltIn: Bool = false
    /// Set on built-ins so the UI can show the genre icon / subtitle.
    var genreRaw: String?

    var genre: LimiterGenre? {
        guard let genreRaw else { return nil }
        return LimiterGenre(rawValue: genreRaw)
    }

    var systemImage: String { genre?.systemImage ?? "slider.horizontal.3" }

    var subtitle: String { genre?.subtitle ?? state.summaryLabel }

    static var builtIns: [LimiterPreset] {
        LimiterGenre.allCases.map {
            LimiterPreset(name: $0.title, state: $0.state, isBuiltIn: true, genreRaw: $0.rawValue)
        }
    }
}

extension LimiterState {
    /// Equality on the audible parameters only, ignoring `isEnabled`.
    /// Used to show which preset chip is currently "selected".
    func matchesParameters(of other: LimiterState) -> Bool {
        let a = sanitized(), b = other.sanitized()
        func near(_ x: Double, _ y: Double, _ eps: Double = 0.005) -> Bool { abs(x - y) < eps }
        return near(a.ceilingDB, b.ceilingDB)
            && near(a.thresholdDB, b.thresholdDB)
            && near(a.ratio, b.ratio)
            && near(a.kneeDB, b.kneeDB)
            && near(a.attackMs, b.attackMs)
            && near(a.releaseMs, b.releaseMs)
            && near(a.lookaheadMs, b.lookaheadMs)
            && a.autoMakeup == b.autoMakeup
            && near(a.postGainDB, b.postGainDB)
    }
}

// MARK: - Coefficients

/// Sample-rate-resolved kernel parameters. Plain values only — this struct is
/// copied across to the render thread.
struct LimiterCoefficients: Equatable {
    var bypass: Bool = true
    var thresholdDB: Double = -8
    var ratio: Double = 8
    var kneeDB: Double = 6
    var ceilingDB: Double = -1
    var makeupDB: Double = 0
    var makeupLinear: Double = 1
    var ceilingLinear: Double = 1
    /// Per-sample one-pole coefficient for gain moving *down* (attack).
    var attackCoef: Double = 0.5
    /// Per-sample coefficient at the fast end of the release range.
    var releaseFastCoef: Double = 0.001
    /// Per-sample coefficient at the slow end (8× the fast time).
    var releaseSlowCoef: Double = 0.0001
    /// Coefficient for the very slow envelope that tracks *sustained* reduction.
    var sustainCoef: Double = 0.0002
    /// Release used while bypassed, so switching the limiter off returns to
    /// unity promptly instead of inheriting the program-dependent release
    /// (which stretches to seconds after a loud passage and makes the toggle
    /// feel broken). Still a ramp, not a jump, so it cannot click.
    var bypassReleaseCoef: Double = 0.001
    var lookaheadSamples: Int = 144

    /// Resolve a user-facing state against a sample rate.
    static func make(from state: LimiterState, sampleRate: Double) -> LimiterCoefficients {
        let s = state.sanitized()
        let sr = max(8_000, sampleRate)
        var c = LimiterCoefficients()
        c.bypass = !s.isEnabled
        c.thresholdDB = s.thresholdDB
        c.ratio = max(1.0, s.ratio)
        c.kneeDB = s.kneeDB
        c.ceilingDB = s.ceilingDB
        c.ceilingLinear = pow(10.0, s.ceilingDB / 20.0)
        c.makeupDB = s.effectiveMakeupDB
        c.makeupLinear = pow(10.0, c.makeupDB / 20.0)

        let lookaheadSamples = Int((s.lookaheadMs / 1000.0 * sr).rounded())
        c.lookaheadSamples = max(1, min(lookaheadSamples, Self.maxLookaheadSamples(sampleRate: sr)))

        // Attack must complete inside the lookahead window, otherwise the gain
        // is still travelling when the peak arrives and the ceiling relies on
        // the final clamp instead of the envelope. Clamp rather than trust UI.
        let lookaheadMs = Double(c.lookaheadSamples) / sr * 1000.0
        let attackMs = min(s.attackMs, lookaheadMs)
        c.attackCoef = Self.onePole(timeMs: attackMs, sampleRate: sr)
        c.releaseFastCoef = Self.onePole(timeMs: s.releaseMs, sampleRate: sr)
        c.releaseSlowCoef = Self.onePole(timeMs: s.releaseMs * 8.0, sampleRate: sr)
        // ~300 ms window for judging "sustained" vs "transient" reduction.
        c.sustainCoef = Self.onePole(timeMs: 300, sampleRate: sr)
        c.bypassReleaseCoef = Self.onePole(timeMs: Self.bypassReleaseMs, sampleRate: sr)
        return c
    }

    /// Ramp back to unity when the stage is switched off. Fast enough to feel
    /// immediate, slow enough that 15 dB of reduction does not pop.
    static let bypassReleaseMs: Double = 30

    static func maxLookaheadSamples(sampleRate: Double) -> Int {
        max(1, Int((LimiterState.maxLookaheadMs / 1000.0 * max(8_000, sampleRate)).rounded()))
    }

    /// One-pole coefficient reaching ~63% of the target in `timeMs`.
    static func onePole(timeMs: Double, sampleRate: Double) -> Double {
        let t = max(0.02, timeMs) / 1000.0
        let n = max(1.0, t * sampleRate)
        return 1.0 - exp(-1.0 / n)
    }
}

// MARK: - Sliding maximum

/// Monotonic-deque sliding maximum over a fixed window. Amortised O(1) per
/// sample, zero allocation after `prepare`. Used so the gain target reflects
/// the loudest sample *still inside the lookahead window*.
final class SlidingPeakDetector {
    // Raw allocations, not Swift arrays: the render thread must not risk a
    // copy-on-write check or retain/release on the hot path.
    private var values: UnsafeMutablePointer<Float>
    private var indices: UnsafeMutablePointer<Int>
    private var head = 0          // front of deque (largest value)
    private var tail = 0          // one past the back
    private var capacity: Int
    private var position = 0      // absolute sample counter
    private(set) var window = 1

    init() {
        capacity = 2
        values = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        values.initialize(repeating: 0, count: capacity)
        indices = UnsafeMutablePointer<Int>.allocate(capacity: capacity)
        indices.initialize(repeating: 0, count: capacity)
    }

    deinit {
        values.deallocate()
        indices.deallocate()
    }

    func prepare(capacity: Int) {
        values.deallocate()
        indices.deallocate()
        // +1 so the ring never wraps onto its own head at full occupancy.
        self.capacity = max(2, capacity + 1)
        values = UnsafeMutablePointer<Float>.allocate(capacity: self.capacity)
        values.initialize(repeating: 0, count: self.capacity)
        indices = UnsafeMutablePointer<Int>.allocate(capacity: self.capacity)
        indices.initialize(repeating: 0, count: self.capacity)
        window = 1
        reset()
    }

    func reset() {
        head = 0
        tail = 0
        position = 0
    }

    /// Shrinking the window must drop entries that are already out of range,
    /// otherwise a stale peak keeps the gain pinned after the user lowers
    /// lookahead. Growing needs no fixup — the deque simply fills.
    func setWindow(_ w: Int) {
        let clamped = max(1, min(w, capacity - 1))
        guard clamped != window else { return }
        window = clamped
        while head != tail, indices[head] <= position - window {
            head = (head + 1) % capacity
        }
    }

    var isEmpty: Bool { head == tail }

    /// Push one sample, return the maximum across the current window.
    @inline(__always)
    func push(_ value: Float) -> Float {
        // Drop entries that can never be the maximum again.
        var back = tail
        while head != back {
            let prev = (back - 1 + capacity) % capacity
            if values[prev] <= value {
                back = prev
            } else {
                break
            }
        }
        tail = back
        values[tail] = value
        indices[tail] = position
        tail = (tail + 1) % capacity

        // Expire the front once it leaves the window.
        while head != tail, indices[head] <= position - window {
            head = (head + 1) % capacity
        }

        position &+= 1
        return values[head]
    }
}

// MARK: - DSP core

/// Pure limiter kernel. No AVFoundation / AudioToolbox dependency so it can be
/// driven directly from tests with plain `[Float]` buffers.
///
/// Stereo (and beyond) is **linked**: one detector, one gain, applied to every
/// channel, so limiting never moves the stereo image.
final class LimiterDSPCore {

    private(set) var sampleRate: Double = 48_000
    private(set) var channelCount: Int = 2

    private var coeffs = LimiterCoefficients()
    private let detector = SlidingPeakDetector()

    /// Per-channel lookahead delay lines, sized for `LimiterState.maxLookaheadMs`.
    /// One flat allocation, channel-major: channel `ch` occupies
    /// `delay[ch * delayCapacity ..< (ch + 1) * delayCapacity]`.
    private var delay: UnsafeMutablePointer<Float>?
    private var delayCapacity = 0
    private var delayChannels = 0
    private var writeIndex = 0

    /// Node-level bypass, set independently of the coefficients (see
    /// `LimiterKernel.setBypass`). ORed with `coeffs.bypass` at render time so
    /// neither source can cancel the other out.
    var bypassOverride = false

    /// Smoothed gain reduction in dB (≤ 0).
    private var gainDB: Double = 0
    /// Slow envelope of |gain reduction|, drives the program-dependent release.
    private var sustainedGR: Double = 0

    /// True while the bypassed fast path is running, meaning the detector has
    /// not been fed and must be primed from the delay line before the full path
    /// can be trusted again. See `process`.
    private var detectorIdle = false

    /// Most recent gain reduction in dB, as a positive number, for metering.
    private(set) var gainReductionDB: Double = 0
    /// Peak output level (dBFS) observed since the last meter read.
    private(set) var outputPeakDB: Double = -120

    // MARK: Setup

    deinit {
        delay?.deallocate()
    }

    func prepare(sampleRate: Double, channelCount: Int) {
        self.sampleRate = max(8_000, sampleRate)
        self.channelCount = max(1, channelCount)
        delayCapacity = LimiterCoefficients.maxLookaheadSamples(sampleRate: self.sampleRate) + 2
        delayChannels = self.channelCount
        delay?.deallocate()
        let total = delayCapacity * delayChannels
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: total)
        buf.initialize(repeating: 0, count: total)
        delay = buf
        detector.prepare(capacity: delayCapacity)
        reset()
    }

    func reset() {
        if let delay {
            delay.update(repeating: 0, count: delayCapacity * delayChannels)
        }
        writeIndex = 0
        gainDB = 0
        sustainedGR = 0
        gainReductionDB = 0
        outputPeakDB = -120
        detectorIdle = false
        detector.reset()
    }

    func update(_ new: LimiterCoefficients) {
        coeffs = new
        detector.setWindow(max(1, min(new.lookaheadSamples, delayCapacity - 1)))
    }

    var currentCoefficients: LimiterCoefficients { coeffs }

    // MARK: Gain computer

    /// Static curve: input level (dB) → gain to apply (dB, ≤ 0).
    /// Soft knee is the standard quadratic interpolation across `kneeDB`,
    /// then a hard ceiling term guarantees the output bound.
    func staticGainDB(forInputDB inputDB: Double) -> Double {
        let c = coeffs
        let over = inputDB - c.thresholdDB
        let slope = 1.0 / c.ratio - 1.0        // ≤ 0
        var gain: Double

        if c.kneeDB > 0.0001, over > -c.kneeDB / 2, over < c.kneeDB / 2 {
            let x = over + c.kneeDB / 2
            gain = slope * x * x / (2 * c.kneeDB)
        } else if over >= c.kneeDB / 2 {
            gain = slope * over
        } else {
            gain = 0
        }

        // Enforce the ceiling *including* makeup, so makeup can never push the
        // output past it. This is what makes the stage a true brickwall.
        let projected = inputDB + gain + c.makeupDB
        if projected > c.ceilingDB {
            gain -= (projected - c.ceilingDB)
        }
        return min(0, gain)
    }

    // MARK: Processing

    /// Process `frameCount` frames in place across `channels`.
    /// Real-time safe: no allocation, no locks, no ObjC.
    func process(channels: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>, frameCount: Int) {
        var c = coeffs
        c.bypass = c.bypass || bypassOverride
        guard let delay else { return }
        let chCount = min(channels.count, delayChannels)
        guard chCount > 0, frameCount > 0, delayCapacity > 1 else { return }

        let lookahead = max(1, min(c.lookaheadSamples, delayCapacity - 1))
        let ceilingLin = Float(c.ceilingLinear)
        let makeupLin = c.bypass ? 1.0 : c.makeupLinear
        var maxGR = 0.0
        var peakOut: Float = 0

        // ── Bypassed fast path ────────────────────────────────────────────────
        //
        // The delay line MUST keep running — latency is constant by contract, so
        // switching the limiter on and off cannot change alignment. Everything
        // else, though, provably cannot affect the output once the gain envelope
        // has unwound: `targetDB` is pinned at 0, `makeupLin` is 1, and the
        // ceiling clamp is skipped while bypassed. That leaves a `log10` and a
        // `pow` per sample plus the detector deque, all computing a gain of
        // exactly 1. Measured, a bypassed limiter cost ~90% of an active one,
        // and both decks carry one — the idle deck's limiter was burning that
        // permanently.
        //
        // The envelope is asymptotic, so it never reaches 0 exactly; below
        // 0.0005 dB (a linear gain within 6e-5 of unity) it is snapped so the
        // fast path is genuine bit-for-bit passthrough rather than nearly so.
        if c.bypass, gainDB > -0.0005 {
            gainDB = 0
            sustainedGR = 0
            detectorIdle = true

            for n in 0 ..< frameCount {
                let readIndex = (writeIndex - lookahead + delayCapacity) % delayCapacity
                for ch in 0 ..< chCount {
                    delay[ch * delayCapacity + writeIndex] = channels[ch][n]
                    let y = delay[ch * delayCapacity + readIndex]
                    channels[ch][n] = y
                    let a = abs(y)
                    if a > peakOut { peakOut = a }
                }
                writeIndex = (writeIndex + 1) % delayCapacity
            }

            gainReductionDB = 0
            outputPeakDB = peakOut > 0 ? 20.0 * log10(Double(peakOut)) : -120
            return
        }

        // Leaving the fast path: the detector has missed every sample that was
        // written while it was skipped, so it would under-read the peaks already
        // sitting in the delay line and let the first loud samples out past the
        // ceiling. Those samples are still in the delay line, so replay them.
        if detectorIdle {
            primeDetector(lookahead: lookahead, channelCount: chCount)
            detectorIdle = false
        }

        for n in 0 ..< frameCount {
            // --- write incoming into the delay line, find the linked peak
            var inPeak: Float = 0
            for ch in 0 ..< chCount {
                let x = channels[ch][n]
                delay[ch * delayCapacity + writeIndex] = x
                let a = abs(x)
                if a > inPeak { inPeak = a }
            }

            // --- detector runs *ahead* of the audio we are about to emit
            let windowPeak = detector.push(inPeak)

            // --- static curve
            let peakDB = 20.0 * log10(max(Double(windowPeak), 1e-9))
            let targetDB = c.bypass ? 0 : staticGainDB(forInputDB: peakDB)

            // --- program-dependent release
            // `sustainedGR` tracks how much reduction has been held recently.
            // Brief transients leave it near 0 → fast release. Loud passages
            // drive it up → release stretches toward 8× the set time, which
            // is what removes the pumping a fixed release causes.
            sustainedGR += (abs(targetDB) - sustainedGR) * c.sustainCoef
            let blend = min(1.0, max(0.0, sustainedGR / 6.0))
            let releaseCoef = c.releaseFastCoef + (c.releaseSlowCoef - c.releaseFastCoef) * blend

            if targetDB < gainDB {
                gainDB += (targetDB - gainDB) * c.attackCoef
            } else {
                // While bypassed the envelope is only unwinding leftover
                // reduction, so it uses the fixed fast ramp rather than the
                // program-dependent release.
                gainDB += (targetDB - gainDB) * (c.bypass ? c.bypassReleaseCoef : releaseCoef)
            }

            let reduction = -gainDB
            if reduction > maxGR { maxGR = reduction }

            // --- emit the delayed sample with the current gain
            let readIndex = (writeIndex - lookahead + delayCapacity) % delayCapacity
            let linGain = Float(pow(10.0, gainDB / 20.0) * makeupLin)

            for ch in 0 ..< chCount {
                var y = delay[ch * delayCapacity + readIndex] * linGain
                if !c.bypass {
                    // Final guard. With a correct attack the envelope has
                    // already arrived, so this clamps essentially nothing —
                    // it exists so the ceiling is a guarantee, not a hope.
                    if y > ceilingLin { y = ceilingLin }
                    if y < -ceilingLin { y = -ceilingLin }
                }
                channels[ch][n] = y
                let a = abs(y)
                if a > peakOut { peakOut = a }
            }

            writeIndex = (writeIndex + 1) % delayCapacity
        }

        gainReductionDB = maxGR
        outputPeakDB = peakOut > 0 ? 20.0 * log10(Double(peakOut)) : -120
    }

    /// Rebuild the sliding-peak window from the samples already in the delay
    /// line, so the detector resumes with exactly the state it would have had if
    /// it had been fed all along. O(lookahead) once per bypass→active edge —
    /// a few hundred samples, paid on a user action, never in steady state.
    private func primeDetector(lookahead: Int, channelCount chCount: Int) {
        guard let delay else { return }
        detector.reset()
        let count = min(lookahead, delayCapacity)
        var idx = (writeIndex - count + delayCapacity) % delayCapacity
        for _ in 0 ..< count {
            var linked: Float = 0
            for ch in 0 ..< chCount {
                let a = abs(delay[ch * delayCapacity + idx])
                if a > linked { linked = a }
            }
            _ = detector.push(linked)
            idx = (idx + 1) % delayCapacity
        }
    }

    /// Convenience mono path for tests.
    func process(_ samples: inout [Float]) {
        let count = samples.count
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var ptr = base
            withUnsafeMutablePointer(to: &ptr) { p in
                let channels = UnsafeMutableBufferPointer(start: p, count: 1)
                process(channels: channels, frameCount: count)
            }
        }
    }
}

// MARK: - Render-thread kernel

/// Wraps `LimiterDSPCore` with a real-time-safe parameter hand-off and a
/// scratch buffer for hosts that hand us a null-`mData` buffer list.
final class LimiterKernel: @unchecked Sendable {

    private let core = LimiterDSPCore()
    private var lock = os_unfair_lock_s()
    private var pending: LimiterCoefficients?
    /// Node-level bypass. Written from the main thread, read on the render
    /// thread; a single Bool, so a torn read is not possible in practice.
    private let nodeBypass = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

    /// Metering, written by the render thread and read by the UI. A torn read
    /// on a meter is harmless, so this is deliberately lock-free.
    private let meterGR = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    private let meterPeak = UnsafeMutablePointer<Double>.allocate(capacity: 1)

    /// Scratch used when the host passes buffers with no backing memory.
    /// Flat, channel-major, one raw allocation — see `LimiterDSPCore.delay`.
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchChannels = 0
    private var maxFrames = 4096
    /// Per-render channel pointer table. Preallocated so the render path never
    /// touches a Swift array.
    private var channelPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
    private var channelPointerCapacity = 0

    init() {
        meterGR.initialize(to: 0)
        meterPeak.initialize(to: -120)
        nodeBypass.initialize(to: false)
    }

    deinit {
        meterGR.deallocate()
        meterPeak.deallocate()
        nodeBypass.deallocate()
        scratch?.deallocate()
        channelPointers?.deallocate()
    }

    var gainReductionDB: Double { meterGR.pointee }
    var outputPeakDB: Double { meterPeak.pointee }

    var latencySeconds: Double {
        let c = core.currentCoefficients
        return Double(c.lookaheadSamples) / core.sampleRate
    }

    // MARK: Main-thread API

    func prepare(sampleRate: Double, channelCount: Int, maxFrames: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        self.maxFrames = max(64, maxFrames)
        let channels = max(1, channelCount)
        core.prepare(sampleRate: sampleRate, channelCount: channels)

        scratch?.deallocate()
        let total = self.maxFrames * channels
        let s = UnsafeMutablePointer<Float>.allocate(capacity: total)
        s.initialize(repeating: 0, count: total)
        scratch = s
        scratchChannels = channels

        channelPointers?.deallocate()
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channels)
        for ch in 0 ..< channels {
            table[ch] = s + ch * self.maxFrames
        }
        channelPointers = table
        channelPointerCapacity = channels

        if let pending {
            core.update(pending)
            self.pending = nil
        }
    }

    func setCoefficients(_ c: LimiterCoefficients) {
        os_unfair_lock_lock(&lock)
        pending = c
        os_unfair_lock_unlock(&lock)
    }

    /// Node-level bypass (`AVAudioUnitEffect.bypass` → `shouldBypassEffect`).
    ///
    /// Kept strictly separate from the coefficients' own bypass flag. Folding it
    /// into `pending` would let `LimiterDSP.apply` — which sets `unit.bypass`
    /// to false on purpose so latency stays constant — cancel out a disabled
    /// limiter and leave the stage processing audio it was told not to touch.
    func setBypass(_ on: Bool) {
        nodeBypass.pointee = on
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        core.reset()
        os_unfair_lock_unlock(&lock)
    }

    // MARK: Render thread

    /// Pull pending coefficients without ever blocking. If the UI happens to
    /// hold the lock this cycle we simply keep last cycle's values.
    @inline(__always)
    private func drainPendingIfPossible() {
        guard os_unfair_lock_trylock(&lock) else { return }
        if let p = pending {
            core.update(p)
            pending = nil
        }
        os_unfair_lock_unlock(&lock)
    }

    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        drainPendingIfPossible()
        core.bypassOverride = nodeBypass.pointee

        guard let table = channelPointers, let scratch else { return }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        let channels = min(abl.count, channelPointerCapacity)
        guard channels > 0, frameCount > 0, frameCount <= maxFrames else { return }

        for ch in 0 ..< channels {
            if let data = abl[ch].mData {
                table[ch] = data.assumingMemoryBound(to: Float.self)
            } else {
                // Host gave us no memory — render into scratch and hand it back.
                let slot = scratch + min(ch, scratchChannels - 1) * maxFrames
                table[ch] = slot
                abl[ch].mData = UnsafeMutableRawPointer(slot)
                abl[ch].mDataByteSize = UInt32(frameCount * MemoryLayout<Float>.size)
            }
        }

        core.process(
            channels: UnsafeMutableBufferPointer(start: table, count: channels),
            frameCount: frameCount
        )

        meterGR.pointee = core.gainReductionDB
        meterPeak.pointee = core.outputPeakDB
    }
}

// MARK: - AUAudioUnit

/// In-process AUv3 effect hosting `LimiterKernel`.
///
/// Registered under a private subtype so `AVAudioUnitEffect(audioComponentDescription:)`
/// can instantiate it **synchronously** — the deck builds its chain in `init`,
/// and the async `AVAudioUnit.instantiate` completion cannot be awaited there
/// without risking a main-thread deadlock.
final class EQTLimiterAudioUnit: AUAudioUnit {

    static let componentSubType: OSType = 0x6571746C   // 'eqtl'
    static let componentManufacturer: OSType = 0x45515447 // 'EQTG'

    static var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    let kernel = LimiterKernel()

    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!
    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var _shouldBypass = false

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        try super.init(componentDescription: componentDescription, options: options)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputBus.maximumChannelCount = 8
        outputBus.maximumChannelCount = 8

        _inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    override var outputBusses: AUAudioUnitBusArray { _outputBusses }

    /// Mirrored into the kernel so the render block never reads an ObjC property.
    override var shouldBypassEffect: Bool {
        get { _shouldBypass }
        set {
            _shouldBypass = newValue
            kernel.setBypass(newValue)
        }
    }

    /// Reported so AVAudioEngine can compensate the lookahead delay.
    override var latency: TimeInterval { kernel.latencySeconds }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        kernel.prepare(
            sampleRate: outputBus.format.sampleRate,
            channelCount: Int(outputBus.format.channelCount),
            maxFrames: Int(maximumFramesToRender)
        )
    }

    override func deallocateRenderResources() {
        kernel.reset()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.kernel
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInput = pullInputBlock else { return kAudioUnitErr_NoConnection }
            var pullFlags = AudioUnitRenderActionFlags(rawValue: 0)
            let err = pullInput(&pullFlags, timestamp, frameCount, 0, outputData)
            guard err == noErr else { return err }
            kernel.process(bufferList: outputData, frameCount: Int(frameCount))
            return noErr
        }
    }
}

// MARK: - Public façade

/// Mapping from `LimiterState` → the limiter node. Keeps the same shape the
/// engine already calls (`makeAudioUnit()` / `apply(params:to:)`) so the graph
/// wiring in `PlaybackDeck` is untouched.
enum LimiterDSP {

    struct UnitParams: Equatable {
        var bypass: Bool
        var coefficients: LimiterCoefficients
    }

    /// Registration must happen exactly once per process, before the first
    /// `AVAudioUnitEffect(audioComponentDescription:)` lookup.
    private static let registration: Bool = {
        AUAudioUnit.registerSubclass(
            EQTLimiterAudioUnit.self,
            as: EQTLimiterAudioUnit.componentDescription,
            name: "EQtargets Limiter",
            version: 2
        )
        return true
    }()

    static func unitParams(from state: LimiterState, sampleRate: Double = 48_000) -> UnitParams {
        let coeffs = LimiterCoefficients.make(from: state, sampleRate: sampleRate)
        return UnitParams(bypass: coeffs.bypass, coefficients: coeffs)
    }

    /// Create the limiter effect node. Falls back to Apple's AUDynamicsProcessor
    /// only if our own registration somehow failed, so a bad registration
    /// degrades to the previous behaviour rather than a silent broken chain.
    static func makeAudioUnit() -> AVAudioUnitEffect {
        _ = registration
        let effect = AVAudioUnitEffect(audioComponentDescription: EQTLimiterAudioUnit.componentDescription)
        if effect.auAudioUnit is EQTLimiterAudioUnit {
            return effect
        }
        let fallback = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return AVAudioUnitEffect(audioComponentDescription: fallback)
    }

    /// Push params onto a live limiter node.
    static func apply(params: UnitParams, to unit: AVAudioUnitEffect) {
        guard let au = unit.auAudioUnit as? EQTLimiterAudioUnit else {
            // Fallback node (Apple dynamics processor) — best-effort mapping.
            applyFallback(params: params, to: unit)
            unit.bypass = params.bypass
            return
        }
        var c = params.coefficients
        c.bypass = params.bypass
        au.kernel.setCoefficients(c)
        // Keep the node itself un-bypassed so the delay line keeps running and
        // latency stays constant; the kernel handles bypass at unity gain.
        // Toggling AVAudioUnit.bypass instead would change latency mid-stream.
        unit.bypass = false
    }

    /// Live gain reduction in dB (positive) for metering, or 0 when unavailable.
    static func gainReductionDB(of unit: AVAudioUnitEffect) -> Double {
        (unit.auAudioUnit as? EQTLimiterAudioUnit)?.kernel.gainReductionDB ?? 0
    }

    private static func applyFallback(params: UnitParams, to unit: AVAudioUnitEffect) {
        let au = unit.audioUnit
        let c = params.coefficients
        func set(_ id: AudioUnitParameterID, _ v: Float) {
            AudioUnitSetParameter(au, id, kAudioUnitScope_Global, 0, v, 0)
        }
        set(kDynamicsProcessorParam_Threshold, Float(min(20, max(-40, c.thresholdDB))))
        set(kDynamicsProcessorParam_HeadRoom, Float(min(40, max(0.1, 40.0 / max(c.ratio - 0.5, 0.5)))))
        set(kDynamicsProcessorParam_ExpansionRatio, 1)
        set(kDynamicsProcessorParam_ExpansionThreshold, -50)
        set(kDynamicsProcessorParam_OverallGain, Float(min(40, max(-40, c.makeupDB))))
    }
}
