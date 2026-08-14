//
//  PerformanceMemory.swift
//  EQtargetsMusic
//
//  Central memory / I/O pressure helpers — purge caches under memory warnings
//  and thermal stress without touching the audio graph. Also posts
//  `powerModeDidChange` so the player can re-apply preferred IO buffer
//  durations (fewer wakeups under LPM/heat, quality-first when cool).
//

import Foundation
import UIKit
import os

enum PerformanceMemory {
    private static let log = Logger(subsystem: "com.eqtargets.music", category: "PerfMemory")
    private static var didInstall = false

    /// Posted on main when thermal state or Low Power Mode changes.
    /// AudioPlayerEngine re-applies `preferredIOBufferDuration` without rebuilding the graph.
    static let powerModeDidChange = Notification.Name("eqtargets.performance.powerModeDidChange")

    /// Call once at launch. Safe to call repeatedly.
    static func install() {
        guard !didInstall else { return }
        didInstall = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            purgeCaches(reason: "memoryWarning")
        }
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            let state = ProcessInfo.processInfo.thermalState
            if state == .serious || state == .critical {
                purgeCaches(reason: "thermal.\(state.rawValue)")
            }
            NotificationCenter.default.post(name: powerModeDidChange, object: nil)
        }
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { _ in
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                purgeCaches(reason: "lowPowerMode")
            }
            NotificationCenter.default.post(name: powerModeDidChange, object: nil)
        }
    }

    /// Drop image + palette caches. Audio engine is left alone.
    static func purgeCaches(reason: String) {
        ArtworkImageCache.purge()
        PlayerArtworkVisualCache.clearCache()
        log.info("purged image/palette caches (\(reason, privacy: .public))")
    }

    /// Larger IO buffer → fewer audio wakeups. This is the dominant power lever
    /// in the whole app: waking the CPU every buffer period to pull six EQ units
    /// and two mixers costs far more than the DSP arithmetic inside them.
    ///
    /// The cool case used to be 0.060. Nothing here needs that: this is a
    /// playback-only app with no live input, so IO latency affects exactly one
    /// thing — how quickly a control change becomes audible — and 80 ms is below
    /// the threshold where a slider feels detached. Going 0.060 → 0.080 removes
    /// a quarter of the audio wakeups for no perceptible cost.
    ///
    /// Note iOS clamps this to roughly 0.093 s on current hardware, so the
    /// hotter rungs are requests rather than guarantees; the ladder still orders
    /// correctly once clamped.
    static var preferredIOBufferDuration: TimeInterval {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 0.120 }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return 0.140
        case .fair: return 0.100
        default: return 0.080
        }
    }

    /// Backgrounded, the screen is off and no control can be touched, so latency
    /// stops mattering entirely — push every rung further out.
    static var preferredBackgroundIOBufferDuration: TimeInterval {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 0.160 }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return 0.180
        case .fair: return 0.140
        default: return 0.120
        }
    }

    /// True when UI should drop expensive Materials / drawingGroup (phone already warm).
    static var prefersCheapChrome: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        switch ProcessInfo.processInfo.thermalState {
        case .fair, .serious, .critical: return true
        default: return false
        }
    }

    /// True when offline heavy work (BPM decode, full rescan thrash) should pause.
    static var devicePrefersLightWork: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }
}
