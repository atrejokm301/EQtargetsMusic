//
//  TempoFeel.swift
//  EQtargetsMusic
//
//  Worship-aware tempo interpretation for auto-next / crossfade / shuffle.
//
//  Problem: pure “BPM distance” with half/double folding mixes
//  adoración (~60–90) with júbilo / alabanza de júbilo (~120–160) because
//  70 ≈ 140 at double-time. We keep raw felt BPM and map to lanes instead.
//
//  Lanes (defaults tuned for Spanish worship libraries):
//  - adoracion  — slower worship
//  - mid        — walking / mid energy
//  - jubilo     — praise / upbeat
//

import Foundation

// MARK: - Lane

enum TempoLane: Int, CaseIterable, Comparable, Codable {
    case adoracion = 0
    case mid = 1
    case jubilo = 2
    case unknown = 99

    static func < (lhs: TempoLane, rhs: TempoLane) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .adoracion: return "Adoración"
        case .mid: return "Mid"
        case .jubilo: return "Júbilo"
        case .unknown: return "Unknown"
        }
    }

    /// Spanish + English labels for UI / logs.
    var detail: String {
        switch self {
        case .adoracion: return "slow worship"
        case .mid: return "mid tempo"
        case .jubilo: return "praise / upbeat"
        case .unknown: return "no tempo data"
        }
    }

    /// Adjacent lanes (mid touches both; extremes only touch mid).
    var neighbors: Set<TempoLane> {
        switch self {
        case .adoracion: return [.mid]
        case .mid: return [.adoracion, .jubilo]
        case .jubilo: return [.mid]
        case .unknown: return []
        }
    }

    /// Hard clash: adoración ↔ júbilo.
    func clashes(with other: TempoLane) -> Bool {
        switch (self, other) {
        case (.adoracion, .jubilo), (.jubilo, .adoracion): return true
        default: return false
        }
    }
}

// MARK: - Feel helpers

enum TempoFeel {
    /// UserDefaults keys — adjustable in Settings without rebuilding.
    static let adoracionMaxKey = "eqtargets.tempo.adoracionMax"
    static let jubiloMinKey = "eqtargets.tempo.jubiloMin"

    /// Factory defaults (Spanish worship–ish starting point).
    static let defaultAdoracionMax: Double = 92
    static let defaultJubiloMin: Double = 118

    /// Allowed slider ranges.
    static let adoracionMaxRange: ClosedRange<Double> = 70 ... 110
    static let jubiloMinRange: ClosedRange<Double> = 100 ... 145
    /// Keep a real Mid band between the two cutoffs.
    static let minMidWidth: Double = 8

    /// Adoración / slow worship ceiling (felt BPM). Songs **below** this → Adoración.
    static var adoracionMax: Double {
        get { readThreshold(key: adoracionMaxKey, default: defaultAdoracionMax, range: adoracionMaxRange) }
        set { writeThresholds(adoracionMax: newValue, jubiloMin: jubiloMin) }
    }

    /// Songs **at or above** this → Júbilo. Between adoracionMax and this → Mid.
    static var jubiloMin: Double {
        get { readThreshold(key: jubiloMinKey, default: defaultJubiloMin, range: jubiloMinRange) }
        set { writeThresholds(adoracionMax: adoracionMax, jubiloMin: newValue) }
    }

    /// Snapshot of both cutoffs (always valid: mid band ≥ minMidWidth).
    static var thresholds: (adoracionMax: Double, jubiloMin: Double) {
        let a = readThreshold(key: adoracionMaxKey, default: defaultAdoracionMax, range: adoracionMaxRange)
        var j = readThreshold(key: jubiloMinKey, default: defaultJubiloMin, range: jubiloMinRange)
        if j < a + minMidWidth { j = min(jubiloMinRange.upperBound, a + minMidWidth) }
        return (a, j)
    }

    /// Human-readable band summary for Settings UI.
    static var thresholdsSummary: String {
        let t = thresholds
        let a = Int(t.adoracionMax.rounded())
        let j = Int(t.jubiloMin.rounded())
        return "Adoración < \(a) · Mid \(a)–\(j - 1) · Júbilo ≥ \(j)"
    }

    static func resetThresholdsToDefaults() {
        UserDefaults.standard.removeObject(forKey: adoracionMaxKey)
        UserDefaults.standard.removeObject(forKey: jubiloMinKey)
    }

    /// Set both at once (clamps + enforces mid width).
    static func writeThresholds(adoracionMax aIn: Double, jubiloMin jIn: Double) {
        var a = min(max(aIn, adoracionMaxRange.lowerBound), adoracionMaxRange.upperBound)
        var j = min(max(jIn, jubiloMinRange.lowerBound), jubiloMinRange.upperBound)
        if j < a + minMidWidth {
            // Prefer keeping the user’s primary drag; nudge the other side.
            if jIn - j == 0, aIn != a {
                j = min(jubiloMinRange.upperBound, a + minMidWidth)
            } else {
                a = max(adoracionMaxRange.lowerBound, j - minMidWidth)
                if j < a + minMidWidth {
                    j = min(jubiloMinRange.upperBound, a + minMidWidth)
                }
            }
        }
        UserDefaults.standard.set(a, forKey: adoracionMaxKey)
        UserDefaults.standard.set(j, forKey: jubiloMinKey)
    }

    private static func readThreshold(key: String, default def: Double, range: ClosedRange<Double>) -> Double {
        let raw: Double
        if let d = UserDefaults.standard.object(forKey: key) as? Double {
            raw = d
        } else if UserDefaults.standard.object(forKey: key) != nil {
            raw = UserDefaults.standard.double(forKey: key)
        } else {
            raw = def
        }
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    /// Use the measured BPM as the listener feels it — do NOT octave-fold toward 120.
    /// (BangerShuffle.canonicalBPM folds 70→140 and causes jubilo/adoración mixing.)
    static func feltBPM(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, raw > 35, raw < 240 else { return nil }
        return raw
    }

    /// Map felt BPM → lane using current (user-tunable) cutoffs.
    ///
    /// Reads `thresholds` (two UserDefaults lookups). Callers in a hot loop should
    /// snapshot the cutoffs once and use the `thresholds:` overload instead —
    /// this sitting inside Banger's scoring loop cost ~75% of its runtime.
    static func lane(bpm raw: Double?) -> TempoLane {
        lane(bpm: raw, thresholds: thresholds)
    }

    /// Lane from pre-read cutoffs — no UserDefaults access.
    static func lane(bpm raw: Double?, thresholds t: (adoracionMax: Double, jubiloMin: Double)) -> TempoLane {
        guard let b = feltBPM(raw) else { return .unknown }
        if b < t.adoracionMax { return .adoracion }
        if b < t.jubiloMin { return .mid }
        return .jubilo
    }

    /// Optional title/album/artist hints for Spanish worship tags when BPM is missing.
    static func laneHint(title: String, album: String, artist: String) -> TempoLane? {
        let blob = "\(title) \(album) \(artist)"
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()

        // Strong adoración markers
        if blob.contains("adoracion") || blob.contains("adoración")
            || blob.contains("soaking") || blob.contains("spontaneous")
            || blob.contains("ministry time") || blob.contains("tiempo de ministr") {
            return .adoracion
        }
        // Strong júbilo / alabanza markers
        if blob.contains("jubilo") || blob.contains("júbilo")
            || blob.contains("alabanza") || blob.contains("praise")
            || blob.contains("celebracion") || blob.contains("celebración")
            || blob.contains("shout") {
            return .jubilo
        }
        return nil
    }

    /// Best lane for a track: BPM first, then metadata hint.
    ///
    /// The hint path folds diacritics and lowercases three strings, so this is far
    /// from free — compute it once per track, never per comparison.
    static func lane(for track: Track) -> TempoLane {
        lane(for: track, thresholds: thresholds)
    }

    /// Track lane from pre-read cutoffs — no UserDefaults access.
    static func lane(for track: Track, thresholds t: (adoracionMax: Double, jubiloMin: Double)) -> TempoLane {
        let fromBPM = lane(bpm: track.bpm, thresholds: t)
        if fromBPM != .unknown { return fromBPM }
        return laneHint(title: track.title, album: track.album, artist: track.artist) ?? .unknown
    }

    /// Absolute BPM gap (no half/double). Nil if either side unknown.
    static func absoluteDistance(_ a: Double?, _ b: Double?) -> Double? {
        guard let x = feltBPM(a), let y = feltBPM(b) else { return nil }
        return abs(x - y)
    }

    /// How many lane steps apart (0 same, 1 adjacent, 2 opposite, 3 if unknown involved).
    static func laneDistance(_ a: TempoLane, _ b: TempoLane) -> Int {
        if a == .unknown || b == .unknown { return 3 }
        return abs(a.rawValue - b.rawValue)
    }

    /// Crossfade scale 0…1 — shorter when lanes clash or absolute BPM far.
    /// Replaces half/double-aware tempoDistance for worship-safe blends.
    static func crossfadeClashScale(outgoingBPM: Double?, incomingBPM: Double?) -> Double {
        let outLane = lane(bpm: outgoingBPM)
        let inLane = lane(bpm: incomingBPM)

        if outLane.clashes(with: inLane) {
            return 0.55 // adoración ↔ júbilo: keep blend short
        }
        if let d = absoluteDistance(outgoingBPM, incomingBPM) {
            if d <= 8 { return 1.0 }
            if d <= 18 { return 1.0 - (d - 8) / 10.0 * 0.18 } // → ~0.82
            if d <= 30 { return 0.82 - (d - 18) / 12.0 * 0.15 } // → ~0.67
            return max(0.55, 0.67 - (d - 30) / 40.0 * 0.12)
        }
        // One side unknown: mild caution
        if outLane == .unknown || inLane == .unknown { return 0.90 }
        if laneDistance(outLane, inLane) == 1 { return 0.88 }
        return 1.0
    }
}
