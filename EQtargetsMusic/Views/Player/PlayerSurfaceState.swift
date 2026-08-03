//
//  PlayerSurfaceState.swift
//  EQtargetsMusic
//
//  UI-only presentation for MiniPlayer ↔ immersive full player.
//  Audio state always lives in AudioPlayerEngine.
//
//  MiniPlayer mount is driven by hasCurrentPlayableTrack (currentTrack != nil).
//  transitionProgress (0…1) drives the interactive expand/collapse overlay only.
//  Stable bottom chrome is never reparented or layout-animated for this transition.
//

import CoreGraphics
import Foundation
import SwiftUI

/// High-level player chrome phase. Combined with `transitionProgress` for continuous motion.
enum PlayerPresentation: Equatable {
    /// MiniPlayer interactive; overlay unmounted (progress ≈ 0).
    case collapsed
    /// Finger is driving progress (expand or collapse).
    case dragging
    /// Full player settled open (progress ≈ 1).
    case expanded
}

enum PlayerTransitionMetrics {
    /// Hide real MiniPlayer once overlay wash is opaque enough to cover it.
    static let chromeHideThreshold: CGFloat = 0.14
    /// Settle-to-expanded if progress exceeds this (or strong velocity).
    static let expandCommitThreshold: CGFloat = 0.38
    /// Settle-to-collapsed if progress falls below this when dragging down.
    static let collapseCommitThreshold: CGFloat = 0.62

    // MARK: - Staged visual windows (smoothstep edges)

    static let washStart: CGFloat = 0.00
    static let washEnd: CGFloat = 0.65
    static let scrimStart: CGFloat = 0.05
    static let scrimEnd: CGFloat = 0.75
    static let miniContentFadeStart: CGFloat = 0.05
    static let miniContentFadeEnd: CGFloat = 0.25
    static let heroGrowthEnd: CGFloat = 0.80
    static let metaStart: CGFloat = 0.25
    static let metaEnd: CGFloat = 0.60
    static let scrubberStart: CGFloat = 0.45
    static let scrubberEnd: CGFloat = 0.75
    static let transportStart: CGFloat = 0.55
    static let transportEnd: CGFloat = 0.85
    static let bottomActionsStart: CGFloat = 0.70
    static let bottomActionsEnd: CGFloat = 1.00
    static let interactiveControlsThreshold: CGFloat = 0.95

    /// Expand settle ~0.42–0.52s feel, well damped (no bounce).
    static var openSpring: Animation {
        .spring(response: 0.48, dampingFraction: 0.90, blendDuration: 0.10)
    }

    /// Collapse settle slightly faster, still soft.
    static var closeSpring: Animation {
        .spring(response: 0.36, dampingFraction: 0.94, blendDuration: 0.06)
    }

    /// Cancel mid-drag return.
    static var cancelSpring: Animation {
        .spring(response: 0.42, dampingFraction: 0.93, blendDuration: 0.08)
    }

    /// Reduce Motion: short non-bouncy settle.
    static var reduceMotionExpand: Animation {
        .easeOut(duration: 0.24)
    }

    static var reduceMotionCollapse: Animation {
        .easeOut(duration: 0.20)
    }

    /// Geometry-derived distance used to map drag translation → progress.
    static func expansionDistance(containerHeight: CGFloat) -> CGFloat {
        max(containerHeight * 0.70, 360)
    }

    // MARK: - Math helpers

    static func clamp(_ value: CGFloat, _ lower: CGFloat = 0, _ upper: CGFloat = 1) -> CGFloat {
        min(max(value, lower), upper)
    }

    static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        let t = clamp((value - edge0) / max(edge1 - edge0, 0.0001))
        return t * t * (3 - 2 * t)
    }
}

// Compatibility alias used by older call sites / docs.
typealias PlayerSurfaceState = PlayerPresentation
