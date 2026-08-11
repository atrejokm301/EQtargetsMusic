//
//  LimiterProcessor.swift
//  EQtargetsMusic
//
//  Wavelet-inspired dynamics stage — independent of DualEQ / Bass Style.
//
//  Chain position:
//    Player → Target PEQ → Fine-Tune PEQ → Bass → Limiter → deck mixer
//
//  Hardware: Apple AUDynamicsProcessor (high-quality, low-latency system AU).
//  It does not expose a fixed ratio knob; we map user ratio → HeadRoom so
//  lower headroom = stronger compression, matching Wavelet-style “ratio” control.
//  OverallGain carries post-gain (makeup) after the dynamics curve.
//

import Foundation
import AudioToolbox
import AVFoundation

// MARK: - State

/// User-facing limiter. Never mutates DualEQState or BassProcessorState.
struct LimiterState: Codable, Equatable {
    /// Master enable. When false the AU is fully bypassed (zero CPU).
    var isEnabled: Bool = false
    /// Level above which gain reduction engages (dBFS-ish). User: −30…−3.
    var thresholdDB: Double = -12
    /// Compression strength as classic ratio N:1. Higher = harder limiting.
    /// Values ≥ 20 display as “∞” (brickwall-ish).
    var ratio: Double = 8
    /// Attack time in milliseconds.
    var attackMs: Double = 5
    /// Release time in milliseconds.
    var releaseMs: Double = 80
    /// Makeup gain after dynamics (dB). User: −12…+12.
    var postGainDB: Double = 0

    static let flat = LimiterState()

    static let thresholdRange: ClosedRange<Double> = -30 ... -3
    static let ratioRange: ClosedRange<Double> = 1.5 ... 20
    static let attackMsRange: ClosedRange<Double> = 0.5 ... 100
    static let releaseMsRange: ClosedRange<Double> = 10 ... 1000
    static let postGainRange: ClosedRange<Double> = -12 ... 12

    /// Brickwall / near-infinite ratio threshold for UI labeling.
    static let infiniteRatioDisplay: Double = 20

    var isActive: Bool { isEnabled }

    mutating func sanitize() {
        thresholdDB = Self.clamp(thresholdDB, to: Self.thresholdRange)
        ratio = Self.clamp(ratio, to: Self.ratioRange)
        attackMs = Self.clamp(attackMs, to: Self.attackMsRange)
        releaseMs = Self.clamp(releaseMs, to: Self.releaseMsRange)
        postGainDB = Self.clamp(postGainDB, to: Self.postGainRange)
    }

    func sanitized() -> LimiterState {
        var c = self
        c.sanitize()
        return c
    }

    /// Compact chip / tile subtitle.
    var summaryLabel: String {
        guard isEnabled else { return "Off" }
        let thr = String(format: "%+.0f dB", thresholdDB)
        let r: String
        if ratio >= Self.infiniteRatioDisplay - 0.05 {
            r = "∞:1"
        } else {
            r = String(format: "%.1f:1", ratio)
        }
        let makeup = abs(postGainDB) < 0.05
            ? ""
            : String(format: " · %+.0f dB", postGainDB)
        return "\(thr) · \(r)\(makeup)"
    }

    private static func clamp(_ v: Double, to range: ClosedRange<Double>) -> Double {
        min(max(v, range.lowerBound), range.upperBound)
    }
}

// MARK: - Hardware mapping

/// Pure mapping from `LimiterState` → AUDynamicsProcessor parameters.
enum LimiterDSP {
    struct UnitParams: Equatable {
        var bypass: Bool
        /// kDynamicsProcessorParam_Threshold (−40…20)
        var threshold: Float
        /// kDynamicsProcessorParam_HeadRoom (0.1…40) — lower = harder limit
        var headRoom: Float
        /// kDynamicsProcessorParam_AttackTime (seconds)
        var attackSec: Float
        /// kDynamicsProcessorParam_ReleaseTime (seconds)
        var releaseSec: Float
        /// kDynamicsProcessorParam_OverallGain — post-gain / makeup
        var overallGain: Float
        /// Expansion disabled (ratio 1)
        var expansionRatio: Float
        var expansionThreshold: Float
    }

    /// Map user ratio N:1 → HeadRoom dB.
    /// Apple: smaller headroom ⇒ stronger compression; output stays under threshold+headroom.
    static func headRoom(forRatio ratio: Double) -> Float {
        let r = max(ratio, 1.01)
        // Smooth curve: 1.5:1 → ~28 dB, 4:1 → ~6.7, 8:1 → ~2.9, 20:1 → ~1.05
        let hr = 40.0 / max(r - 0.5, 0.5)
        return Float(min(40, max(0.1, hr)))
    }

    static func unitParams(from state: LimiterState) -> UnitParams {
        let s = state.sanitized()
        guard s.isEnabled else {
            return UnitParams(
                bypass: true,
                threshold: -20,
                headRoom: 5,
                attackSec: 0.005,
                releaseSec: 0.08,
                overallGain: 0,
                expansionRatio: 1,
                expansionThreshold: -40
            )
        }

        // AU ranges (from AudioUnitParameters.h)
        let thr = Float(min(20, max(-40, s.thresholdDB)))
        let atk = Float(min(0.2, max(0.0001, s.attackMs / 1000.0)))
        let rel = Float(min(3.0, max(0.01, s.releaseMs / 1000.0)))
        let gain = Float(min(40, max(-40, s.postGainDB)))

        return UnitParams(
            bypass: false,
            threshold: thr,
            headRoom: headRoom(forRatio: s.ratio),
            attackSec: atk,
            releaseSec: rel,
            overallGain: gain,
            expansionRatio: 1,          // no expander stage
            expansionThreshold: -50     // keep expansion inert
        )
    }

    /// Create a system Dynamics Processor effect node.
    static func makeAudioUnit() -> AVAudioUnitEffect {
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return AVAudioUnitEffect(audioComponentDescription: desc)
    }

    /// Push params onto a live AUDynamicsProcessor.
    static func apply(params: UnitParams, to unit: AVAudioUnitEffect) {
        let au = unit.audioUnit
        set(au, kDynamicsProcessorParam_Threshold, params.threshold)
        set(au, kDynamicsProcessorParam_HeadRoom, params.headRoom)
        set(au, kDynamicsProcessorParam_ExpansionRatio, params.expansionRatio)
        set(au, kDynamicsProcessorParam_ExpansionThreshold, params.expansionThreshold)
        set(au, kDynamicsProcessorParam_AttackTime, params.attackSec)
        set(au, kDynamicsProcessorParam_ReleaseTime, params.releaseSec)
        set(au, kDynamicsProcessorParam_OverallGain, params.overallGain)
        unit.bypass = params.bypass
    }

    private static func set(_ au: AudioUnit, _ id: AudioUnitParameterID, _ value: Float) {
        AudioUnitSetParameter(au, id, kAudioUnitScope_Global, 0, value, 0)
    }
}
