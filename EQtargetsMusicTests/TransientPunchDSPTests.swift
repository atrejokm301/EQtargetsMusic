//
//  TransientPunchDSPTests.swift
//  EQtargetsMusicTests
//
//  Contract for the dynamic layer behind the Transient Punch bass style:
//    • every other style leaves it bit-for-bit inert;
//    • the LR4 crossover reconstructs flat, so the K-weighted style matching
//      in BassProcessorDSP is not disturbed;
//    • a steady tone is neither boosted nor modulated (the failure mode that
//      the transient deadband exists to prevent);
//    • a kick attack actually gets lifted, and more than the gap after it;
//    • stereo stays linked.
//

import XCTest
@testable import EQtargetsMusic

final class TransientPunchDSPTests: XCTestCase {

    private let sr = 48_000.0

    // MARK: - Helpers

    private func state(
        attack: Double = 0.5,
        sustain: Double = 0,
        strength: Double = 0.6,
        cutoff: Double = 85,
        style: BassStyle = .transientPunch
    ) -> BassProcessorState {
        var s = BassProcessorState()
        s.style = style
        s.strength = strength
        s.cutoff = cutoff
        s.punchAttack = attack
        s.punchSustain = sustain
        return s.sanitized()
    }

    private func makeCore(_ s: BassProcessorState, channels: Int = 1) -> TransientPunchDSPCore {
        let core = TransientPunchDSPCore()
        core.prepare(sampleRate: sr, channelCount: channels)
        core.update(TransientPunchCoefficients.make(from: s, sampleRate: sr))
        return core
    }

    private func sine(_ amp: Double, _ hz: Double, _ n: Int) -> [Float] {
        (0 ..< n).map { Float(amp * sin(2 * .pi * hz * Double($0) / sr)) }
    }

    private func rms(_ b: ArraySlice<Float>) -> Double {
        guard !b.isEmpty else { return 0 }
        return (b.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(b.count)).squareRoot()
    }

    private func processStereo(_ core: TransientPunchDSPCore, _ l: inout [Float], _ r: inout [Float]) {
        let n = l.count
        l.withUnsafeMutableBufferPointer { lb in
            r.withUnsafeMutableBufferPointer { rb in
                var p = [lb.baseAddress!, rb.baseAddress!]
                p.withUnsafeMutableBufferPointer { pb in
                    core.process(channels: pb, frameCount: n)
                }
            }
        }
    }

    // MARK: - Inertness

    /// Sustain / Rumble deliberately left this list when it gained its own gain
    /// law — it now drives the same kernel in the opposite direction. Off and
    /// Natural Clean stay static by design.
    func test_staticBassStyles_leaveAudioBitForBitUntouched() {
        for style in [BassStyle.none, .naturalClean] {
            let input = sine(0.5, 60, 8_000)
            var buf = input
            makeCore(state(style: style)).process(&buf)
            XCTAssertEqual(buf, input, "\(style.title) must not reach the dynamic stage")
        }
    }

    func test_rumbleWithBothControlsAtZero_isBitForBitPassthrough() {
        var s = state(strength: 1.0, style: .sustainRumble)
        s.rumbleSustain = 0
        s.rumbleSoften = 0
        let input = sine(0.5, 60, 8_000)
        var buf = input
        makeCore(s).process(&buf)
        XCTAssertEqual(buf, input, "an idle mode must stay transparent, not apply a gain of 1")
    }

    func test_zeroStrength_isBitForBitPassthrough() {
        let input = sine(0.5, 60, 8_000)
        var buf = input
        makeCore(state(strength: 0)).process(&buf)
        XCTAssertEqual(buf, input)
    }

    func test_nodeBypass_winsOverAnEngagedStyle() {
        let core = makeCore(state())
        core.bypassOverride = true
        let input = sine(0.5, 60, 8_000)
        var buf = input
        core.process(&buf)
        XCTAssertEqual(buf, input)
    }

    // MARK: - Crossover reconstruction

    func test_crossoverReconstructsFlatAtUnityGain() {
        // LR4 low + high sums to an allpass. If this drifts, every Transient
        // Punch listener silently gets a different level than the style was
        // level-matched to produce.
        let core = makeCore(state(attack: 0, sustain: 0, strength: 1.0))
        for hz in [30.0, 60.0, 98.0, 150.0, 400.0, 2_000.0] {
            let n = Int(sr)
            let input = sine(0.5, hz, n)
            var buf = input
            core.reset()
            core.process(&buf)

            let start = Int(sr * 0.3)
            let deltaDB = 20 * log10(rms(buf[start...]) / rms(input[start...]))
            XCTAssertEqual(deltaDB, 0, accuracy: 0.1,
                           "\(Int(hz)) Hz reconstruction is \(deltaDB) dB off flat")
        }
    }

    // MARK: - Steady material

    func test_steadyLowTone_isNeitherBoostedNorModulated() {
        // Regression for the envelope-ripple problem: following the peak of a
        // rectified low sine makes fast/slow wobble to ~1.15, and a fast-attack
        // slow-release gain smoother rectifies that into a standing boost.
        // Measured at +0.72 dB before `onsetRatio` existed.
        for hz in [40.0, 60.0, 80.0] {
            let core = makeCore(state(attack: 1.0, strength: 1.0))   // worst case
            let n = Int(sr * 2)
            let input = sine(0.5, hz, n)
            var buf = input
            core.process(&buf)

            let start = Int(sr * 0.5)
            let deltaDB = 20 * log10(rms(buf[start...]) / rms(input[start...]))
            XCTAssertEqual(deltaDB, 0, accuracy: 0.2,
                           "steady \(Int(hz)) Hz gained \(deltaDB) dB")

            // And it must not wobble cycle to cycle either.
            let cycle = max(64, Int(sr / hz))
            var lo = Double.infinity, hi = 0.0
            var i = start
            while i + cycle < n {
                let r = rms(buf[i ..< i + cycle])
                lo = min(lo, r); hi = max(hi, r)
                i += cycle
            }
            XCTAssertLessThan(20 * log10(hi / max(lo, 1e-12)), 0.5,
                              "steady \(Int(hz)) Hz is being amplitude-modulated")
        }
    }

    // MARK: - It punches

    func test_kickAttackIsLifted_moreThanTheDecayBehindIt() {
        let core = makeCore(state(attack: 1.0, strength: 1.0))

        // Kick every 500 ms over a quiet sustained bed.
        let n = Int(sr * 3)
        var input = [Float](repeating: 0, count: n)
        for i in 0 ..< n {
            let t = Double(i) / sr
            var v = 0.05 * sin(2 * .pi * 55 * t)
            let inBeat = t.truncatingRemainder(dividingBy: 0.5)
            if inBeat < 0.12 {
                v += 0.6 * exp(-inBeat * 30) * sin(2 * .pi * 60 * inBeat)
            }
            input[i] = Float(v)
        }
        var buf = input
        core.process(&buf)

        let kick = Int(sr * 2.0)
        let attackWin = kick ..< (kick + Int(sr * 0.02))
        let gapWin = (kick + Int(sr * 0.30)) ..< (kick + Int(sr * 0.45))

        let attackDB = 20 * log10(rms(buf[attackWin]) / max(rms(input[attackWin]), 1e-12))
        let gapDB = 20 * log10(rms(buf[gapWin]) / max(rms(input[gapWin]), 1e-12))

        XCTAssertGreaterThan(attackDB, 1.0, "the kick attack was not emphasised")
        XCTAssertGreaterThan(attackDB, gapDB + 1.0,
                             "attack and sustain were lifted equally — that is a static EQ, not punch")
    }

    func test_sustainControl_trimsSteadyLowEnergyWhenRaised() {
        let neutral = makeCore(state(attack: 0.5, sustain: 0, strength: 1.0))
        let trimmed = makeCore(state(attack: 0.5, sustain: 1.0, strength: 1.0))
        let n = Int(sr * 2)
        let input = sine(0.5, 60, n)

        var a = input, b = input
        neutral.process(&a)
        trimmed.process(&b)

        let start = Int(sr * 0.6)
        let deltaDB = 20 * log10(rms(b[start...]) / rms(a[start...]))
        XCTAssertLessThan(deltaDB, -2.0, "sustain control did not trim (got \(deltaDB) dB)")
    }

    // MARK: - Stereo

    func test_bothChannelsReceiveIdenticalGain() {
        let core = makeCore(state(attack: 1.0, strength: 1.0), channels: 2)
        let n = Int(sr)
        var l = sine(0.5, 60, n)
        var r = l.map { $0 * 0.25 }
        let refL = l, refR = r
        processStereo(core, &l, &r)

        for i in Int(sr * 0.3) ..< n where abs(refR[i]) > 1e-4 {
            let gl = Double(l[i]) / Double(refL[i])
            let gr = Double(r[i]) / Double(refR[i])
            XCTAssertEqual(gl, gr, accuracy: 1e-6, "gain diverged between channels at \(i)")
        }
    }

    // MARK: - Gain computer

    func test_deadbandSuppressesRippleButNotRealTransients() {
        let core = makeCore(state(attack: 1.0, strength: 1.0))
        // Ripple-sized ratio: no response at all.
        XCTAssertEqual(core.decideGain(fast: 0.115, slow: 0.1), 1.0, accuracy: 1e-9)
        // A real kick: clear boost.
        XCTAssertGreaterThan(core.decideGain(fast: 0.4, slow: 0.1), 1.5)
    }

    func test_belowTheActivityFloor_nothingIsPunched() {
        let core = makeCore(state(attack: 1.0, strength: 1.0))
        // Silence and noise floors must not be shaped, whatever their ratio.
        XCTAssertEqual(core.decideGain(fast: 1e-6, slow: 1e-9), 1.0, accuracy: 1e-9)
    }

    // MARK: - Sustain / Rumble
    //
    // The mirror of Punch on the same kernel: boost when the ratio sags (a note
    // already decaying), soften when it spikes. The contract that matters most
    // is the first one — a steady note must not move, or the K-weighted style
    // level-matching in BassProcessorDSP silently stops holding.

    private func rumbleState(
        sustain: Double = 0.5,
        soften: Double = 0,
        strength: Double = 0.6,
        cutoff: Double = 55
    ) -> BassProcessorState {
        var s = BassProcessorState()
        s.style = .sustainRumble
        s.strength = strength
        s.cutoff = cutoff
        s.rumbleSustain = sustain
        s.rumbleSoften = soften
        return s.sanitized()
    }

    /// A plucked low note: fast onset, exponential decay — what Rumble is for.
    private func decayingNote(hz: Double, decay: Double, seconds: Double, amp: Double = 0.6) -> [Float] {
        (0 ..< Int(sr * seconds)).map { i in
            let t = Double(i) / sr
            return Float(amp * exp(-t * decay) * sin(2 * .pi * hz * t))
        }
    }

    func test_rumble_leavesASteadyToneAtExactlyItsOwnLevel() {
        for hz in [40.0, 55.0, 70.0, 90.0] {
            let core = makeCore(rumbleState(sustain: 1.0, strength: 1.0))
            let input = sine(0.5, hz, Int(sr * 3))
            var out = input
            core.process(&out)
            let start = Int(sr * 1.5)
            let delta = 20 * log10(rms(out[start...]) / rms(input[start...]))
            XCTAssertLessThan(abs(delta), 0.10,
                              "\(Int(hz)) Hz steady tone moved \(delta) dB — level matching is broken")
        }
    }

    func test_rumble_holdsUpTheTail_notTheWholeNote() {
        let input = decayingNote(hz: 55, decay: 3.0, seconds: 2.5)
        let off = makeCore(rumbleState(sustain: 0.001))
        let on = makeCore(rumbleState(sustain: 1.0, strength: 1.0))
        var a = input, b = input
        off.process(&a)
        on.process(&b)

        let early = Int(sr * 0.05) ..< Int(sr * 0.15)
        let tail = Int(sr * 1.2) ..< Int(sr * 2.0)
        let earlyDelta = 20 * log10(rms(b[early]) / max(rms(a[early]), 1e-12))
        let tailDelta = 20 * log10(rms(b[tail]) / max(rms(a[tail]), 1e-12))

        XCTAssertGreaterThan(tailDelta, 2.0, "the tail was not held up (got \(tailDelta) dB)")
        XCTAssertGreaterThan(tailDelta, earlyDelta + 2.0,
                             "the whole note was lifted equally — that is a louder EQ, not sustain")
    }

    func test_rumble_neverRaisesThePeak() {
        // The restore clamp: slow/fast is exactly the gain that returns a tail to
        // its own running average, so a decaying note can never be pushed above a
        // level it already reached. Without it the sustain stage could add gain
        // on top of a shape that is already at its headroom ceiling.
        let input = decayingNote(hz: 50, decay: 2.0, seconds: 3.0, amp: 0.9)
        let core = makeCore(rumbleState(sustain: 1.0, strength: 1.0))
        var out = input
        core.process(&out)
        let rise = 20 * log10(peak(out) / peak(input))
        XCTAssertLessThan(rise, 0.5, "sustain stage raised the peak by \(rise) dB")

        // And directly, at the gain law's most demanding point.
        let g = core.decideGain(fast: 0.01, slow: 0.5)
        XCTAssertLessThanOrEqual(g, 0.5 / 0.01 + 1e-9, "gain exceeded the restore ceiling")
    }

    func test_rumble_softensTheLeadingEdge() {
        // Regression guard for a real bug: softening needs its own smoothing
        // pair. Engaging a cut means the gain must FALL, and under the sustain
        // ballistics that takes 200 ms — measured at −0.085 dB over an onset,
        // i.e. nothing at all.
        let input = decayingNote(hz: 60, decay: 4.0, seconds: 1.5)
        let plain = makeCore(rumbleState(sustain: 0.001, soften: 0, strength: 1.0))
        let soft = makeCore(rumbleState(sustain: 0.001, soften: 1.0, strength: 1.0))
        var a = input, b = input
        plain.process(&a)
        soft.process(&b)

        let onset = Int(sr * 0.005) ..< Int(sr * 0.06)
        let delta = 20 * log10(rms(b[onset]) / max(rms(a[onset]), 1e-12))
        XCTAssertLessThan(delta, -1.0, "leading edge was not softened (got \(delta) dB)")
    }

    func test_rumble_deadbandClearsTheMeasuredRipple() {
        // Steady tones sit at a fast/slow ratio just above 1.05 with Rumble's
        // ballistics; the deadband must stay clear of that or held notes get
        // treated as decaying ones.
        XCTAssertLessThan(SustainRumbleTuning.decayOnsetRatio, 1.0)
        let core = makeCore(rumbleState(sustain: 1.0, strength: 1.0))
        XCTAssertEqual(core.decideGain(fast: 0.105, slow: 0.1), 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(core.decideGain(fast: 0.03, slow: 0.1), 1.2, "a real decay was ignored")
    }

    private func peak(_ b: [Float]) -> Double {
        b.reduce(0.0) { max($0, abs(Double($1))) }
    }

    // MARK: - Metering
    //
    // The Bass Style sheet draws a centre-anchored bar from these two values on a
    // fixed 9 dB scale. Three things must hold or the bar lies: it reads zero when
    // the stage is inert, it reports real movement when the stage works, and it
    // never exceeds the configured ceilings the scale is drawn from.

    func test_meter_readsZero_whenTheStageIsInert() {
        for style in [BassStyle.none, .naturalClean] {
            let core = makeCore(state(attack: 1.0, sustain: 1.0, style: style))
            var buf = sine(0.5, 60, 8_000)
            core.process(&buf)
            XCTAssertEqual(core.attackBoostDB, 0, "\(style.title) must not show punch activity")
            XCTAssertEqual(core.sustainTrimDB, 0, "\(style.title) must not show punch activity")
        }
    }

    func test_meter_reportsAttackBoost_onAKick_withinTheConfiguredCeiling() {
        let core = makeCore(state(attack: 1.0, strength: 1.0))
        var buf = kickPattern(seconds: 3)
        core.process(&buf)

        XCTAssertGreaterThan(core.attackBoostDB, 1.0, "meter showed no boost on a kick pattern")
        // The bar's full scale is maxAttackBoostDB; a reading past it would clip.
        XCTAssertLessThanOrEqual(
            core.attackBoostDB,
            TransientPunchTuning.maxAttackBoostDB + 1e-6,
            "meter exceeded the boost ceiling its scale is drawn from"
        )
    }

    func test_meter_reportsTrim_onlyWhenSustainControlIsRaised() {
        let n = Int(sr * 2)

        let off = makeCore(state(attack: 0.5, sustain: 0, strength: 1.0))
        var a = sine(0.5, 60, n)
        off.process(&a)
        XCTAssertEqual(off.sustainTrimDB, 0, "trim meter moved with sustain control off")

        let on = makeCore(state(attack: 0.5, sustain: 1.0, strength: 1.0))
        var b = sine(0.5, 60, n)
        on.process(&b)
        XCTAssertGreaterThan(on.sustainTrimDB, 3.0, "trim meter did not follow the sustain stage")
        XCTAssertLessThanOrEqual(
            on.sustainTrimDB,
            TransientPunchTuning.maxSustainTrimDB + 1e-6,
            "meter exceeded the trim ceiling"
        )
    }

    func test_meter_clearsOnReset() {
        let core = makeCore(state(attack: 1.0, strength: 1.0))
        var buf = kickPattern(seconds: 1)
        core.process(&buf)
        XCTAssertGreaterThan(core.attackBoostDB, 0)

        core.reset()
        XCTAssertEqual(core.attackBoostDB, 0, "stale meter value survived a track change")
        XCTAssertEqual(core.sustainTrimDB, 0, "stale meter value survived a track change")
    }

    /// Kicks every 500 ms over a quiet sustained bed — the same signal the gain
    /// tests use, factored out so the meter tests measure the identical case.
    private func kickPattern(seconds: Double) -> [Float] {
        let n = Int(sr * seconds)
        var out = [Float](repeating: 0, count: n)
        for i in 0 ..< n {
            let t = Double(i) / sr
            var v = 0.05 * sin(2 * .pi * 55 * t)
            let inBeat = t.truncatingRemainder(dividingBy: 0.5)
            if inBeat < 0.12 {
                v += 0.6 * exp(-inBeat * 30) * sin(2 * .pi * 60 * inBeat)
            }
            out[i] = Float(v)
        }
        return out
    }

    // MARK: - State migration

    func test_bassState_savedBeforePunchExisted_stillDecodes() throws {
        // BassProcessorState used synthesised Codable, which fails on a missing
        // key. Without the hand-written decoder, adding punch parameters would
        // have reset every existing user's Bass Style on upgrade.
        let old = """
        {"style":"transientPunch","strength":0.8,"cutoff":85,"postGain":-1.5}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(BassProcessorState.self, from: old)

        XCTAssertEqual(decoded.style, .transientPunch)
        XCTAssertEqual(decoded.strength, 0.8, accuracy: 1e-9)
        XCTAssertEqual(decoded.cutoff, 85, accuracy: 1e-9)
        XCTAssertEqual(decoded.postGain, -1.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.punchAttack, BassProcessorState().punchAttack, accuracy: 1e-9)
        // Sustain must default to neutral so upgrading cannot change anyone's level.
        XCTAssertEqual(decoded.punchSustain, 0, accuracy: 1e-9)
    }

    func test_bassState_roundTripsWithPunchParameters() throws {
        var s = state(attack: 0.75, sustain: 0.4, strength: 0.9, cutoff: 92)
        s.postGain = 2
        let back = try JSONDecoder().decode(
            BassProcessorState.self, from: JSONEncoder().encode(s)
        )
        XCTAssertEqual(s, back)
    }

    func test_sanitize_clampsPunchParameters() {
        var s = BassProcessorState()
        s.punchAttack = 9
        s.punchSustain = -4
        s.sanitize()
        XCTAssertTrue(BassProcessorState.punchAttackRange.contains(s.punchAttack))
        XCTAssertTrue(BassProcessorState.punchSustainRange.contains(s.punchSustain))
    }
}
