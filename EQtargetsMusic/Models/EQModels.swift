//
//  EQModels.swift
//  EQtargetsMusic
//
//  Dual-layer parametric EQ (Target + Fine-Tune).
//  Audio chain: player → Target PEQ → Fine-Tune PEQ → Bass Processor → output
//
//  Bass Style lives in BassProcessor.swift and NEVER mutates Target / Fine-Tune.
//  NOTE: iOS cannot apply EQ to other apps (YouTube, Music, Netflix, etc.).
//  EQ only affects playback inside this app.
//

import Foundation
import AVFoundation

// MARK: - Band filter type (peaking + shelves)

/// Parametric filter shape for Target / Fine-Tune bands.
/// Defaults to `.peak` for backward compatibility with older presets / AutoEQ.
enum EQFilterType: String, Codable, CaseIterable, Identifiable, Hashable {
    case peak
    case lowShelf
    case highShelf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .peak: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        }
    }

    /// Compact label for band chrome.
    var shortTitle: String {
        switch self {
        case .peak: return "Peak"
        case .lowShelf: return "L-Shelf"
        case .highShelf: return "H-Shelf"
        }
    }

    var systemImage: String {
        switch self {
        case .peak: return "waveform.path.ecg"
        case .lowShelf: return "arrow.down.to.line"
        case .highShelf: return "arrow.up.to.line"
        }
    }

    /// Hardware mapping for `AVAudioUnitEQ`.
    var avFilterType: AVAudioUnitEQFilterType {
        switch self {
        case .peak: return .parametric
        case .lowShelf: return .lowShelf
        case .highShelf: return .highShelf
        }
    }
}

struct EQBand: Identifiable, Equatable, Hashable {
    var id: UUID
    var frequency: Double
    var gain: Double
    var q: Double
    var isEnabled: Bool
    /// Peaking by default — never breaks old JSON without this key.
    var filterType: EQFilterType

    static let frequencyRange: ClosedRange<Double> = 20 ... 20_000
    static let gainRange: ClosedRange<Double> = -20 ... 20
    static let qRange: ClosedRange<Double> = 0.1 ... 10

    init(
        id: UUID = UUID(),
        frequency: Double,
        gain: Double = 0,
        q: Double = 1.41,
        isEnabled: Bool = true,
        filterType: EQFilterType = .peak
    ) {
        self.id = id
        self.frequency = Self.clamp(frequency, to: Self.frequencyRange)
        self.gain = Self.clamp(gain, to: Self.gainRange)
        self.q = Self.clamp(q, to: Self.qRange)
        self.isEnabled = isEnabled
        self.filterType = filterType
    }

    static func defaultTenBands() -> [EQBand] {
        [31.5, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
            .map { EQBand(frequency: $0, filterType: .peak) }
    }

    mutating func reset() {
        gain = 0
        q = 1.41
        isEnabled = true
        // Keep filterType — user may have set L-Shelf on band 1 intentionally.
    }

    /// Clamp all fields into legal ranges (use after UI mutation / import).
    mutating func sanitize() {
        frequency = Self.clamp(frequency, to: Self.frequencyRange)
        gain = Self.clamp(gain, to: Self.gainRange)
        q = Self.clamp(q, to: Self.qRange)
        if EQFilterType(rawValue: filterType.rawValue) == nil {
            filterType = .peak
        }
    }

    /// Convert Q-factor → bandwidth in **octaves** for `AVAudioUnitEQ.bandwidth`.
    /// RBJ peaking identity: BW_oct = 2 · asinh(1 / (2Q)) / ln(2).
    static func bandwidthOctaves(fromQ q: Double) -> Float {
        let safe = max(q, 0.05)
        guard safe.isFinite else { return 1.0 }
        return Float(2.0 * asinh(1.0 / (2.0 * safe)) / log(2.0))
    }

    private static func clamp(_ v: Double, to r: ClosedRange<Double>) -> Double {
        min(max(v, r.lowerBound), r.upperBound)
    }
}

// Codable with default `.peak` when key missing (old presets / AutoEQ imports).
extension EQBand: Codable {
    enum CodingKeys: String, CodingKey {
        case id, frequency, gain, q, isEnabled, filterType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        frequency = Self.clamp(try c.decode(Double.self, forKey: .frequency), to: Self.frequencyRange)
        gain = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .gain) ?? 0, to: Self.gainRange)
        q = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .q) ?? 1.41, to: Self.qRange)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        filterType = try c.decodeIfPresent(EQFilterType.self, forKey: .filterType) ?? .peak
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(frequency, forKey: .frequency)
        try c.encode(gain, forKey: .gain)
        try c.encode(q, forKey: .q)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(filterType, forKey: .filterType)
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
        for i in n.indices { n[i].sanitize() }
        self.bands = n
        self.isBypassed = isBypassed
    }

    /// Ensure 10 bands + clamped F/G/Q/preamp before pushing to audio hardware.
    mutating func sanitizeForDSP() {
        preamp = min(max(preamp, Self.preampRange.lowerBound), Self.preampRange.upperBound)
        if bands.count < Self.bandCount {
            let d = EQBand.defaultTenBands()
            for i in bands.count ..< Self.bandCount { bands.append(d[i]) }
        } else if bands.count > Self.bandCount {
            bands = Array(bands.prefix(Self.bandCount))
        }
        for i in bands.indices { bands[i].sanitize() }
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
            EQBiquad(
                type: $0.filterType,
                frequency: $0.frequency,
                gainDB: $0.gain,
                q: $0.q
            )
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

/// RBJ cookbook biquad for graph magnitude (peak + low/high shelf).
/// Kept separate from AVAudioUnitEQ so the UI curve matches DSP types.
struct EQBiquad {
    let b0, b1, b2, a0, a1, a2: Double

    /// Backward-compatible peaking constructor.
    init(frequency: Double, gainDB: Double, q: Double, sampleRate: Double = FrequencyResponse.sampleRate) {
        self.init(type: .peak, frequency: frequency, gainDB: gainDB, q: q, sampleRate: sampleRate)
    }

    init(
        type: EQFilterType,
        frequency: Double,
        gainDB: Double,
        q: Double,
        sampleRate: Double = FrequencyResponse.sampleRate
    ) {
        let A = pow(10, gainDB / 40)
        let w0 = 2 * .pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let safeQ = max(q, 0.05)
        let alpha = sinW0 / (2 * safeQ)

        switch type {
        case .peak:
            b0 = 1 + alpha * A
            b1 = -2 * cosW0
            b2 = 1 - alpha * A
            a0 = 1 + alpha / A
            a1 = -2 * cosW0
            a2 = 1 - alpha / A

        case .lowShelf:
            let twoSqrtAAlpha = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cosW0 + twoSqrtAAlpha)
            b1 = 2 * A * ((A - 1) - (A + 1) * cosW0)
            b2 = A * ((A + 1) - (A - 1) * cosW0 - twoSqrtAAlpha)
            a0 = (A + 1) + (A - 1) * cosW0 + twoSqrtAAlpha
            a1 = -2 * ((A - 1) + (A + 1) * cosW0)
            a2 = (A + 1) + (A - 1) * cosW0 - twoSqrtAAlpha

        case .highShelf:
            let twoSqrtAAlpha = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cosW0 + twoSqrtAAlpha)
            b1 = -2 * A * ((A - 1) + (A + 1) * cosW0)
            b2 = A * ((A + 1) + (A - 1) * cosW0 - twoSqrtAAlpha)
            a0 = (A + 1) - (A - 1) * cosW0 + twoSqrtAAlpha
            a1 = 2 * ((A - 1) - (A + 1) * cosW0)
            a2 = (A + 1) - (A - 1) * cosW0 - twoSqrtAAlpha
        }
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

/// Legacy name kept for any external references.
typealias PeakBiquad = EQBiquad

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

/// Stable identity for an output port so Target curves can follow devices.
struct AudioRouteDevice: Identifiable, Codable, Equatable, Hashable {
    /// `uid:…` when available, else `name:PortName|portType`.
    var key: String
    var name: String
    var portTypeRaw: String
    /// True when this port is on the active AVAudioSession route right now.
    var isConnected: Bool = true

    var id: String { key }

    var isBluetooth: Bool {
        Self.bluetoothPortTypes.contains(portTypeRaw)
    }

    /// Built-in phone speaker / earpiece — not useful for Target binding.
    var isBuiltIn: Bool {
        Self.builtInPortTypes.contains(portTypeRaw)
    }

    static let bluetoothPortTypes: Set<String> = [
        AVAudioSession.Port.bluetoothA2DP.rawValue,
        AVAudioSession.Port.bluetoothLE.rawValue,
        AVAudioSession.Port.bluetoothHFP.rawValue
    ]

    static let builtInPortTypes: Set<String> = [
        AVAudioSession.Port.builtInSpeaker.rawValue,
        AVAudioSession.Port.builtInReceiver.rawValue
    ]

    var kindLabel: String {
        if isBluetooth { return "Bluetooth" }
        switch portTypeRaw {
        case AVAudioSession.Port.headphones.rawValue: return "Wired"
        case AVAudioSession.Port.airPlay.rawValue: return "AirPlay"
        case AVAudioSession.Port.carAudio.rawValue: return "Car"
        case "USBAudio", "usbAudio": return "USB"
        default: return "Output"
        }
    }
}

/// One Target AutoEQ profile bound to one output device.
struct DeviceTargetAssignment: Identifiable, Codable, Equatable, Hashable {
    var deviceKey: String
    var deviceName: String
    var targetPresetName: String

    var id: String { deviceKey }
}

@MainActor
final class EQPresetStore: ObservableObject {
    @Published var targetPresets: [EQPreset] = []
    @Published var fineTunePresets: [EQPreset] = []
    @Published var selectedTargetName: String = "Flat (No Target)"
    @Published var selectedFineTuneName: String = "Flat / Neutral"
    /// Device key → Target preset name. One Target per device.
    @Published private(set) var deviceTargetAssignments: [DeviceTargetAssignment] = []
    /// Devices we’ve seen on the active route (connected now or previously).
    @Published private(set) var knownDevices: [AudioRouteDevice] = []
    /// Snapshot of external outputs currently on the route (from the system).
    @Published private(set) var connectedDevices: [AudioRouteDevice] = []

    private let userTargetsKey = "eqtargets.userTargetPresets"
    private let userFineTunesKey = "eqtargets.userFineTunePresets"
    private let deviceTargetsKey = "eqtargets.deviceTargetAssignments.v1"
    private let knownDevicesKey = "eqtargets.knownAudioDevices.v1"
    private var routeObserver: NSObjectProtocol?

    init() {
        loadPresets()
        loadDeviceAssignments()
        loadKnownDevices()
        refreshConnectedDevices()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshConnectedDevices()
            }
        }
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
    }

    // MARK: - Target / Fine-Tune presets

    func saveTargetPreset(name: String, layer: EQLayerState) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = targetPresets.firstIndex(where: { $0.name == trimmed && !$0.isSystemDefault }) {
            targetPresets[idx].layer = layer
        } else {
            targetPresets.append(EQPreset(name: trimmed, layer: layer))
        }
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
        // Drop BT bindings that pointed at the deleted curve.
        deviceTargetAssignments.removeAll { $0.targetPresetName == preset.name }
        saveDeviceAssignments()
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

    func preset(named name: String) -> EQPreset? {
        targetPresets.first { $0.name == name }
    }

    // MARK: - Connected / known route devices

    /// Re-read `AVAudioSession.currentRoute` — only devices **already connected** (active outputs).
    /// Safe to call often: **no-ops** when nothing changed (avoids SwiftUI re-render loops).
    @discardableResult
    func refreshConnectedDevices() -> [AudioRouteDevice] {
        let session = AVAudioSession.sharedInstance()
        // Do NOT force setActive here — can hitch/freeze UI when Now Playing mounts.
        let outs = session.currentRoute.outputs.compactMap { port -> AudioRouteDevice? in
            let raw = port.portType.rawValue
            if AudioRouteDevice.builtInPortTypes.contains(raw) { return nil }
            let name = port.portName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return AudioRouteDevice(
                key: Self.deviceKey(for: port),
                name: name,
                portTypeRaw: raw,
                isConnected: true
            )
        }

        // Early exit if snapshot unchanged — critical: publishing every time freezes Now Playing.
        if outs == connectedDevices {
            return outs
        }

        connectedDevices = outs

        var known = knownDevices
        var knownChanged = false
        let liveKeys = Set(outs.map(\.key))
        for d in outs {
            if let i = known.firstIndex(where: { $0.key == d.key }) {
                if known[i] != d {
                    known[i] = d
                    knownChanged = true
                }
            } else {
                known.append(d)
                knownChanged = true
            }
        }
        for i in known.indices {
            let live = liveKeys.contains(known[i].key)
            if known[i].isConnected != live {
                known[i].isConnected = live
                knownChanged = true
            }
        }
        if knownChanged {
            knownDevices = known
            saveKnownDevices()
        }
        return outs
    }

    /// Devices for the Target menu: **connected now**, then known-but-offline.
    /// Pure read — does **not** refresh (call `refreshConnectedDevices()` on route change / appear).
    func devicesForAssignmentMenu() -> [AudioRouteDevice] {
        var byKey: [String: AudioRouteDevice] = [:]
        for d in connectedDevices { byKey[d.key] = d }
        for d in knownDevices where byKey[d.key] == nil {
            var offline = d
            offline.isConnected = false
            byKey[d.key] = offline
        }
        return byKey.values.sorted { a, b in
            if a.isConnected != b.isConnected { return a.isConnected && !b.isConnected }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Primary external output currently connected (if any). Pure read.
    var primaryConnectedDevice: AudioRouteDevice? {
        connectedDevices.first(where: \.isBluetooth) ?? connectedDevices.first
    }

    static func deviceKey(for port: AVAudioSessionPortDescription) -> String {
        let uid = port.uid.trimmingCharacters(in: .whitespacesAndNewlines)
        if !uid.isEmpty { return "uid:\(uid)" }
        return "name:\(port.portName)|\(port.portType.rawValue)"
    }

    func devicesAssigned(toTarget name: String) -> [DeviceTargetAssignment] {
        deviceTargetAssignments.filter { $0.targetPresetName == name }
    }

    func assignment(forDeviceKey key: String) -> DeviceTargetAssignment? {
        deviceTargetAssignments.first { $0.deviceKey == key }
    }

    /// Bind a Target curve to a device (replaces any previous binding for that device).
    func assignTarget(_ targetName: String, to device: AudioRouteDevice) {
        let name = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, targetPresets.contains(where: { $0.name == name }) else { return }
        deviceTargetAssignments.removeAll { $0.deviceKey == device.key }
        deviceTargetAssignments.append(
            DeviceTargetAssignment(
                deviceKey: device.key,
                deviceName: device.name,
                targetPresetName: name
            )
        )
        if !knownDevices.contains(where: { $0.key == device.key }) {
            knownDevices.append(device)
            saveKnownDevices()
        }
        saveDeviceAssignments()
    }

    func unassignDevice(key: String) {
        deviceTargetAssignments.removeAll { $0.deviceKey == key }
        saveDeviceAssignments()
    }

    func unassignDevice(_ assignment: DeviceTargetAssignment) {
        unassignDevice(key: assignment.deviceKey)
    }

    func unassignAllDevices(fromTarget name: String) {
        deviceTargetAssignments.removeAll { $0.targetPresetName == name }
        saveDeviceAssignments()
    }

    /// Target bound to a **currently connected** external output, if any.
    /// Pure read of last snapshot — call `refreshConnectedDevices()` first from route handlers.
    func assignedTargetNameForCurrentRoute() -> (targetName: String, device: AudioRouteDevice)? {
        for device in connectedDevices {
            if let a = assignment(forDeviceKey: device.key) {
                return (a.targetPresetName, device)
            }
        }
        return nil
    }

    // MARK: - Persistence

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

    private func loadDeviceAssignments() {
        guard let data = UserDefaults.standard.data(forKey: deviceTargetsKey),
              let list = try? JSONDecoder().decode([DeviceTargetAssignment].self, from: data)
        else {
            deviceTargetAssignments = []
            return
        }
        deviceTargetAssignments = list
    }

    private func saveDeviceAssignments() {
        if let data = try? JSONEncoder().encode(deviceTargetAssignments) {
            UserDefaults.standard.set(data, forKey: deviceTargetsKey)
        }
    }

    private func loadKnownDevices() {
        guard let data = UserDefaults.standard.data(forKey: knownDevicesKey),
              let list = try? JSONDecoder().decode([AudioRouteDevice].self, from: data)
        else {
            knownDevices = []
            return
        }
        knownDevices = list.map {
            var d = $0
            d.isConnected = false
            return d
        }
    }

    private func saveKnownDevices() {
        // Persist identity only; connection is refreshed live.
        let stripped = knownDevices.map {
            AudioRouteDevice(key: $0.key, name: $0.name, portTypeRaw: $0.portTypeRaw, isConnected: false)
        }
        if let data = try? JSONEncoder().encode(stripped) {
            UserDefaults.standard.set(data, forKey: knownDevicesKey)
        }
    }
}
