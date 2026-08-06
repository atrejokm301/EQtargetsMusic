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

    /// Slightly larger IO buffer under heat / LPM (less wakeups, tiny latency cost).
    /// Cool + plugged-in path stays ~50 ms for dual-EQ responsiveness.
    static var preferredIOBufferDuration: TimeInterval {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 0.080 }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return 0.100
        case .fair: return 0.065
        default: return 0.050
        }
    }

    static var preferredBackgroundIOBufferDuration: TimeInterval {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 0.120 }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return 0.140
        default: return 0.100
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
