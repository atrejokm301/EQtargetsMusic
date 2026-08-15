//
//  TransientPunchProcessor.swift
//  EQtargetsMusic
//
//  Dynamic layer for the **Transient Punch** bass style.
//
//  Chain position:
//    Player → Target PEQ → Fine-Tune PEQ → Bass (static shape) → Punch → Limiter → mixer
//
//  WHY THIS EXISTS
//  ------------------------------------------------------------------
//  "Transient Punch" is named after a time-domain behaviour but was a static
//  curve: a peak at ~98 Hz boosts a kick attack and a sustained bass note by
//  exactly the same amount. Punch is the *contrast* between attack and
//  sustain, which a fixed EQ cannot produce by definition.
//
//  This stage adds that contrast. It does not replace the static shape —
//  `BassProcessorDSP` still authors the tone and still level-matches every
//  style by K-weighted loudness. This layer only modulates the low band over
//  time, and at rest it is bit-exact passthrough, so that level-matching work
//  survives intact.
//
//  HOW IT DETECTS A TRANSIENT
//  ------------------------------------------------------------------
//  Differential envelope (the classic transient-designer technique): run two
//  followers on the low band, one fast and one slow. A kick attack makes the
//  fast one jump while the slow one lags, so their *ratio* spikes. During
//  sustain the two converge and the ratio returns to 1. No pitch tracking, no
//  FFT, no lookahead — just two one-poles and a divide.
//
//  COST
//  ------------------------------------------------------------------
//  Deliberately built so "dynamic" never means "recompute filter coefficients
//  per sample" — that is what makes naive dynamic EQ expensive (a sin/cos per
//  sample). Here:
//    • the crossover is FIXED; coefficients change only when the user moves
//      the cutoff slider, never on the audio thread;
//    • the gain is a scalar applied to a parallel band — one multiply-add;
//    • the divide and the gain decision run at CONTROL RATE (every 32 samples)
//      and are linearly interpolated in between. Punch time constants are tens
//      of milliseconds, so per-sample gain decisions buy nothing;
//    • there is no log/exp/pow anywhere in the render path — the detector works
//      in the linear domain on purpose.
//
//  TOPOLOGY
//  ------------------------------------------------------------------
//      out = g · LP₄(in) + HP₄(in)        (Linkwitz-Riley, 4th order)
//
//  A true complementary crossover, NOT a parallel boost. The obvious cheaper
//  form `out = in + (g − 1)·lowpass(in)` is wrong here and was measured to be
//  wrong: the lowpass lags the input by ~70° near the corner, so the two are
//  not in phase, and scaling one and adding it back is a comb filter rather
//  than a gain. Asking that form for a 6 dB low-band *cut* produced a 1.6 dB
//  rise instead.
//
//  Linkwitz-Riley 4th order has the property that LP₄ + HP₄ sums to an
//  allpass: at g == 1 the magnitude response is exactly flat, so the K-weighted
//  style level-matching upstream is preserved to the dB. The cost is a static
//  allpass phase response while the style is engaged, which is inaudible and is
//  what every multiband processor does. When the style is off the stage returns
//  early and the samples are untouched bit for bit.
//
//  Modulating a scalar band gain (rather than modulating filter coefficients)
//  also means the gain can move as fast as punch requires without any risk of
//  filter-state transients.
//

import Foundation
import AudioToolbox
import AVFoundation
import os.lock

// MARK: - Tuning constants

enum TransientPunchTuning {
    /// Envelope that tracks the instantaneous low-band level.
    static let fastAttackMs: Double = 0.5
    static let fastReleaseMs: Double = 40

    /// Envelope that tracks the recent average. The gap between the two is the
    /// transient. Attack is deliberately slow so a kick does not drag it up.
    static let slowAttackMs: Double = 45
    static let slowReleaseMs: Double = 300

    /// Applied gain smoothing. Fast enough to let an attack through, slow
    /// enough that the gain change itself is never audible as a click.
    static let gainAttackMs: Double = 1.0
    static let gainReleaseMs: Double = 90

    /// Largest boost the attack stage may apply to the low band, in dB.
    static let maxAttackBoostDB: Double = 9.0
    /// Largest trim the sustain stage may apply, in dB (applied as a cut).
    static let maxSustainTrimDB: Double = 6.0

    /// Gain decisions per block. 32 samples ≈ 0.67 ms at 48 kHz — two orders of
    /// magnitude finer than the envelopes, and 32× cheaper than per-sample.
    static let controlRateSamples = 32

    /// Low-band level below which the stage stands down entirely, so noise
    /// floors and silence are never "punched". Linear, ≈ −60 dBFS.
    static let activityFloor: Double = 0.001

    /// Ratio below which nothing is treated as a transient at all.
    ///
    /// This deadband is not cosmetic. Following the *peak* of a rectified low
    /// sine makes the fast envelope sag between peaks, so even a perfectly
    /// steady 40-80 Hz tone produces a fast/slow ratio that wobbles up to
    /// ~1.15. With a fast-attack/slow-release gain smoother that ripple gets
    /// rectified into a standing boost — measured at +0.72 dB on a steady tone
    /// before this existed, which would quietly break the level matching the
    /// bass stage depends on. 1.3 sits clear of the ripple and well under a
    /// real kick (2-4).
    static let onsetRatio: Double = 1.3

    /// Ratio at which the attack stage is considered fully engaged.
    /// fast/slow of 4 (≈ +12 dB above the running average) is a hard transient.
    static let fullTransientRatio: Double = 4.0

    /// Denormal guard. Envelopes decaying toward zero generate denormal floats,
    /// which stall some FPUs badly; this keeps them in normal range.
    static let denormalFloor: Double = 1e-15
}

/// Tuning for the **Sustain / Rumble** mode of the same kernel.
///
/// Rumble is the mirror of Punch and reuses every part of the machinery — one
/// crossover, one pair of envelopes, one gain scalar. Only the mapping from
/// `fast/slow` to gain differs, so running Rumble costs the same as running
/// Punch and adds no node to the graph.
///
/// Punch acts when the ratio **spikes** (a leading edge). Rumble acts when it
/// **sags** — the signature of a note already decaying — and holds it up. The
/// two regions do not overlap, which is why one scalar can serve both.
enum SustainRumbleTuning {
    /// Slower than Punch's followers on purpose. Punch needs 0.5 ms to catch a
    /// kick edge; Rumble is looking at decay over hundreds of milliseconds, and
    /// a slower fast-follower has far less inter-peak ripple to design around.
    static let fastAttackMs: Double = 3
    static let fastReleaseMs: Double = 90

    /// The reference the decay is measured against. Long release so the average
    /// outlives the note and the tail has something to be held up toward.
    static let slowAttackMs: Double = 80
    static let slowReleaseMs: Double = 700

    /// Gain smoothing. Deliberately sluggish: sustain is a slow gesture, and a
    /// fast gain rise here would read as pumping rather than length.
    static let gainAttackMs: Double = 45
    static let gainReleaseMs: Double = 200

    /// Smoothing used instead of the pair above whenever the gain *target* is
    /// below unity — i.e. while the softening half is cutting a leading edge.
    ///
    /// Two pairs are needed because the smoother is direction-based, and the two
    /// halves want opposite things from the same direction. Engaging a cut means
    /// the gain must FALL, which under the sustain pair takes 200 ms — measured,
    /// that delivered −0.085 dB over a note onset, i.e. nothing. Softening has to
    /// arrive inside the first few milliseconds like any transient designer;
    /// recovery back to unity stays slow so it never chirps.
    static let cutFallMs: Double = 1.5
    static let cutRiseMs: Double = 80

    /// Largest lift applied to a decaying tail, in dB. Note this is an upper
    /// bound only — `decideGain` additionally clamps the lift so a tail is never
    /// raised above its own running average (see there).
    static let maxSustainBoostDB: Double = 7.0

    /// Largest cut applied to a leading edge when softening, in dB.
    static let maxSoftenDB: Double = 4.0

    /// Ratio below which a note counts as decaying. Chosen from the measured
    /// steady-tone ripple trough of these ballistics, with margin — the mirror
    /// of `TransientPunchTuning.onsetRatio` and there for the same reason: a
    /// steady tone must produce exactly no gain movement, or the K-weighted
    /// style level-matching upstream quietly stops holding.
    static let decayOnsetRatio: Double = 0.80

    /// Ratio at which the sustain stage is fully engaged.
    static let fullDecayRatio: Double = 0.30

    /// Leading-edge detection for the softening half. Same thresholds as Punch's
    /// attack detector, used to cut instead of boost.
    static let softenOnsetRatio: Double = 1.3
    static let fullTransientRatio: Double = 4.0

    /// The dynamic band sits above the style's shelf corner by this factor.
    /// Wider than Punch's 1.15 because Rumble's job covers sub *and* body, not
    /// just the kick attack region.
    static let crossoverMultiplier: Double = 1.6
}

// MARK: - Coefficients

/// Sample-rate-resolved kernel parameters. Plain values — copied to the render
/// thread wholesale.
struct TransientPunchCoefficients: Equatable {

    /// Which gain law the shared kernel runs. The DSP path — crossover,
    /// envelopes, smoothing, recombination — is identical either way; only
    /// `decideGain` branches, and it does so at control rate.
    enum Mode: Int, Equatable {
        /// Boost leading edges, optionally trim what sits behind them.
        case punch
        /// Hold up decaying tails, optionally soften leading edges.
        case rumble
    }

    var mode: Mode = .punch
    var bypass: Bool = true

    /// Fixed crossover biquads (RBJ, normalised by a0), each cascaded twice to
    /// make the 4th-order Linkwitz-Riley pair. Coefficients are computed when
    /// the user moves the cutoff slider — never on the audio thread.
    var lpB0: Double = 0
    var lpB1: Double = 0
    var lpB2: Double = 0
    var hpB0: Double = 0
    var hpB1: Double = 0
    var hpB2: Double = 0
    /// Shared denominator — the LP and HP sections use the same poles.
    var a1: Double = 0
    var a2: Double = 0

    var fastAttackCoef: Double = 0
    var fastReleaseCoef: Double = 0
    var slowAttackCoef: Double = 0
    var slowReleaseCoef: Double = 0
    var gainAttackCoef: Double = 0
    var gainReleaseCoef: Double = 0

    /// Smoothing pair used while the gain target sits **below unity**. For Punch
    /// these are set equal to the pair above, so its behaviour is bit-identical
    /// to before this existed; Rumble uses them to make softening actually land.
    var cutRiseCoef: Double = 0
    var cutFallCoef: Double = 0

    /// 0…1 — how strongly a detected transient boosts the low band.
    var attackAmount: Double = 0
    /// 0…1 — how strongly sustained low energy is trimmed.
    var sustainAmount: Double = 0

    /// Linear bounds derived from the dB limits above, scaled by strength.
    var maxBoostLinear: Double = 1
    var minTrimLinear: Double = 1

    static func make(from state: BassProcessorState, sampleRate: Double) -> TransientPunchCoefficients {
        let s = state.sanitized()
        let sr = max(8_000, sampleRate)
        var c = TransientPunchCoefficients()

        // Transient Punch and Sustain / Rumble both drive this stage, in
        // opposite directions. Natural Clean and Off leave it inert — Clean is a
        // deliberately static "gentle lift", so there is nothing to modulate.
        switch s.style {
        case .transientPunch: c.mode = .punch
        case .sustainRumble: c.mode = .rumble
        case .none, .naturalClean: c.bypass = true; return c
        }

        // A mode whose own controls are both at zero has nothing to do; keep it
        // bypassed so it stays bit-for-bit transparent rather than burning the
        // crossover to apply a gain of exactly 1.
        let modeIdle = c.mode == .punch
            ? (s.punchAttack <= 0.001 && s.punchSustain <= 0.001)
            : (s.rumbleSustain <= 0.001 && s.rumbleSoften <= 0.001)
        let engaged = s.strength > 0.001 && !modeIdle
        c.bypass = !engaged
        guard engaged else { return c }

        // --- fixed low band, cutoff follows the style's own cutoff slider.
        // Punch sits just above the shape's corner so the dynamic band covers
        // the kick body the static peak sits in; Rumble reaches wider because
        // its job spans sub and body. See each mode's tuning.
        let multiplier = c.mode == .punch ? 1.15 : SustainRumbleTuning.crossoverMultiplier
        let fc = min(max(s.cutoff * multiplier, 30), sr * 0.45)
        let q = 1.0 / 2.0.squareRoot()          // Butterworth; cascaded → LR4
        let w0 = 2 * Double.pi * fc / sr
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        c.lpB0 = ((1 - cosW0) / 2) / a0
        c.lpB1 = (1 - cosW0) / a0
        c.lpB2 = c.lpB0
        c.hpB0 = ((1 + cosW0) / 2) / a0
        c.hpB1 = -(1 + cosW0) / a0
        c.hpB2 = c.hpB0
        c.a1 = (-2 * cosW0) / a0
        c.a2 = (1 - alpha) / a0

        // Strength scales both halves of whichever mode is running, so the
        // existing slider still governs how much the style does overall.
        // `attackAmount` / `sustainAmount` are named for Punch but carry the
        // boosting and cutting halves of either mode.
        switch c.mode {
        case .punch:
            c.fastAttackCoef = onePole(TransientPunchTuning.fastAttackMs, sr)
            c.fastReleaseCoef = onePole(TransientPunchTuning.fastReleaseMs, sr)
            c.slowAttackCoef = onePole(TransientPunchTuning.slowAttackMs, sr)
            c.slowReleaseCoef = onePole(TransientPunchTuning.slowReleaseMs, sr)
            c.gainAttackCoef = onePole(TransientPunchTuning.gainAttackMs, sr)
            c.gainReleaseCoef = onePole(TransientPunchTuning.gainReleaseMs, sr)
            // Punch keeps one smoothing pair — identical maths to before.
            c.cutRiseCoef = c.gainAttackCoef
            c.cutFallCoef = c.gainReleaseCoef

            c.attackAmount = s.punchAttack * s.strength
            c.sustainAmount = s.punchSustain * s.strength
            c.maxBoostLinear = pow(10, TransientPunchTuning.maxAttackBoostDB * c.attackAmount / 20)
            c.minTrimLinear = pow(10, -TransientPunchTuning.maxSustainTrimDB * c.sustainAmount / 20)

        case .rumble:
            c.fastAttackCoef = onePole(SustainRumbleTuning.fastAttackMs, sr)
            c.fastReleaseCoef = onePole(SustainRumbleTuning.fastReleaseMs, sr)
            c.slowAttackCoef = onePole(SustainRumbleTuning.slowAttackMs, sr)
            c.slowReleaseCoef = onePole(SustainRumbleTuning.slowReleaseMs, sr)
            c.gainAttackCoef = onePole(SustainRumbleTuning.gainAttackMs, sr)
            c.gainReleaseCoef = onePole(SustainRumbleTuning.gainReleaseMs, sr)
            c.cutRiseCoef = onePole(SustainRumbleTuning.cutRiseMs, sr)
            c.cutFallCoef = onePole(SustainRumbleTuning.cutFallMs, sr)

            c.attackAmount = s.rumbleSustain * s.strength
            c.sustainAmount = s.rumbleSoften * s.strength
            c.maxBoostLinear = pow(10, SustainRumbleTuning.maxSustainBoostDB * c.attackAmount / 20)
            c.minTrimLinear = pow(10, -SustainRumbleTuning.maxSoftenDB * c.sustainAmount / 20)
        }
        return c
    }

    /// One-pole coefficient reaching ~63% of the target in `ms`.
    static func onePole(_ ms: Double, _ sampleRate: Double) -> Double {
        let n = max(1.0, max(0.02, ms) / 1000.0 * sampleRate)
        return 1.0 - exp(-1.0 / n)
    }
}

// MARK: - DSP core

/// Pure transient-punch kernel. No AVFoundation dependency, so tests drive it
/// with plain `[Float]` buffers.
///
/// Detection is **linked** across channels (one shared gain) so punch never
/// pulls the stereo image around.
final class TransientPunchDSPCore {

    private(set) var sampleRate: Double = 48_000
    private(set) var channelCount: Int = 2
    private var coeffs = TransientPunchCoefficients()

    /// Crossover filter state: 4 cascaded biquads per channel (LP×2, HP×2),
    /// 2 state words each. One flat allocation, channel-major:
    /// channel `ch` occupies `state[ch*8 ..< ch*8+8]`.
    private var state: UnsafeMutablePointer<Double>?
    private var stateChannels = 0
    private static let wordsPerChannel = 8

    /// Exposed `private(set)` so tests and the tuning harness can read the
    /// detector's own state instead of inferring it from output audio — the
    /// deadband constants below are chosen from measured ripple, not guessed.
    private(set) var fastEnv: Double = 0
    private(set) var slowEnv: Double = 0
    /// Smoothed applied gain (linear). 1.0 == passthrough.
    private var gain: Double = 1
    /// Countdown to the next control-rate decision.
    private var controlCounter = 0
    /// Gain target the per-sample interpolation is walking toward.
    private var gainTarget: Double = 1
    /// Smoothing coefficients in force for the current target, refreshed at
    /// control rate alongside `gainTarget`.
    private var riseCoef: Double = 0
    private var fallCoef: Double = 0

    /// Largest boost applied during the last processed block, in dB (≥ 0).
    private(set) var attackBoostDB: Double = 0
    /// Largest trim applied during the last processed block, in dB (≥ 0).
    private(set) var sustainTrimDB: Double = 0

    /// Node-level bypass, ORed with the coefficients' own flag — see the
    /// limiter's equivalent; folding the two together caused a real bug there.
    var bypassOverride = false

    deinit { freeState() }

    private func freeState() {
        state?.deallocate()
        state = nil
    }

    func prepare(sampleRate: Double, channelCount: Int) {
        self.sampleRate = max(8_000, sampleRate)
        self.channelCount = max(1, channelCount)
        freeState()
        let n = self.channelCount
        // + 2n for the per-sample low/high band scratch.
        let total = n * Self.wordsPerChannel + 2 * n
        let p = UnsafeMutablePointer<Double>.allocate(capacity: total)
        p.initialize(repeating: 0, count: total)
        state = p
        stateChannels = n
        reset()
    }

    func reset() {
        if let state, stateChannels > 0 {
            state.update(repeating: 0, count: stateChannels * Self.wordsPerChannel + 2 * stateChannels)
        }
        fastEnv = 0
        slowEnv = 0
        gain = 1
        gainTarget = 1
        // Zero until the first control-rate decision sets them; a gain of 1 with
        // a target of 1 cannot move regardless, so the first block is safe.
        riseCoef = 0
        fallCoef = 0
        controlCounter = 0
        attackBoostDB = 0
        sustainTrimDB = 0
    }

    func update(_ new: TransientPunchCoefficients) {
        coeffs = new
    }

    var currentCoefficients: TransientPunchCoefficients { coeffs }

    /// The control-rate decision, factored out so tests can drive the curve
    /// directly without pushing audio through.
    ///
    /// - Returns: linear gain to apply to the low band.
    func decideGain(fast: Double, slow: Double) -> Double {
        let c = coeffs
        guard !c.bypass else { return 1 }

        // Below the activity floor there is nothing musical to shape.
        guard slow > TransientPunchTuning.activityFloor
                || fast > TransientPunchTuning.activityFloor else { return 1 }

        let ratio = fast / max(slow, TransientPunchTuning.denormalFloor)

        switch c.mode {
        case .punch:
            // 0 at steady state (including envelope ripple), 1 at a hard transient.
            let span = TransientPunchTuning.fullTransientRatio - TransientPunchTuning.onsetRatio
            let transient = min(
                1.0,
                max(0.0, (ratio - TransientPunchTuning.onsetRatio) / span)
            )

            // Attack stage lifts the leading edge; sustain stage trims what is left
            // behind it. The (1 − transient) weighting is what makes them exclusive
            // — you cannot boost and trim the same moment.
            let boost = 1.0 + (c.maxBoostLinear - 1.0) * transient
            let trim = 1.0 + (c.minTrimLinear - 1.0) * (1.0 - transient)
            return boost * trim

        case .rumble:
            // Decay detection: 0 while the note is steady or rising, 1 once the
            // instantaneous level has fallen well below its running average.
            let decaySpan = SustainRumbleTuning.decayOnsetRatio - SustainRumbleTuning.fullDecayRatio
            let decay = min(
                1.0,
                max(0.0, (SustainRumbleTuning.decayOnsetRatio - ratio) / decaySpan)
            )
            var boost = 1.0 + (c.maxBoostLinear - 1.0) * decay

            // **Peak safety by construction.** slow/fast is exactly the gain that
            // would restore the tail to its own running average. Clamping to it
            // means the sustain stage can never push a decaying note above a
            // level that note already reached — so the stage lengthens the decay
            // without ever raising the peak the static shape was level-matched
            // and headroom-checked against. No lookahead, no limiter dependency,
            // one compare.
            let restore = slow / max(fast, TransientPunchTuning.denormalFloor)
            if boost > restore { boost = max(1.0, restore) }

            // Softening half: cut the leading edge. Lives in the ratio > 1.3
            // region, which `decay` above cannot reach, so the two never fight.
            let softSpan = SustainRumbleTuning.fullTransientRatio - SustainRumbleTuning.softenOnsetRatio
            let onset = min(
                1.0,
                max(0.0, (ratio - SustainRumbleTuning.softenOnsetRatio) / softSpan)
            )
            let soften = 1.0 + (c.minTrimLinear - 1.0) * onset
            return boost * soften
        }
    }

    /// Process `frameCount` frames in place. Real-time safe: no allocation,
    /// no locks, no ObjC, no transcendental functions.
    func process(channels: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>, frameCount: Int) {
        var c = coeffs
        c.bypass = c.bypass || bypassOverride

        guard let state else { return }
        let chCount = min(channels.count, stateChannels)
        guard chCount > 0, frameCount > 0 else { return }

        // Bypassed: leave the samples completely untouched. Unlike the limiter
        // there is no delay line here, so there is no latency to preserve and
        // nothing to keep running.
        guard !c.bypass else {
            gain = 1; gainTarget = 1
            attackBoostDB = 0; sustainTrimDB = 0
            return
        }

        var maxBoost = 1.0
        var minTrim = 1.0

        for n in 0 ..< frameCount {
            // --- fixed LR4 crossover, transposed direct form II.
            // Low band is kept per channel for the gain stage; high band is
            // written straight back so only the low band is ever scaled.
            var linkedLow = 0.0
            for ch in 0 ..< chCount {
                let x = Double(channels[ch][n])
                let base = ch * Self.wordsPerChannel

                // lowpass, two cascaded sections
                let l1 = c.lpB0 * x + state[base]
                state[base]     = c.lpB1 * x  - c.a1 * l1 + state[base + 1]
                state[base + 1] = c.lpB2 * x  - c.a2 * l1
                let low = c.lpB0 * l1 + state[base + 2]
                state[base + 2] = c.lpB1 * l1 - c.a1 * low + state[base + 3]
                state[base + 3] = c.lpB2 * l1 - c.a2 * low

                // highpass, two cascaded sections (same poles)
                let h1 = c.hpB0 * x + state[base + 4]
                state[base + 4] = c.hpB1 * x  - c.a1 * h1 + state[base + 5]
                state[base + 5] = c.hpB2 * x  - c.a2 * h1
                let high = c.hpB0 * h1 + state[base + 6]
                state[base + 6] = c.hpB1 * h1 - c.a1 * high + state[base + 7]
                state[base + 7] = c.hpB2 * h1 - c.a2 * high

                lowBand[ch] = low
                highBand[ch] = high
                let a = abs(low)
                if a > linkedLow { linkedLow = a }
            }

            // --- differential envelopes (audio rate: cheap, and the fast one
            //     genuinely needs the resolution to catch a 0.5 ms edge)
            if linkedLow > fastEnv {
                fastEnv += (linkedLow - fastEnv) * c.fastAttackCoef
            } else {
                fastEnv += (linkedLow - fastEnv) * c.fastReleaseCoef
            }
            if linkedLow > slowEnv {
                slowEnv += (linkedLow - slowEnv) * c.slowAttackCoef
            } else {
                slowEnv += (linkedLow - slowEnv) * c.slowReleaseCoef
            }
            if fastEnv < TransientPunchTuning.denormalFloor { fastEnv = 0 }
            if slowEnv < TransientPunchTuning.denormalFloor { slowEnv = 0 }

            // --- control rate: the divide and the decision, 1 sample in 32.
            // The smoothing pair is chosen here too, so selecting between the
            // sustain and cut ballistics costs nothing in the per-sample path.
            if controlCounter == 0 {
                gainTarget = decideGain(fast: fastEnv, slow: slowEnv)
                if gainTarget < 1.0 {
                    riseCoef = c.cutRiseCoef
                    fallCoef = c.cutFallCoef
                } else {
                    riseCoef = c.gainAttackCoef
                    fallCoef = c.gainReleaseCoef
                }
                controlCounter = TransientPunchTuning.controlRateSamples
            }
            controlCounter -= 1

            // --- smooth toward the target
            if gainTarget > gain {
                gain += (gainTarget - gain) * riseCoef
            } else {
                gain += (gainTarget - gain) * fallCoef
            }

            if gain > maxBoost { maxBoost = gain }
            if gain < minTrim { minTrim = gain }

            // --- recombine: out = g·low + high
            for ch in 0 ..< chCount {
                channels[ch][n] = Float(gain * lowBand[ch] + highBand[ch])
            }
        }

        attackBoostDB = maxBoost > 1 ? 20 * log10(maxBoost) : 0
        sustainTrimDB = minTrim < 1 ? -20 * log10(minTrim) : 0
    }

    /// Per-sample band scratch, one slot per channel. Fixed capacity, allocated
    /// once in `prepare`, so the render path never touches a Swift array.
    private var lowBand: UnsafeMutablePointer<Double> {
        state! + stateChannels * Self.wordsPerChannel
    }
    private var highBand: UnsafeMutablePointer<Double> {
        state! + stateChannels * Self.wordsPerChannel + stateChannels
    }

    /// Convenience mono path for tests.
    func process(_ samples: inout [Float]) {
        let count = samples.count
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var ptr = base
            withUnsafeMutablePointer(to: &ptr) { p in
                process(channels: UnsafeMutableBufferPointer(start: p, count: 1), frameCount: count)
            }
        }
    }
}

// MARK: - Render-thread kernel

final class TransientPunchKernel: @unchecked Sendable {

    private let core = TransientPunchDSPCore()
    private var lock = os_unfair_lock_s()
    private var pending: TransientPunchCoefficients?
    private let nodeBypass = UnsafeMutablePointer<Bool>.allocate(capacity: 1)

    private let meterBoost = UnsafeMutablePointer<Double>.allocate(capacity: 1)
    private let meterTrim = UnsafeMutablePointer<Double>.allocate(capacity: 1)

    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchChannels = 0
    private var maxFrames = 4096
    private var channelPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
    private var channelPointerCapacity = 0

    init() {
        nodeBypass.initialize(to: false)
        meterBoost.initialize(to: 0)
        meterTrim.initialize(to: 0)
    }

    deinit {
        nodeBypass.deallocate()
        meterBoost.deallocate()
        meterTrim.deallocate()
        scratch?.deallocate()
        channelPointers?.deallocate()
    }

    var attackBoostDB: Double { meterBoost.pointee }
    var sustainTrimDB: Double { meterTrim.pointee }

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
        for ch in 0 ..< channels { table[ch] = s + ch * self.maxFrames }
        channelPointers = table
        channelPointerCapacity = channels

        if let pending {
            core.update(pending)
            self.pending = nil
        }
    }

    func setCoefficients(_ c: TransientPunchCoefficients) {
        os_unfair_lock_lock(&lock)
        pending = c
        os_unfair_lock_unlock(&lock)
    }

    func setBypass(_ on: Bool) { nodeBypass.pointee = on }

    func reset() {
        os_unfair_lock_lock(&lock)
        core.reset()
        os_unfair_lock_unlock(&lock)
    }

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

        meterBoost.pointee = core.attackBoostDB
        meterTrim.pointee = core.sustainTrimDB
    }
}

// MARK: - AUAudioUnit

/// In-process AUv3 hosting `TransientPunchKernel`. Same registration approach
/// as `EQTLimiterAudioUnit` so `AVAudioUnitEffect(audioComponentDescription:)`
/// can build it synchronously inside `PlaybackDeck.init`.
final class EQTPunchAudioUnit: AUAudioUnit {

    static let componentSubType: OSType = 0x65717470       // 'eqtp'
    static let componentManufacturer: OSType = 0x45515447  // 'EQTG'

    static var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    let kernel = TransientPunchKernel()

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

    override var shouldBypassEffect: Bool {
        get { _shouldBypass }
        set {
            _shouldBypass = newValue
            kernel.setBypass(newValue)
        }
    }

    /// Zero — the parallel-boost topology adds no delay.
    override var latency: TimeInterval { 0 }

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

enum TransientPunchDSP {

    struct UnitParams: Equatable {
        var bypass: Bool
        var coefficients: TransientPunchCoefficients
    }

    private static let registration: Bool = {
        AUAudioUnit.registerSubclass(
            EQTPunchAudioUnit.self,
            as: EQTPunchAudioUnit.componentDescription,
            name: "EQtargets Transient Punch",
            version: 1
        )
        return true
    }()

    static func unitParams(from state: BassProcessorState, sampleRate: Double = 48_000) -> UnitParams {
        let c = TransientPunchCoefficients.make(from: state, sampleRate: sampleRate)
        return UnitParams(bypass: c.bypass, coefficients: c)
    }

    /// Create the punch node. If registration somehow failed we return a
    /// permanently-bypassed Apple delay unit rather than a broken chain, so the
    /// worst case is "no punch" instead of "no audio".
    static func makeAudioUnit() -> AVAudioUnitEffect {
        _ = registration
        let effect = AVAudioUnitEffect(audioComponentDescription: EQTPunchAudioUnit.componentDescription)
        if effect.auAudioUnit is EQTPunchAudioUnit { return effect }
        let fallback = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_Delay,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let unit = AVAudioUnitEffect(audioComponentDescription: fallback)
        unit.bypass = true
        return unit
    }

    static func apply(params: UnitParams, to unit: AVAudioUnitEffect) {
        guard let au = unit.auAudioUnit as? EQTPunchAudioUnit else {
            unit.bypass = true          // fallback node: never process
            return
        }
        var c = params.coefficients
        c.bypass = params.bypass
        au.kernel.setCoefficients(c)
        // The kernel handles bypass internally (and passes through untouched),
        // so the node itself stays live. Latency is 0 either way.
        unit.bypass = false
    }

    /// Live attack boost in dB for metering, or 0 when unavailable.
    static func attackBoostDB(of unit: AVAudioUnitEffect) -> Double {
        (unit.auAudioUnit as? EQTPunchAudioUnit)?.kernel.attackBoostDB ?? 0
    }

    /// Live sustain trim in dB (positive magnitude) for metering, or 0 when
    /// unavailable. Reported separately from the boost because a single block can
    /// contain both — the attack of one kick and the tail of the last.
    static func sustainTrimDB(of unit: AVAudioUnitEffect) -> Double {
        (unit.auAudioUnit as? EQTPunchAudioUnit)?.kernel.sustainTrimDB ?? 0
    }
}
