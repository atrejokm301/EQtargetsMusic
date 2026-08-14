//
//  LimiterDSPTests.swift
//  EQtargetsMusicTests
//
//  The limiter's contract, not its internals:
//    • the ceiling is never exceeded, whatever is fed in;
//    • gain reduction is engaged *before* the peak reaches the output
//      (that is the whole point of the lookahead);
//    • quiet material passes through untouched, sample for sample;
//    • release adapts to sustained loudness rather than running fixed;
//    • stereo stays linked so the image cannot shift.
//
//  All of it drives `LimiterDSPCore` directly with plain buffers — no engine,
//  no AVAudioSession, no timing dependence.
//

import XCTest
import AudioToolbox
@testable import EQtargetsMusic

final class LimiterDSPTests: XCTestCase {

    private let sr = 48_000.0

    // MARK: - Helpers

    private func makeCore(
        _ state: LimiterState,
        channels: Int = 1,
        sampleRate: Double? = nil
    ) -> LimiterDSPCore {
        let rate = sampleRate ?? sr
        let core = LimiterDSPCore()
        core.prepare(sampleRate: rate, channelCount: channels)
        core.update(LimiterCoefficients.make(from: state, sampleRate: rate))
        return core
    }

    private func lookaheadSamples(_ state: LimiterState, sampleRate: Double? = nil) -> Int {
        LimiterCoefficients.make(from: state, sampleRate: sampleRate ?? sr).lookaheadSamples
    }

    private func processStereo(_ core: LimiterDSPCore, _ left: inout [Float], _ right: inout [Float]) {
        precondition(left.count == right.count)
        let n = left.count
        left.withUnsafeMutableBufferPointer { lb in
            right.withUnsafeMutableBufferPointer { rb in
                var ptrs = [lb.baseAddress!, rb.baseAddress!]
                ptrs.withUnsafeMutableBufferPointer { pb in
                    core.process(channels: pb, frameCount: n)
                }
            }
        }
    }

    private func sine(amplitude: Float, hz: Double, count: Int, sampleRate: Double? = nil) -> [Float] {
        let rate = sampleRate ?? sr
        return (0 ..< count).map { i in
            amplitude * Float(sin(2 * Double.pi * hz * Double(i) / rate))
        }
    }

    private func peak(_ buf: [Float]) -> Double {
        Double(buf.map { abs($0) }.max() ?? 0)
    }

    private func linear(_ db: Double) -> Double { pow(10, db / 20) }

    /// A limiter that is on, with makeup out of the way unless a test wants it.
    private func baseState(
        threshold: Double = -20,
        ratio: Double = 20,
        ceiling: Double = -1,
        lookaheadMs: Double = 5,
        releaseMs: Double = 100,
        knee: Double = 0
    ) -> LimiterState {
        var s = LimiterState()
        s.isEnabled = true
        s.autoMakeup = false
        s.postGainDB = 0
        s.thresholdDB = threshold
        s.ratio = ratio
        s.ceilingDB = ceiling
        s.lookaheadMs = lookaheadMs
        s.releaseMs = releaseMs
        s.kneeDB = knee
        s.attackMs = 1
        return s.sanitized()
    }

    // MARK: - Ceiling is a guarantee

    func test_ceiling_isNeverExceeded_forEveryGenrePreset() {
        for genre in LimiterGenre.allCases {
            let state = genre.state
            let core = makeCore(state)
            // Deliberately hotter than full scale: the EQ stages upstream can
            // and do push past 0 dBFS before this stage sees the signal.
            var buf = sine(amplitude: 2.0, hz: 220, count: Int(sr))
            core.process(&buf)

            let ceiling = linear(state.ceilingDB)
            XCTAssertLessThanOrEqual(
                peak(buf), ceiling + 1e-4,
                "\(genre.title) let \(peak(buf)) through a \(state.ceilingDB) dB ceiling"
            )
        }
    }

    func test_ceiling_isNeverExceeded_onImpulseTrain() {
        // Isolated full-scale impulses on a quiet bed — the classic overshoot case.
        let state = baseState(threshold: -24, ratio: 20, ceiling: -1)
        let core = makeCore(state)
        var buf = [Float](repeating: 0.02, count: 48_000)
        for i in stride(from: 1_000, to: buf.count, by: 4_000) {
            buf[i] = 1.0
            buf[i + 1] = -1.0
        }
        core.process(&buf)
        XCTAssertLessThanOrEqual(peak(buf), linear(-1) + 1e-4)
    }

    func test_ceiling_isNeverExceeded_whenAutoMakeupIsAggressive() {
        // Auto makeup must be bounded by the ceiling, not applied on top of it.
        var state = baseState(threshold: -30, ratio: 20, ceiling: -3)
        state.autoMakeup = true
        XCTAssertGreaterThan(state.effectiveMakeupDB, 0, "expected auto makeup to be non-trivial here")

        let core = makeCore(state)
        var buf = sine(amplitude: 1.0, hz: 440, count: Int(sr))
        core.process(&buf)
        XCTAssertLessThanOrEqual(peak(buf), linear(-3) + 1e-4)
    }

    // MARK: - Lookahead

    func test_lookahead_reducesGainBeforeThePeakReachesTheOutput() {
        // Quiet bed, then a sudden full-scale block. With lookahead, the samples
        // emitted *while the loud block is still inside the delay line* are
        // already attenuated. Without lookahead they would be untouched.
        let state = baseState(threshold: -20, ratio: 20, lookaheadMs: 5)
        let look = lookaheadSamples(state)
        XCTAssertGreaterThan(look, 10, "test needs a meaningful lookahead window")

        let quiet: Float = 0.05
        let onset = 4_000
        var buf = [Float](repeating: quiet, count: 12_000)
        for i in onset ..< buf.count { buf[i] = 1.0 }
        core_process(state: state, buffer: &buf)

        // Output index `onset` still carries quiet input (input[onset - look]),
        // but the detector has already seen the loud block.
        let midWindow = onset + look / 2
        XCTAssertLessThan(
            abs(buf[midWindow]), quiet * 0.9,
            "quiet audio inside the lookahead window was not pre-attenuated"
        )
    }

    func test_withoutLookaheadWindow_theSameSamplesAreUntouched() {
        // Control for the test above: at the shortest lookahead the pre-onset
        // samples are essentially unattenuated, which is what makes the
        // lookahead result meaningful rather than a side effect of the ratio.
        let state = baseState(threshold: -20, ratio: 20, lookaheadMs: 0.5)
        let look = lookaheadSamples(state)

        let quiet: Float = 0.05
        let onset = 4_000
        var buf = [Float](repeating: quiet, count: 12_000)
        for i in onset ..< buf.count { buf[i] = 1.0 }
        core_process(state: state, buffer: &buf)

        let beforeWindow = onset - look - 50
        XCTAssertEqual(Double(abs(buf[beforeWindow])), Double(quiet), accuracy: 1e-5)
    }

    private func core_process(state: LimiterState, buffer: inout [Float]) {
        let core = makeCore(state)
        core.process(&buffer)
    }

    // MARK: - Transparency below threshold

    func test_belowThreshold_signalPassesThroughUnchangedApartFromDelay() {
        let state = baseState(threshold: -6, ratio: 20, ceiling: -1)
        let look = lookaheadSamples(state)
        let input = sine(amplitude: 0.1, hz: 300, count: 8_000)   // −20 dBFS
        var buf = input
        makeCore(state).process(&buf)

        for n in (look + 10) ..< buf.count {
            XCTAssertEqual(
                Double(buf[n]), Double(input[n - look]), accuracy: 1e-6,
                "sample \(n) was altered despite sitting below the threshold"
            )
        }
    }

    func test_bypass_isExactPassthroughWithConstantDelay() {
        var state = baseState()
        state.isEnabled = false
        let look = lookaheadSamples(state)

        var generator = SystemRandomNumberGenerator()
        let input = (0 ..< 4_000).map { _ in Float.random(in: -1 ... 1, using: &generator) }
        var buf = input
        makeCore(state).process(&buf)

        for n in look ..< buf.count {
            XCTAssertEqual(Double(buf[n]), Double(input[n - look]), accuracy: 1e-6)
        }
    }

    func test_nodeBypassAndCoefficientBypassDoNotCancelEachOtherOut() {
        // Regression: `LimiterDSP.apply` sets `unit.bypass = false` on purpose
        // so the delay line keeps running and latency stays constant. An
        // earlier version folded that node-level flag into the pending
        // coefficients, which cleared the *disabled* limiter's own bypass and
        // left the stage processing audio the user had switched off.
        var disabled = baseState(threshold: -20, ratio: 20)
        disabled.isEnabled = false

        let core = makeCore(disabled)
        core.bypassOverride = false          // what `unit.bypass = false` produces

        let look = lookaheadSamples(disabled)
        let input = sine(amplitude: 1.0, hz: 220, count: 8_000)   // well over threshold
        var buf = input
        core.process(&buf)

        for n in (look + 10) ..< buf.count {
            XCTAssertEqual(
                Double(buf[n]), Double(input[n - look]), accuracy: 1e-6,
                "a disabled limiter altered sample \(n)"
            )
        }
    }

    func test_nodeBypassAloneSilencesProcessingEvenWhenEnabled() {
        var enabled = baseState(threshold: -20, ratio: 20)
        enabled.isEnabled = true

        let core = makeCore(enabled)
        core.bypassOverride = true           // host bypassed the node

        let look = lookaheadSamples(enabled)
        let input = sine(amplitude: 1.0, hz: 220, count: 8_000)
        var buf = input
        core.process(&buf)

        for n in (look + 10) ..< buf.count {
            XCTAssertEqual(Double(buf[n]), Double(input[n - look]), accuracy: 1e-6)
        }
    }

    func test_kernel_disabledLimiterStaysSilentWhenTheNodeIsUnBypassed() throws {
        // Replays exactly what `LimiterDSP.apply` does to a disabled limiter:
        //   setCoefficients(bypass: true)  then  unit.bypass = false
        // Verified to fail (19 dB of gain reduction on a limiter that is off)
        // against the version where setBypass folded into the coefficients.
        var disabled = baseState(threshold: -20, ratio: 20)
        disabled.isEnabled = false
        let coeffs = LimiterCoefficients.make(from: disabled, sampleRate: sr)
        XCTAssertTrue(coeffs.bypass)

        let kernel = LimiterKernel()
        kernel.prepare(sampleRate: sr, channelCount: 1, maxFrames: 4096)
        kernel.setCoefficients(coeffs)
        kernel.setBypass(false)

        let frames = 4096
        let input = sine(amplitude: 1.0, hz: 220, count: frames)
        var work = input
        let abl = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(abl.unsafeMutablePointer) }

        work.withUnsafeMutableBufferPointer { wb in
            abl[0] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(wb.baseAddress!)
            )
            kernel.process(bufferList: abl.unsafeMutablePointer, frameCount: frames)
        }

        let look = coeffs.lookaheadSamples
        for n in (look + 10) ..< frames {
            XCTAssertEqual(Double(work[n]), Double(input[n - look]), accuracy: 1e-6,
                           "a switched-off limiter processed sample \(n)")
        }
        XCTAssertEqual(kernel.gainReductionDB, 0, accuracy: 1e-9)
    }

    func test_switchingOffAfterHeavyReduction_returnsToUnityPromptlyWithoutJumping() {
        // Toggling the limiter off mid-reduction must not inherit the
        // program-dependent release — after a loud passage that stretches to
        // seconds, so the switch would feel broken. It also must not jump,
        // which would pop. Expect a short ramp.
        var on = baseState(threshold: -20, ratio: 20, releaseMs: 1_000)
        on.isEnabled = true
        let core = makeCore(on)

        // Drive it into deep, sustained reduction.
        var loud = [Float](repeating: 1.0, count: 96_000)
        core.process(&loud)
        XCTAssertGreaterThan(core.gainReductionDB, 10, "setup: expected heavy reduction")

        // Now switch off and feed a quiet bed.
        var off = on
        off.isEnabled = false
        core.update(LimiterCoefficients.make(from: off, sampleRate: sr))

        let quiet: Float = 0.2
        var tail = [Float](repeating: quiet, count: Int(sr / 2))   // 500 ms
        core.process(&tail)

        let look = lookaheadSamples(off)
        // No jump: the first emitted sample must not already be at full level.
        XCTAssertLessThan(Double(abs(tail[look + 1])), Double(quiet) * 0.9,
                          "gain jumped straight to unity — that pops")

        // Prompt: back to unity well inside 150 ms.
        let deadline = look + Int(sr * 0.15)
        XCTAssertGreaterThanOrEqual(
            Double(abs(tail[deadline])), Double(quiet) * 0.99,
            "still fading up 150 ms after being switched off"
        )
    }

    // MARK: - Program-dependent release

    func test_release_isSlowerAfterSustainedLoudnessThanAfterABriefTransient() {
        let state = baseState(threshold: -20, ratio: 20, releaseMs: 100)
        let quiet: Float = 0.01
        let tail = 24_000

        let look = lookaheadSamples(state)

        func recoverySamples(burstSamples: Int) -> Int {
            var buf = [Float](repeating: 1.0, count: burstSamples)
            buf.append(contentsOf: [Float](repeating: quiet, count: tail))
            makeCore(state).process(&buf)

            // Start measuring only once the loud block has fully drained out of
            // the lookahead delay line — before that the output still carries
            // burst audio and would match immediately.
            let start = burstSamples + look
            let target = Double(quiet) * 0.95
            for n in start ..< buf.count where Double(abs(buf[n])) >= target {
                return n - start
            }
            return buf.count
        }

        let shortBurst = recoverySamples(burstSamples: 240)      // 5 ms
        let longBurst = recoverySamples(burstSamples: 96_000)    // 2 s

        XCTAssertLessThan(shortBurst, longBurst,
                          "a 5 ms transient should recover faster than 2 s of sustained loudness")
        XCTAssertGreaterThan(Double(longBurst) / Double(max(shortBurst, 1)), 1.5,
                             "the two release behaviours are too close to be program-dependent")
    }

    // MARK: - Stereo linking

    func test_stereo_gainIsLinkedSoTheImageDoesNotShift() {
        let state = baseState(threshold: -20, ratio: 12)
        let core = makeCore(state, channels: 2)

        // Constant 4:1 level difference between channels.
        var left = sine(amplitude: 1.0, hz: 200, count: 12_000)
        var right = left.map { $0 * 0.25 }
        processStereo(core, &left, &right)

        let look = lookaheadSamples(state)
        for n in (look + 100) ..< left.count {
            guard abs(right[n]) > 1e-4 else { continue }
            XCTAssertEqual(Double(left[n] / right[n]), 4.0, accuracy: 0.02,
                           "channel ratio drifted at sample \(n) — gain is not linked")
        }
    }

    // MARK: - Static curve

    func test_staticCurve_isFlatBelowThresholdAndFollowsTheRatioAbove() {
        let state = baseState(threshold: -20, ratio: 4, ceiling: 0, knee: 0)
        let core = makeCore(state)

        XCTAssertEqual(core.staticGainDB(forInputDB: -40), 0, accuracy: 1e-9)
        XCTAssertEqual(core.staticGainDB(forInputDB: -21), 0, accuracy: 1e-9)
        // 10 dB over a 4:1 threshold → 7.5 dB of reduction.
        XCTAssertEqual(core.staticGainDB(forInputDB: -10), -7.5, accuracy: 1e-6)
    }

    func test_staticCurve_softKneeEasesInEarlyAndRejoinsTheHardCurve() {
        // The knee spans threshold ± width/2, i.e. −24…−16 dB here. A correct
        // soft knee starts reducing *before* the threshold and has converged
        // back onto the hard-knee line by the top of the knee — that is what
        // makes the transition smooth rather than a corner.
        let threshold = -20.0, knee = 8.0
        let hard = makeCore(baseState(threshold: threshold, ratio: 8, ceiling: 0, knee: 0))
        let soft = makeCore(baseState(threshold: threshold, ratio: 8, ceiling: 0, knee: knee))

        var previous = 0.0
        for db in stride(from: -40.0, through: -1.0, by: 0.25) {
            let g = soft.staticGainDB(forInputDB: db)
            XCTAssertLessThanOrEqual(g, previous + 1e-9, "soft knee curve is not monotonic at \(db) dB")
            previous = g
        }

        // Below the knee: both inert.
        XCTAssertEqual(soft.staticGainDB(forInputDB: threshold - knee / 2), 0, accuracy: 1e-9)
        // At the threshold: soft is already working, hard has not started.
        XCTAssertLessThan(soft.staticGainDB(forInputDB: threshold), -0.1)
        XCTAssertEqual(hard.staticGainDB(forInputDB: threshold), 0, accuracy: 1e-9)
        // At the top of the knee: the two curves meet.
        XCTAssertEqual(
            soft.staticGainDB(forInputDB: threshold + knee / 2),
            hard.staticGainDB(forInputDB: threshold + knee / 2),
            accuracy: 1e-6
        )
    }

    func test_staticCurve_enforcesTheCeilingEvenWhenTheRatioAloneWouldNot() {
        // Ratio 1.5:1 leaves plenty above the ceiling — the ceiling term must
        // take over and pull the projected output down to it.
        let state = baseState(threshold: -20, ratio: 1.5, ceiling: -1)
        let core = makeCore(state)
        let gain = core.staticGainDB(forInputDB: 0)
        XCTAssertLessThanOrEqual(0 + gain, -1 + 1e-9)
    }

    // MARK: - Sliding peak detector

    func test_slidingPeakDetector_matchesBruteForceMaximum() {
        let window = 37
        let detector = SlidingPeakDetector()
        detector.prepare(capacity: 256)
        detector.setWindow(window)

        var generator = SystemRandomNumberGenerator()
        let input = (0 ..< 2_000).map { _ in Float.random(in: 0 ... 1, using: &generator) }

        for i in input.indices {
            let got = detector.push(input[i])
            let lower = max(0, i - window + 1)
            let expected = input[lower ... i].max()!
            XCTAssertEqual(got, expected, accuracy: 1e-6, "window maximum wrong at \(i)")
        }
    }

    func test_slidingPeakDetector_shrinkingWindowDropsStalePeaks() {
        let detector = SlidingPeakDetector()
        detector.prepare(capacity: 256)
        detector.setWindow(100)

        _ = detector.push(1.0)                       // the stale peak
        for _ in 0 ..< 50 { _ = detector.push(0.1) }

        // Still inside a 100-sample window.
        XCTAssertEqual(detector.push(0.1), 1.0, accuracy: 1e-6)

        // Shrink so the old peak falls out; it must not keep pinning the gain.
        detector.setWindow(10)
        XCTAssertEqual(detector.push(0.1), 0.1, accuracy: 1e-6)
    }

    // MARK: - State validation

    func test_sanitize_clampsEveryParameterIntoRange() {
        var s = LimiterState()
        s.ceilingDB = 40
        s.thresholdDB = -900
        s.ratio = 1_000
        s.kneeDB = -5
        s.attackMs = 5_000
        s.releaseMs = 0
        s.lookaheadMs = 900
        s.postGainDB = 99
        s.sanitize()

        XCTAssertTrue(LimiterState.ceilingRange.contains(s.ceilingDB))
        XCTAssertTrue(LimiterState.thresholdRange.contains(s.thresholdDB))
        XCTAssertTrue(LimiterState.ratioRange.contains(s.ratio))
        XCTAssertTrue(LimiterState.kneeRange.contains(s.kneeDB))
        XCTAssertTrue(LimiterState.attackMsRange.contains(s.attackMs))
        XCTAssertTrue(LimiterState.releaseMsRange.contains(s.releaseMs))
        XCTAssertTrue(LimiterState.lookaheadMsRange.contains(s.lookaheadMs))
        XCTAssertTrue(LimiterState.postGainRange.contains(s.postGainDB))
    }

    func test_sanitize_pullsAThresholdAboveTheCeilingBackUnderIt() {
        var s = LimiterState()
        s.ceilingDB = -6
        s.thresholdDB = -2      // above the ceiling — could never engage
        s.sanitize()
        XCTAssertLessThanOrEqual(s.thresholdDB, s.ceilingDB)
    }

    func test_attackIsClampedToTheLookaheadWindow() {
        // A 50 ms attack inside a 1 ms window would leave the envelope still
        // travelling when the peak lands, so the coefficient must be rebuilt
        // against the window, not the requested time.
        var s = baseState(lookaheadMs: 1)
        s.attackMs = 50
        let c = LimiterCoefficients.make(from: s, sampleRate: sr)
        let windowMs = Double(c.lookaheadSamples) / sr * 1000
        let expected = LimiterCoefficients.onePole(timeMs: windowMs, sampleRate: sr)
        XCTAssertEqual(c.attackCoef, expected, accuracy: 1e-9)
    }

    // MARK: - v1 migration

    func test_decoding_v1State_keepsManualMakeupAndFillsV2Defaults() throws {
        // Exactly what the shipped v1 limiter wrote to `eqtargets.limiter`.
        let v1 = """
        {"isEnabled":true,"thresholdDB":-12,"ratio":8,"attackMs":5,"releaseMs":80,"postGainDB":3}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LimiterState.self, from: v1)

        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.thresholdDB, -12, accuracy: 1e-9)
        XCTAssertEqual(decoded.ratio, 8, accuracy: 1e-9)
        XCTAssertEqual(decoded.postGainDB, 3, accuracy: 1e-9)
        // v1 had no auto makeup; honouring the saved postGain matters more than
        // the new default, otherwise upgrading silently changes people's levels.
        XCTAssertFalse(decoded.autoMakeup)
        XCTAssertEqual(decoded.effectiveMakeupDB, 3, accuracy: 1e-9)
        // v2-only fields fall back to defaults.
        XCTAssertEqual(decoded.ceilingDB, LimiterState.flat.ceilingDB, accuracy: 1e-9)
        XCTAssertEqual(decoded.kneeDB, LimiterState.flat.kneeDB, accuracy: 1e-9)
        XCTAssertEqual(decoded.lookaheadMs, LimiterState.flat.lookaheadMs, accuracy: 1e-9)
    }

    func test_roundTrip_v2StatePreservesAutoMakeupFlag() throws {
        var s = LimiterGenre.rock.state
        s.autoMakeup = true
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(LimiterState.self, from: data)
        XCTAssertEqual(s, back)
        XCTAssertTrue(back.autoMakeup)
    }

    // MARK: - Genre presets

    func test_everyGenrePreset_isUsableAsShipped() {
        for genre in LimiterGenre.allCases {
            let s = genre.state
            XCTAssertTrue(s.isEnabled, "\(genre.title) ships disabled")
            XCTAssertEqual(s, s.sanitized(), "\(genre.title) has out-of-range values")
            XCTAssertLessThanOrEqual(s.thresholdDB, s.ceilingDB,
                                     "\(genre.title) threshold sits above its ceiling")
            XCTAssertFalse(genre.compactTitle.isEmpty)
            XCTAssertFalse(genre.subtitle.isEmpty)
        }
    }

    func test_genrePresets_areDistinctFromOneAnother() {
        let states = LimiterGenre.allCases.map(\.state)
        for i in states.indices {
            for j in states.indices where j > i {
                XCTAssertFalse(
                    states[i].matchesParameters(of: states[j]),
                    "\(LimiterGenre.allCases[i].title) and \(LimiterGenre.allCases[j].title) are identical"
                )
            }
        }
    }

    func test_spokenPresetLevelsHarderThanThePopSafetyNet() {
        // The two ends of the shipped range — if this inverts, the presets are
        // mislabelled regardless of whether each one is individually valid.
        let spoken = LimiterGenre.podcast.state
        let pop = LimiterGenre.pop.state
        XCTAssertLessThan(spoken.thresholdDB, pop.thresholdDB)
        XCTAssertGreaterThan(spoken.ratio, pop.ratio)
    }

    func test_adoracionIsTheGentlestPresetAndLeavesQuietPassagesAlone() {
        // Adoración exists to preserve the dynamics of intimate worship. If it
        // ever reduces more than another preset at conversational level, the
        // threshold has drifted down and it is no longer doing its job.
        func reduction(_ genre: LimiterGenre, at inputDB: Double) -> Double {
            -makeCore(genre.state).staticGainDB(forInputDB: inputDB)
        }

        for other in LimiterGenre.allCases where other != .adoracion {
            XCTAssertLessThanOrEqual(
                reduction(.adoracion, at: -6), reduction(other, at: -6) + 1e-9,
                "Adoración compresses harder than \(other.title) at −6 dBFS"
            )
        }
        XCTAssertLessThan(reduction(.adoracion, at: -12), 0.01,
                          "Adoración should be inert on quiet passages")
    }

    func test_jubiloControlsLoudPraiseHarderThanAdoracion() {
        func reduction(_ genre: LimiterGenre, at inputDB: Double) -> Double {
            -makeCore(genre.state).staticGainDB(forInputDB: inputDB)
        }
        XCTAssertGreaterThan(reduction(.jubilo, at: 0), reduction(.adoracion, at: 0))
    }

    func test_matchesParameters_ignoresEnabledButCatchesRealEdits() {
        var a = LimiterGenre.edm.state
        var b = a
        b.isEnabled = !a.isEnabled
        XCTAssertTrue(a.matchesParameters(of: b), "enable state should not count as a parameter edit")

        a.thresholdDB -= 2
        XCTAssertFalse(a.matchesParameters(of: b))
    }
}
