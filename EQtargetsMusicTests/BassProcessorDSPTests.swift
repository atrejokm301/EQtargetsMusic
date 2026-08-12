//
//  BassProcessorDSPTests.swift
//  EQtargetsMusicTests
//
//  Bass Style is level-matched by K-weighted loudness, bounded by a peak
//  ceiling. Response is re-derived from the *emitted* UnitParams (converting
//  bandwidth back to Q), so these validate what actually reaches AVAudioUnitEQ.
//

import XCTest
@testable import EQtargetsMusic

final class BassProcessorDSPTests: XCTestCase {

    private let sr = 48_000.0
    private let styles: [BassStyle] = [.transientPunch, .sustainRumble, .naturalClean]
    private let strengths = [0.1, 0.25, 0.5, 0.6, 0.8, 1.0]

    // MARK: - Helpers

    private func params(_ style: BassStyle, _ strength: Double, _ cutoff: Double, post: Double = 0)
        -> BassProcessorDSP.UnitParams {
        var s = BassProcessorState()
        s.style = style
        s.strength = strength
        s.cutoff = cutoff
        s.postGain = post
        return BassProcessorDSP.unitParams(from: s.sanitized(), sampleRate: sr)
    }

    /// Summed magnitude of the emitted bands at `f`, excluding globalGain.
    private func emittedDB(_ p: BassProcessorDSP.UnitParams, at f: Double) -> Double {
        var sum = 0.0
        for b in p.bands where !b.bypass {
            let isShelf = b.filterType == .lowShelf
            // AVAudioUnitEQ ignores bandwidth on shelves (fixed S = 1 → Q = 1/√2).
            let q = isShelf ? 1.0 / 2.0.squareRoot() : Fixtures.qFromBandwidth(b.bandwidth)
            let kind: Fixtures.RefBiquad.Kind = isShelf ? .lowShelf : .peak
            sum += Fixtures.RefBiquad(kind, frequency: Double(b.frequency),
                                      gainDB: Double(b.gain), q: q, sampleRate: sr)
                .magnitudeDB(at: f, sampleRate: sr)
        }
        return sum
    }

    private func netPeak(_ p: BassProcessorDSP.UnitParams) -> (db: Double, hz: Double) {
        guard !p.unitBypass else { return (0, 0) }
        var best = -Double.infinity, bestF = 0.0
        var f = 18.0
        while f <= 1_200 {
            let m = emittedDB(p, at: f) + Double(p.globalGain)
            if m > best { best = m; bestF = f }
            f *= 1.001
        }
        return (best, bestF)
    }

    /// K-weighted perceived loudness vs bypass.
    private func perceivedDB(_ p: BassProcessorDSP.UnitParams) -> Double {
        guard !p.unitBypass else { return 0 }
        var num = 0.0, den = 0.0
        var f = 20.0
        while f <= 20_000 {
            let w = pow(10, Fixtures.kWeightDB(f, sampleRate: sr) / 10)
            num += w * pow(10, (emittedDB(p, at: f) + Double(p.globalGain)) / 10)
            den += w
            f *= 1.01
        }
        return 10 * log10(num / den)
    }

    // MARK: - Tests

    /// The whole point: chips compare character, not volume.
    func testStylesArePerceptuallyLevelMatched() {
        for str in strengths where str < 0.8 {
            var loudness: [Double] = []
            for style in styles {
                let l = perceivedDB(params(style, str, style.recommendedCutoffHz ?? 120))
                loudness.append(l)
                XCTAssertEqual(l, 0, accuracy: 0.25,
                               "\(style.rawValue) not loudness-neutral at strength \(str)")
            }
            let spread = loudness.max()! - loudness.min()!
            XCTAssertLessThan(spread, 0.25, "perceptual spread \(spread) dB at strength \(str)")
        }
    }

    /// Above strength 0.8 the clipping ceiling legitimately pulls Rumble down.
    func testCeilingPullsDownOnlyTheBassHeaviestStyle() {
        XCTAssertEqual(perceivedDB(params(.transientPunch, 1.0, 85)), 0, accuracy: 0.25)
        XCTAssertEqual(perceivedDB(params(.naturalClean, 1.0, 120)), 0, accuracy: 0.25)
        XCTAssertLessThan(perceivedDB(params(.sustainRumble, 1.0, 55)), -0.5,
                          "Rumble at full strength should be ceiling-limited")
    }

    func testPeakNeverExceedsCeiling() {
        var worst = -Double.infinity
        for style in styles {
            for str in strengths {
                for fc in stride(from: 40.0, through: 250.0, by: 2.0) {
                    let n = netPeak(params(style, str, fc)).db
                    worst = max(worst, n)
                    XCTAssertLessThanOrEqual(
                        n, BassProcessorDSP.peakCeilingDB + 0.15,
                        "\(style.rawValue) str \(str) fc \(fc) exceeded ceiling at \(n) dB")
                }
            }
        }
        XCTAssertGreaterThan(worst, 0, "sanity: some setting should approach the ceiling")
    }

    /// Regression: Punch used to peak at 58 Hz — below Natural Clean's — despite
    /// being named for attack.
    func testTransientPunchPeaksInKickRegion() {
        for str in [0.4, 0.6, 1.0] {
            let hz = netPeak(params(.transientPunch, str, 85)).hz
            XCTAssertTrue((78 ... 125).contains(hz), "punch peak at \(hz) Hz, strength \(str)")
        }
        let punch = netPeak(params(.transientPunch, 0.6, 85)).hz
        let clean = netPeak(params(.naturalClean, 0.6, 120)).hz
        XCTAssertGreaterThan(punch, clean, "punch (\(punch) Hz) must sit above clean (\(clean) Hz)")
    }

    func testStylesRemainTonallyDistinct() {
        let rumble = params(.sustainRumble, 0.6, 55)
        XCTAssertGreaterThan(emittedDB(rumble, at: 25), emittedDB(rumble, at: 250) + 3,
                             "Rumble lost its low tilt")
        let punch = params(.transientPunch, 0.6, 85)
        XCTAssertGreaterThan(emittedDB(punch, at: 100), emittedDB(punch, at: 40) + 2,
                             "Punch lost its kick-region emphasis")
    }

    func testOffAndZeroStrengthFullyBypass() {
        for p in [params(.none, 0.8, 120), params(.sustainRumble, 0, 55)] {
            XCTAssertTrue(p.unitBypass)
            XCTAssertEqual(p.globalGain, 0)
            XCTAssertTrue(p.bands.allSatisfy(\.bypass))
        }
    }

    func testPostGainIsPurelyAdditive() {
        for style in styles {
            let base = params(style, 0.6, style.recommendedCutoffHz ?? 120).globalGain
            for post in [-12.0, -6.0, 3.0, 6.0] {
                let g = params(style, 0.6, style.recommendedCutoffHz ?? 120, post: post).globalGain
                XCTAssertEqual(Double(g - base), post, accuracy: 0.001,
                               "post gain not additive for \(style.rawValue)")
            }
        }
    }

    func testStateSanitizingClamps() {
        var high = BassProcessorState()
        high.strength = 9; high.cutoff = 9_999; high.postGain = 99
        high.sanitize()
        XCTAssertEqual(high.strength, 1)
        XCTAssertEqual(high.cutoff, 250)
        XCTAssertEqual(high.postGain, 6)

        var low = BassProcessorState()
        low.strength = -5; low.cutoff = -5; low.postGain = -99
        low.sanitize()
        XCTAssertEqual(low.strength, 0)
        XCTAssertEqual(low.cutoff, 40)
        XCTAssertEqual(low.postGain, -12)
    }

    /// unitParams sweeps the response on every call and applyBass calls it once
    /// per deck, at UI drag rate. Bound sits between the cached cost and the cost
    /// with K-weight caching removed, so dropping that cache fails here.
    func testUnitParamsStaysCheapEnoughForDragRate() {
        let iterations = 5_000
        let per = Fixtures.bestOf(5) {
            var sink = 0.0
            for i in 0 ..< iterations {
                let p = self.params(self.styles[i % 3], Double(i % 100) / 100.0, 40 + Double(i % 210))
                sink += Double(p.globalGain)
            }
            XCTAssertFalse(sink.isNaN)
        } / Double(iterations)
        let perChange = per * 2 * 1e6   // two decks
        XCTAssertLessThan(perChange, 400, "unitParams too slow for drag-rate calls: \(perChange) µs")
    }
}
