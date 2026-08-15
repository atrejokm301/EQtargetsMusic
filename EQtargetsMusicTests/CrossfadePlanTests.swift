//
//  CrossfadePlanTests.swift
//  EQtargetsMusicTests
//
//  Curve level behaviour, and the plan explaining itself honestly to the UI.
//

import XCTest
@testable import EQtargetsMusic

final class CrossfadePlanTests: XCTestCase {

    private func plan(
        _ seconds: Int,
        out: TimeInterval = 300,
        inn: TimeInterval = 300,
        remaining: TimeInterval? = nil,
        outBPM: Double? = nil,
        inBPM: Double? = nil,
        adaptive: Bool = false,
        curve: CrossfadeCurve = .equalPower
    ) -> CrossfadePlan {
        CrossfadeMath.plan(
            settings: CrossfadeSettings(durationSeconds: seconds, adaptiveBPM: adaptive, curve: curve),
            outgoingPlayable: out,
            incomingPlayable: inn,
            outgoingRemaining: remaining,
            outgoingBPM: outBPM,
            incomingBPM: inBPM
        )
    }

    // MARK: - Curves

    /// Equal Power and Smooth must hold uncorrelated level flat across the fade.
    func testConstantPowerCurves() {
        for curve in [CrossfadeCurve.equalPower, .smooth] {
            for i in 0 ... 1_000 {
                let g = CrossfadeMath.gains(progress: Double(i) / 1_000, curve: curve)
                let power = Double(g.out * g.out + g.inn * g.inn)
                XCTAssertEqual(power, 1.0, accuracy: 0.001,
                               "\(curve.rawValue) is not constant power at \(Double(i) / 1000)")
            }
        }
    }

    /// Linear dips ~3 dB at the midpoint — documented, and why it exists.
    func testLinearDipsAtMidpoint() {
        let mid = CrossfadeMath.gains(progress: 0.5, curve: .linear)
        let power = Double(mid.out * mid.out + mid.inn * mid.inn)
        XCTAssertEqual(10 * log10(power), -3.01, accuracy: 0.05)
        // ...but sums to unity in amplitude, which is correct for correlated material.
        XCTAssertEqual(Double(mid.out + mid.inn), 1.0, accuracy: 0.001)
    }

    func testCurveEndpoints() {
        for curve in CrossfadeCurve.allCases {
            let start = CrossfadeMath.gains(progress: 0, curve: curve)
            let end = CrossfadeMath.gains(progress: 1, curve: curve)
            XCTAssertEqual(start.out, 1, accuracy: 0.001, "\(curve.rawValue) start")
            XCTAssertEqual(start.inn, 0, accuracy: 0.001, "\(curve.rawValue) start")
            XCTAssertEqual(end.out, 0, accuracy: 0.001, "\(curve.rawValue) end")
            XCTAssertEqual(end.inn, 1, accuracy: 0.001, "\(curve.rawValue) end")
        }
        // Out of range progress must clamp, not extrapolate.
        XCTAssertEqual(CrossfadeMath.gains(progress: -5, curve: .equalPower).out, 1, accuracy: 0.001)
        XCTAssertEqual(CrossfadeMath.gains(progress: 5, curve: .equalPower).inn, 1, accuracy: 0.001)
    }

    // MARK: - Caps

    func testEffectiveFadeNeverExceedsRemaining() {
        for rem in stride(from: 0.1, through: 20.0, by: 0.1) {
            for asked in [1, 3, 10, 30, 60] {
                let p = plan(asked, remaining: rem)
                XCTAssertLessThanOrEqual(p.effective, rem,
                                         "asked \(asked)s with \(rem)s left gave \(p.effective)s")
            }
        }
    }

    func testTooLateFadeHardCuts() {
        let p = plan(30, remaining: 0.3)
        XCTAssertFalse(p.isEnabled, "should hard-cut, not fade")
        XCTAssertEqual(p.effective, 0)
    }

    // MARK: - The plan explains itself

    func testCleanPlanReportsNoAdjustment() {
        let p = plan(5)
        XCTAssertFalse(p.differsFromRequest)
        XCTAssertNil(p.adjustmentSummary)
        XCTAssertNil(p.adjustmentReason)
    }

    /// At >= 12s Equal Power is substituted with Smooth. The UI showed the
    /// setting, so this was invisible at the recommended 30s setup.
    func testLongEqualPowerFadeSubstitutesSmooth() {
        let p = plan(30)
        XCTAssertTrue(p.curveWasSubstituted)
        XCTAssertEqual(p.requestedCurve, .equalPower)
        XCTAssertEqual(p.curve, .smooth)
        XCTAssertEqual(p.adjustmentSummary, "Smooth")
        XCTAssertEqual(p.adjustmentReason, "long blends use softer knees")

        // Just below the threshold nothing changes.
        XCTAssertFalse(plan(11).curveWasSubstituted)
    }

    func testExplicitCurvesAreNeverSubstituted() {
        XCTAssertFalse(plan(30, curve: .smooth).curveWasSubstituted)
        XCTAssertEqual(plan(30, curve: .linear).curve, .linear,
                       "Linear must survive long durations")
    }

    func testTempoClashShortensAndExplains() {
        let p = plan(30, outBPM: 75, inBPM: 140, adaptive: true)
        XCTAssertTrue(p.durationWasReduced)
        XCTAssertLessThan(p.tempoScale, 0.98)
        XCTAssertEqual(p.adjustmentReason?.contains("tempo"), true,
                       "reason should cite tempo, got \(p.adjustmentReason ?? "nil")")
        // Same lane, close tempo — no shortening.
        XCTAssertFalse(plan(30, outBPM: 128, inBPM: 132, adaptive: true).durationWasReduced)
    }

    func testShortTrackCapsExplainThemselves() {
        let shortOut = plan(30, out: 10)
        XCTAssertTrue(shortOut.cappedByOutgoing)
        XCTAssertEqual(shortOut.adjustmentReason, "this track is short")

        let shortIn = plan(30, inn: 8)
        XCTAssertTrue(shortIn.cappedByIncoming)
        XCTAssertEqual(shortIn.adjustmentReason, "next track is short")
    }

    /// Running out of track is the most specific cause and must win.
    func testRemainingIsTheMostSpecificReason() {
        let p = plan(30, remaining: 5)
        XCTAssertTrue(p.cappedByRemaining)
        XCTAssertEqual(p.adjustmentReason, "not enough of this track left")
    }

    func testDisabledPlansClaimNothing() {
        XCTAssertNil(plan(0).adjustmentSummary)
        XCTAssertFalse(plan(0).isEnabled)
        XCTAssertNil(plan(30, remaining: 0.3).adjustmentSummary)
    }

    // MARK: - Abort resolution

    /// Soft abort must never leave the audible deck EQ-bypassed — the dual-PEQ
    /// death regression.
    func testAbortWinnerRules() {
        XCTAssertEqual(CrossfadeMath.abortWinner(outgoingVolume: 1, incomingVolume: 0,
                                                 uiTrackIsIncoming: true), .commitIncoming)
        XCTAssertEqual(CrossfadeMath.abortWinner(outgoingVolume: 0.1, incomingVolume: 0.9,
                                                 uiTrackIsIncoming: true), .commitIncoming)
        XCTAssertEqual(CrossfadeMath.abortWinner(outgoingVolume: 0.9, incomingVolume: 0.1,
                                                 uiTrackIsIncoming: false), .keepOutgoing)
        XCTAssertEqual(CrossfadeMath.abortWinner(outgoingVolume: 0.2, incomingVolume: 0.8,
                                                 uiTrackIsIncoming: nil), .commitIncoming)
        XCTAssertEqual(CrossfadeMath.abortWinner(outgoingVolume: 0.8, incomingVolume: 0.2,
                                                 uiTrackIsIncoming: nil), .keepOutgoing)
    }

    // MARK: - Settings round-trip

    func testSettingsCodingRoundTrip() throws {
        let original = CrossfadeSettings(durationSeconds: 30, adaptiveBPM: false,
                                         curve: .linear, skipSilence: false)
        let decoded = try JSONDecoder().decode(
            CrossfadeSettings.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testLegacySettingsMigration() throws {
        // Old schema used duration + isEnabled instead of durationSeconds.
        let legacy = #"{"duration":12.0,"isEnabled":true,"curve":"smooth"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(CrossfadeSettings.self, from: legacy)
        XCTAssertEqual(decoded.durationSeconds, 12)
        XCTAssertEqual(decoded.curve, .smooth)

        let disabled = #"{"duration":12.0,"isEnabled":false}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(CrossfadeSettings.self, from: disabled).durationSeconds, 0)
    }
}
