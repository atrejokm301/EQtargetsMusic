//
//  EQModels.swift
//  EQtargetsMusic
//
//  Dual-layer parametric EQ (Target + Fine-Tune).
//  Audio chain: player → Target PEQ → Fine-Tune PEQ → output
//  NOTE: iOS cannot apply EQ to other apps (YouTube, Music, Netflix, etc.).
//  EQ only affects playback inside this app.
//

import Foundation

struct EQBand: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var frequency: Double
    var gain: Double
    var q: Double
    var isEnabled: Bool

    static let frequencyRange: ClosedRange<Double> = 20 ... 20_000
    static let gainRange: ClosedRange<Double> = -20 ... 20
    static let qRange: ClosedRange<Double> = 0.1 ... 10

    init(
        id: UUID = UUID(),
        frequency: Double,
        gain: Double = 0,
        q: Double = 1.41,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.frequency = Self.clamp(frequency, to: Self.frequencyRange)
        self.gain = Self.clamp(gain, to: Self.gainRange)
        self.q = Self.clamp(q, to: Self.qRange)
        self.isEnabled = isEnabled
    }

    static func defaultTenBands() -> [EQBand] {
        [31.5, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
            .map { EQBand(frequency: $0) }
    }

    mutating func reset() {
        gain = 0
        q = 1.41
        isEnabled = true
    }

    private static func clamp(_ v: Double, to r: ClosedRange<Double>) -> Double {
        min(max(v, r.lowerBound), r.upperBound)
    }
}

struct EQLayerState: Codable, Equatable, Hashable {
    var preamp: Double
    var bands: [EQBand]
    var isBypassed: Bool

    /// User request: preamp protection range −20…+20 dB
    static let preampRange: ClosedRange<Double> = -20 ... 20
    static let bandCount = 10

    static var flat: EQLayerState {
        EQLayerState(preamp: 0, bands: EQBand.defaultTenBands(), isBypassed: false)
    }

    init(preamp: Double = 0, bands: [EQBand], isBypassed: Bool = false) {
        self.preamp = min(max(preamp, Self.preampRange.lowerBound), Self.preampRange.upperBound)
        var n = bands
        if n.count < Self.bandCount {
            let d = EQBand.defaultTenBands()
            for i in n.count ..< Self.bandCount { n.append(d[i]) }
        } else if n.count > Self.bandCount {
            n = Array(n.prefix(Self.bandCount))
        }
        self.bands = n
        self.isBypassed = isBypassed
    }

    mutating func resetAll() {
        preamp = 0
        bands = EQBand.defaultTenBands()
        isBypassed = false
    }

    var isFlat: Bool {
        abs(preamp) < 0.001 && bands.allSatisfy { abs($0.gain) < 0.001 }
    }
}

enum EQLayer: String, CaseIterable, Identifiable, Codable {
    case target
    case fineTune

    var id: String { rawValue }

    var title: String {
        switch self {
        case .target: return "Target"
        case .fineTune: return "Fine-Tune"
        }
    }

    var subtitle: String {
        switch self {
        case .target: return "AutoEQ / Squiglink curve"
        case .fineTune: return "Personal adjustment on top"
        }
    }
}

struct DualEQState: Codable, Equatable, Hashable {
    var target: EQLayerState
    var fineTune: EQLayerState
    var isBypassed: Bool
    var editingLayer: EQLayer

    static var flat: DualEQState {
        DualEQState(target: .flat, fineTune: .flat, isBypassed: false, editingLayer: .fineTune)
    }

    var activeLayer: EQLayerState {
        get { editingLayer == .target ? target : fineTune }
        set {
            if editingLayer == .target { target = newValue }
            else { fineTune = newValue }
        }
    }

    mutating func loadTarget(_ layer: EQLayerState, keepFineTune: Bool = true) {
        var t = layer
        t.isBypassed = false
        target = t
        if !keepFineTune { fineTune.resetAll() }
        editingLayer = .fineTune
    }

    mutating func resetFineTune() {
        fineTune.resetAll()
        editingLayer = .fineTune
    }
}

// MARK: - AutoEQ parser

enum AutoEQParser {
    enum ParseError: LocalizedError {
        case empty, noFilters
        var errorDescription: String? {
            switch self {
            case .empty: return "File is empty."
            case .noFilters: return "No parametric (PK) filters found."
            }
        }
    }

    static func parse(text: String) throws -> EQLayerState {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        var preamp: Double = 0
        if let m = trimmed.firstMatch(of: #/(?i)Preamp\s*:\s*([+-]?\d+(?:\.\d+)?)\s*dB/#) {
            preamp = Double(m.1) ?? 0
            preamp = min(max(preamp, EQLayerState.preampRange.lowerBound), EQLayerState.preampRange.upperBound)
        }

        var bands: [EQBand] = []
        let filterPattern = #/(?i)Filter\s+\d+\s*:\s*(ON|OFF)\s+(PK|PEAK|PEQ|Bell)\s+Fc\s+([+-]?\d+(?:\.\d+)?)\s*Hz\s+Gain\s+([+-]?\d+(?:\.\d+)?)\s*dB\s+Q\s+([+-]?\d+(?:\.\d+)?)/#

        for match in trimmed.matches(of: filterPattern) {
            bands.append(
                EQBand(
                    frequency: Double(match.3) ?? 1000,
                    gain: Double(match.4) ?? 0,
                    q: Double(match.5) ?? 1.0,
                    isEnabled: String(match.1).uppercased() == "ON"
                )
            )
            if bands.count >= EQLayerState.bandCount { break }
        }

        if bands.isEmpty {
            let loose = #/(?i)Fc\s+([+-]?\d+(?:\.\d+)?)\s*Hz.*?Gain\s+([+-]?\d+(?:\.\d+)?)\s*dB.*?Q\s+([+-]?\d+(?:\.\d+)?)/#
            for match in trimmed.matches(of: loose) {
                bands.append(
                    EQBand(
                        frequency: Double(match.1) ?? 1000,
                        gain: Double(match.2) ?? 0,
                        q: Double(match.3) ?? 1.0
                    )
                )
                if bands.count >= EQLayerState.bandCount { break }
            }
        }

        guard !bands.isEmpty else { throw ParseError.noFilters }

        if bands.count < EQLayerState.bandCount {
            let d = EQBand.defaultTenBands()
            for i in bands.count ..< EQLayerState.bandCount {
                var f = d[i]
                f.gain = 0
                f.isEnabled = false
                bands.append(f)
            }
        }

        return EQLayerState(preamp: preamp, bands: bands)
    }
}

// MARK: - Frequency response (graph)

enum FrequencyResponse {
    /// 96 log points is enough for a 160pt-tall graph; half the CPU of 200.
    static let pointCount = 96
    static let sampleRate: Double = 48_000

    struct Point: Identifiable {
        var id: Double { frequency }
        let frequency: Double
        let magnitudeDB: Double
    }

    static func curve(layer: EQLayerState) -> [Point] {
        let freqs = logSpace(20, 20_000, pointCount)
        if layer.isBypassed {
            return freqs.map { Point(frequency: $0, magnitudeDB: 0) }
        }
        let filters = layer.bands.filter(\.isEnabled).map {
            PeakBiquad(frequency: $0.frequency, gainDB: $0.gain, q: $0.q)
        }
        return freqs.map { f in
            var m = layer.preamp
            for filter in filters { m += filter.magnitudeDB(at: f) }
            return Point(frequency: f, magnitudeDB: m)
        }
    }

    static func combined(dual: DualEQState) -> [Point] {
        let freqs = logSpace(20, 20_000, pointCount)
        if dual.isBypassed {
            return freqs.map { Point(frequency: $0, magnitudeDB: 0) }
        }
        let t = curve(layer: dual.target)
        let f = curve(layer: dual.fineTune)
        return zip(t, f).map { a, b in
            Point(frequency: a.frequency, magnitudeDB: a.magnitudeDB + b.magnitudeDB)
        }
    }

    static func xPosition(_ frequency: Double) -> Double {
        let f = min(max(frequency, 20), 20_000)
        return (log10(f) - log10(20)) / (log10(20_000) - log10(20))
    }

    private static func logSpace(_ minF: Double, _ maxF: Double, _ count: Int) -> [Double] {
        let a = log10(minF), b = log10(maxF)
        let step = (b - a) / Double(count - 1)
        return (0 ..< count).map { pow(10, a + Double($0) * step) }
    }
}

struct PeakBiquad {
    let b0, b1, b2, a0, a1, a2: Double

    init(frequency: Double, gainDB: Double, q: Double, sampleRate: Double = FrequencyResponse.sampleRate) {
        let A = pow(10, gainDB / 40)
        let w0 = 2 * .pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2 * max(q, 0.05))
        b0 = 1 + alpha * A
        b1 = -2 * cosW0
        b2 = 1 - alpha * A
        a0 = 1 + alpha / A
        a1 = -2 * cosW0
        a2 = 1 - alpha / A
    }

    func magnitudeDB(at f: Double, sampleRate: Double = FrequencyResponse.sampleRate) -> Double {
        let w = 2 * .pi * f / sampleRate
        let cosW = cos(w), cos2W = cos(2 * w)
        let sinW = sin(w), sin2W = sin(2 * w)
        let numRe = b0 + b1 * cosW + b2 * cos2W
        let numIm = -(b1 * sinW + b2 * sin2W)
        let denRe = a0 + a1 * cosW + a2 * cos2W
        let denIm = -(a1 * sinW + a2 * sin2W)
        let n2 = numRe * numRe + numIm * numIm
        let d2 = denRe * denRe + denIm * denIm
        guard d2 > 1e-30, n2 > 0 else { return 0 }
        return 10 * log10(n2 / d2)
    }
}

// MARK: - EQ Presets & Storage

struct EQPreset: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var layer: EQLayerState
    var isSystemDefault: Bool = false
}

enum BuiltinPresets {
    static let targets: [EQPreset] = [
        EQPreset(name: "Flat (No Target)", layer: .flat, isSystemDefault: true)
    ]

    static let fineTunes: [EQPreset] = [
        EQPreset(name: "Flat / Neutral", layer: .flat, isSystemDefault: true),
        EQPreset(
            name: "Bass Punch (+3.5 dB)",
            layer: EQLayerState(
                preamp: -1.5,
                bands: [
                    EQBand(frequency: 31.5, gain: 3.5, q: 0.8),
                    EQBand(frequency: 63, gain: 3.0, q: 1.0),
                    EQBand(frequency: 125, gain: 1.5, q: 1.2),
                    EQBand(frequency: 250, gain: 0.0, q: 1.4),
                    EQBand(frequency: 500, gain: 0.0, q: 1.4),
                    EQBand(frequency: 1000, gain: 0.0, q: 1.4),
                    EQBand(frequency: 2000, gain: 0.0, q: 1.4),
                    EQBand(frequency: 4000, gain: 0.0, q: 1.4),
                    EQBand(frequency: 8000, gain: 0.0, q: 1.4),
                    EQBand(frequency: 16000, gain: 0.0, q: 1.4)
                ]
            ),
            isSystemDefault: true
        ),
        EQPreset(
            name: "Treble Smooth (-2.5 dB Highs)",
            layer: EQLayerState(
                preamp: 0.0,
                bands: [
                    EQBand(frequency: 31.5, gain: 0.0, q: 1.4),
                    EQBand(frequency: 63, gain: 0.0, q: 1.4),
                    EQBand(frequency: 125, gain: 0.0, q: 1.4),
                    EQBand(frequency: 250, gain: 0.0, q: 1.4),
                    EQBand(frequency: 500, gain: 0.0, q: 1.4),
                    EQBand(frequency: 1000, gain: 0.0, q: 1.4),
                    EQBand(frequency: 2000, gain: 0.0, q: 1.4),
                    EQBand(frequency: 4000, gain: -1.0, q: 1.5),
                    EQBand(frequency: 8000, gain: -2.5, q: 1.8),
                    EQBand(frequency: 16000, gain: -3.0, q: 1.8)
                ]
            ),
            isSystemDefault: true
        ),
        EQPreset(
            name: "Vocal Focus",
            layer: EQLayerState(
                preamp: -1.0,
                bands: [
                    EQBand(frequency: 31.5, gain: -1.0, q: 1.0),
                    EQBand(frequency: 63, gain: -0.5, q: 1.0),
                    EQBand(frequency: 125, gain: 0.0, q: 1.0),
                    EQBand(frequency: 250, gain: 0.5, q: 1.4),
                    EQBand(frequency: 500, gain: 1.5, q: 1.4),
                    EQBand(frequency: 1000, gain: 2.0, q: 1.4),
                    EQBand(frequency: 2000, gain: 2.5, q: 1.4),
                    EQBand(frequency: 4000, gain: 1.0, q: 1.4),
                    EQBand(frequency: 8000, gain: 0.0, q: 1.4),
                    EQBand(frequency: 16000, gain: 0.0, q: 1.4)
                ]
            ),
            isSystemDefault: true
        )
    ]
}

@MainActor
final class EQPresetStore: ObservableObject {
    @Published var targetPresets: [EQPreset] = []
    @Published var fineTunePresets: [EQPreset] = []
    @Published var selectedTargetName: String = "Flat (No Target)"
    @Published var selectedFineTuneName: String = "Flat / Neutral"

    private let userTargetsKey = "eqtargets.userTargetPresets"
    private let userFineTunesKey = "eqtargets.userFineTunePresets"

    init() {
        loadPresets()
    }

    func saveTargetPreset(name: String, layer: EQLayerState) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = EQPreset(name: trimmed, layer: layer)
        targetPresets.append(preset)
        selectedTargetName = trimmed
        saveUserPresets()
    }

    func saveFineTunePreset(name: String, layer: EQLayerState) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = EQPreset(name: trimmed, layer: layer)
        fineTunePresets.append(preset)
        selectedFineTuneName = trimmed
        saveUserPresets()
    }

    func deleteTargetPreset(_ preset: EQPreset) {
        guard !preset.isSystemDefault else { return }
        targetPresets.removeAll { $0.id == preset.id }
        if selectedTargetName == preset.name {
            selectedTargetName = targetPresets.first?.name ?? "Flat (No Target)"
        }
        saveUserPresets()
    }

    func deleteFineTunePreset(_ preset: EQPreset) {
        guard !preset.isSystemDefault else { return }
        fineTunePresets.removeAll { $0.id == preset.id }
        if selectedFineTuneName == preset.name {
            selectedFineTuneName = fineTunePresets.first?.name ?? "Flat / Neutral"
        }
        saveUserPresets()
    }

    private func loadPresets() {
        var targets = BuiltinPresets.targets
        if let data = UserDefaults.standard.data(forKey: userTargetsKey),
           let userTargets = try? JSONDecoder().decode([EQPreset].self, from: data) {
            targets.append(contentsOf: userTargets)
        }
        targetPresets = targets

        var fineTunes = BuiltinPresets.fineTunes
        if let data = UserDefaults.standard.data(forKey: userFineTunesKey),
           let userFine = try? JSONDecoder().decode([EQPreset].self, from: data) {
            fineTunes.append(contentsOf: userFine)
        }
        fineTunePresets = fineTunes
    }

    private func saveUserPresets() {
        let userTargets = targetPresets.filter { !$0.isSystemDefault }
        if let data = try? JSONEncoder().encode(userTargets) {
            UserDefaults.standard.set(data, forKey: userTargetsKey)
        }

        let userFine = fineTunePresets.filter { !$0.isSystemDefault }
        if let data = try? JSONEncoder().encode(userFine) {
            UserDefaults.standard.set(data, forKey: userFineTunesKey)
        }
    }
}
