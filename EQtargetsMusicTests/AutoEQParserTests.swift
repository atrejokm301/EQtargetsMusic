//
//  AutoEQParserTests.swift
//  EQtargetsMusicTests
//
//  Import defects: dropped shelves, positional truncation, trusted preamp.
//

import XCTest
@testable import EQtargetsMusic

final class AutoEQParserTests: XCTestCase {

    /// Verbatim copy of Kevin's AirPods Max export — the preset the app is
    /// actually used with. Inlined rather than read from disk so the suite runs
    /// on device.
    private let airPodsMaxPreset = """
    Preamp: -8.9 dB
    Filter 1: ON PK Fc 30 Hz Gain 1.0 dB Q 1.700
    Filter 2: ON PK Fc 100 Hz Gain 3.3 dB Q 0.600
    Filter 3: ON PK Fc 110 Hz Gain 0.9 dB Q 2.900
    Filter 4: ON PK Fc 210 Hz Gain -0.9 dB Q 2.800
    Filter 5: ON PK Fc 320 Hz Gain -2.5 dB Q 0.700
    Filter 6: ON PK Fc 1200 Hz Gain -1.5 dB Q 2.200
    Filter 7: ON PK Fc 2700 Hz Gain 2.6 dB Q 3.000
    Filter 8: ON PK Fc 4900 Hz Gain 9.4 dB Q 3.000
    Filter 9: ON PK Fc 8200 Hz Gain 5.7 dB Q 3.000
    Filter 10: ON PK Fc 8500 Hz Gain -4.7 dB Q 1.400
    """

    /// Fine-sweep realized peak including preamp, from the reference biquad.
    private func realizedPeak(_ layer: EQLayerState) -> (db: Double, hz: Double) {
        let filters = layer.bands.filter(\.isEnabled).map { b -> Fixtures.RefBiquad in
            let kind: Fixtures.RefBiquad.Kind = {
                switch b.filterType {
                case .peak: return .peak
                case .lowShelf: return .lowShelf
                case .highShelf: return .highShelf
                }
            }()
            return Fixtures.RefBiquad(kind, frequency: b.frequency, gainDB: b.gain, q: b.q)
        }
        var best = -Double.infinity, bestF = 0.0
        var f = 20.0
        while f <= 20_000 {
            var m = layer.preamp
            for filter in filters { m += filter.magnitudeDB(at: f) }
            if m > best { best = m; bestF = f }
            f *= 1.001
        }
        return (best, bestF)
    }

    func testRealPresetImportsUnchanged() throws {
        let layer = try AutoEQParser.parse(text: airPodsMaxPreset)
        XCTAssertEqual(layer.bands.filter(\.isEnabled).count, 10)
        let peak = realizedPeak(layer)
        XCTAssertEqual(peak.db, 0, accuracy: 0.05, "preset should sit at 0 dBFS")
        // Derived preamp must agree with the file, or we changed how it sounds.
        XCTAssertEqual(layer.preamp, -8.9, accuracy: 0.1,
                       "derived preamp drifted from the file's value")
    }

    func testShelfFiltersSurviveImport() throws {
        let text = """
        Preamp: -6.7 dB
        Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
        Filter 2: ON PK Fc 230 Hz Gain -1.5 dB Q 1.00
        Filter 3: ON PK Fc 3000 Hz Gain 2.0 dB Q 2.00
        Filter 4: ON HSC Fc 10000 Hz Gain -3.0 dB Q 0.70
        """
        let enabled = try AutoEQParser.parse(text: text).bands.filter(\.isEnabled)
        XCTAssertEqual(enabled.count, 4, "shelves were dropped")
        XCTAssertTrue(enabled.contains { $0.filterType == .lowShelf && abs($0.frequency - 105) < 1 })
        XCTAssertTrue(enabled.contains { $0.filterType == .highShelf && abs($0.frequency - 10_000) < 1 })
    }

    func testAllFilterTypeTokens() throws {
        let expected: [String: EQFilterType] = [
            "LS": .lowShelf, "LSC": .lowShelf, "LSQ": .lowShelf,
            "HS": .highShelf, "HSC": .highShelf, "HSQ": .highShelf,
            "PK": .peak, "PEAK": .peak, "PEQ": .peak, "Bell": .peak,
        ]
        for (token, type) in expected {
            let layer = try AutoEQParser.parse(
                text: "Filter 1: ON \(token) Fc 200 Hz Gain 4.0 dB Q 0.70")
            let bands = layer.bands.filter(\.isEnabled)
            XCTAssertEqual(bands.count, 1, "token \(token) did not parse")
            XCTAssertEqual(bands.first?.filterType, type, "token \(token) mapped wrong")
            XCTAssertEqual(bands.first?.frequency ?? 0, 200, accuracy: 1)
            XCTAssertEqual(bands.first?.gain ?? 0, 4.0, accuracy: 0.01)
        }
    }

    /// Regression: truncating in file order discarded the largest correction.
    func testTruncationKeepsMostSignificantFilters() throws {
        var lines = ["Preamp: -7.0 dB"]
        for i in 1 ... 14 {
            lines.append("Filter \(i): ON PK Fc \(i * 400) Hz Gain \(i == 14 ? 8.0 : 1.0) dB Q 1.00")
        }
        let enabled = try AutoEQParser.parse(text: lines.joined(separator: "\n"))
            .bands.filter(\.isEnabled)
        XCTAssertEqual(enabled.count, 10)
        XCTAssertTrue(enabled.contains { $0.gain > 7 }, "dropped the largest correction")
        XCTAssertEqual(enabled.map(\.frequency), enabled.map(\.frequency).sorted(),
                       "kept bands lost frequency ordering")
    }

    func testPreampAlwaysLandsCurveAtZeroDBFS() throws {
        let cases: [(String, String)] = [
            ("boost-heavy", "Filter 1: ON PK Fc 60 Hz Gain 9.0 dB Q 0.7\nFilter 2: ON PK Fc 3000 Hz Gain 6.0 dB Q 1.0"),
            ("overlapping stack", "Filter 1: ON PK Fc 100 Hz Gain 5.0 dB Q 0.7\nFilter 2: ON PK Fc 120 Hz Gain 5.0 dB Q 0.7\nFilter 3: ON PK Fc 140 Hz Gain 5.0 dB Q 0.7"),
            ("lying preamp", "Preamp: +12.0 dB\nFilter 1: ON PK Fc 1000 Hz Gain 6.0 dB Q 1.0"),
            ("shelf stack", "Filter 1: ON LSC Fc 120 Hz Gain 8.0 dB Q 0.7\nFilter 2: ON PK Fc 80 Hz Gain 4.0 dB Q 1.0"),
        ]
        for (name, text) in cases {
            let layer = try AutoEQParser.parse(text: text)
            XCTAssertEqual(realizedPeak(layer).db, 0, accuracy: 0.05, "\(name) not gain-staged")
            XCTAssertLessThanOrEqual(layer.preamp, 0.001, "\(name): preamp must never boost")
        }
        // Cuts-only curves get no makeup, matching AutoEQ's convention.
        let cutsOnly = try AutoEQParser.parse(
            text: "Filter 1: ON PK Fc 200 Hz Gain -6.0 dB Q 1.0\nFilter 2: ON PK Fc 5000 Hz Gain -3.0 dB Q 1.0")
        XCTAssertEqual(cutsOnly.preamp, 0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(realizedPeak(cutsOnly).db, 0.05)
    }

    func testMalformedInput() {
        XCTAssertThrowsError(try AutoEQParser.parse(text: ""))
        XCTAssertThrowsError(try AutoEQParser.parse(text: "no filters here"))
    }

    func testDisabledAndOutOfRangeFilters() throws {
        let off = try AutoEQParser.parse(text: "Filter 1: OFF PK Fc 100 Hz Gain 5.0 dB Q 1.0")
        XCTAssertTrue(off.bands.filter(\.isEnabled).isEmpty)
        XCTAssertEqual(off.preamp, 0, accuracy: 0.001, "disabled-only preset needs no preamp")

        let wild = try AutoEQParser.parse(text: "Filter 1: ON PK Fc 99999 Hz Gain 99 dB Q 99")
        let b = wild.bands[0]
        XCTAssertLessThanOrEqual(b.frequency, 20_000)
        XCTAssertLessThanOrEqual(b.gain, 20)
        XCTAssertLessThanOrEqual(b.q, 10)
        // Preamp must reflect the clamped curve, not the file's intent.
        XCTAssertLessThanOrEqual(realizedPeak(wild).db, 0.05)
    }

    /// The 96-point display grid is too coarse to derive preamp from.
    func testFineSweepBeatsDisplayGridForPeak() throws {
        let layer = try AutoEQParser.parse(text: airPodsMaxPreset)
        var flat = layer
        flat.preamp = 0
        let fine = FrequencyResponse.peakMagnitudeDB(bands: flat.bands)
        let reference = realizedPeak(flat).db
        XCTAssertEqual(fine, reference, accuracy: 0.05,
                       "peakMagnitudeDB disagrees with an independent fine sweep")
    }
}
