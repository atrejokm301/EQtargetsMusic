//
//  AppSurfaceColors.swift
//  EQtargetsMusic
//
//  Warm Light / Dark *surfaces* only — chrome, cards, text.
//  Analysis colors (EQ bands, spectrum, Target/Fine tints) live on GrokTheme
//  as `analysis*` / targetTint / fineTint and stay fully saturated.
//

import SwiftUI
import UIKit

// MARK: - Design tokens (sRGB 0…1)

/// Single source of truth for warm UI surfaces. Not a third theme — only Light & Dark.
enum AppSurfacePalette {
    // MARK: Light — paper / cream (no pure #FFFFFF)

    /// App canvas — soft warm off-white
    static let lightBackground = RGB(0.973, 0.957, 0.925)      // #F8F4EC
    /// Raised chrome (toolbars, sheets)
    static let lightElevated = RGB(0.992, 0.980, 0.957)        // #FDFAF4
    /// Cards / glass fill
    static let lightCard = RGB(1.000, 0.992, 0.973)             // #FFFDF8
    /// Primary ink (warm near-black)
    static let lightTextPrimary = RGB(0.118, 0.102, 0.086)      // #1E1A16
    static let lightTextSecondary = RGB(0.380, 0.345, 0.306)    // #61584E
    static let lightTextTertiary = RGB(0.545, 0.498, 0.447)     // #8B7F72
    static let lightSeparator = RGB(0.120, 0.090, 0.060)        // used at low alpha

    // MARK: Dark — warm charcoal (not cool navy, not pure #000)

    /// App canvas — warm black / charcoal
    static let darkBackground = RGB(0.039, 0.035, 0.031)        // #0A0908
    /// Elevated (lists, docks)
    static let darkElevated = RGB(0.078, 0.071, 0.063)          // #141210
    /// Cards / glass veil base
    static let darkCard = RGB(0.110, 0.098, 0.086)              // #1C1916
    /// Text on dark (warm white, not blue-white)
    static let darkTextPrimary = RGB(0.965, 0.949, 0.925)       // #F6F2EC
    static let darkTextSecondary = RGB(0.725, 0.690, 0.640)     // #B9B0A3
    static let darkTextTertiary = RGB(0.525, 0.490, 0.445)      // #867D71
    static let darkSeparator = RGB(0.980, 0.940, 0.880)

    // MARK: Analysis (NEVER warm-shifted — EQ / spectrum precision)

    static let analysisTargetLight = RGB(0.15, 0.45, 0.78)
    static let analysisTargetDark = RGB(0.40, 0.75, 1.00)
    static let analysisFineLight = RGB(0.88, 0.45, 0.12)
    static let analysisFineDark = RGB(1.00, 0.70, 0.35)

    struct RGB {
        let r, g, b: Double
        init(_ r: Double, _ g: Double, _ b: Double) {
            self.r = r; self.g = g; self.b = b
        }
        var color: Color { Color(red: r, green: g, blue: b) }
        var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
    }
}

// MARK: - SwiftUI Color API

extension Color {
    /// Warm canvas — use for app backgrounds, not for EQ plot ink.
    static func appBackground(isDark: Bool) -> Color {
        isDark ? AppSurfacePalette.darkBackground.color : AppSurfacePalette.lightBackground.color
    }

    static func appElevated(isDark: Bool) -> Color {
        isDark ? AppSurfacePalette.darkElevated.color : AppSurfacePalette.lightElevated.color
    }

    static func appCard(isDark: Bool) -> Color {
        isDark ? AppSurfacePalette.darkCard.color : AppSurfacePalette.lightCard.color
    }

    static func appPrimaryText(isDark: Bool) -> Color {
        isDark ? AppSurfacePalette.darkTextPrimary.color : AppSurfacePalette.lightTextPrimary.color
    }

    static func appSecondaryText(isDark: Bool) -> Color {
        isDark ? AppSurfacePalette.darkTextSecondary.color : AppSurfacePalette.lightTextSecondary.color
    }

    static func appTertiaryText(isDark: Bool) -> Color {
        isDark ? AppSurfacePalette.darkTextTertiary.color : AppSurfacePalette.lightTextTertiary.color
    }

    /// Glass stroke / hairlines on warm surfaces
    static func appHairline(isDark: Bool) -> Color {
        isDark
            ? AppSurfacePalette.darkSeparator.color.opacity(0.10)
            : AppSurfacePalette.lightSeparator.color.opacity(0.10)
    }

    // MARK: Analysis (keep saturated)

    static func analysisTarget(isDark: Bool) -> Color {
        isDark ? AppSurfacePalette.analysisTargetDark.color : AppSurfacePalette.analysisTargetLight.color
    }

    static func analysisFine(isDark: Bool) -> Color {
        isDark ? AppSurfacePalette.analysisFineDark.color : AppSurfacePalette.analysisFineLight.color
    }
}

// MARK: - UIKit (nav bars / tab bars / launch)

enum AppUIKitSurfaces {
    static func background(isDark: Bool) -> UIColor {
        isDark ? AppSurfacePalette.darkBackground.uiColor : AppSurfacePalette.lightBackground.uiColor
    }

    static func elevated(isDark: Bool) -> UIColor {
        isDark ? AppSurfacePalette.darkElevated.uiColor : AppSurfacePalette.lightElevated.uiColor
    }

    static func label(isDark: Bool) -> UIColor {
        isDark ? AppSurfacePalette.darkTextPrimary.uiColor : AppSurfacePalette.lightTextPrimary.uiColor
    }

    static func secondaryLabel(isDark: Bool) -> UIColor {
        isDark ? AppSurfacePalette.darkTextSecondary.uiColor : AppSurfacePalette.lightTextSecondary.uiColor
    }

    /// Dynamic provider that tracks trait collection (light/dark).
    static var dynamicBackground: UIColor {
        UIColor { tc in
            background(isDark: tc.userInterfaceStyle == .dark)
        }
    }

    static var dynamicLabel: UIColor {
        UIColor { tc in
            label(isDark: tc.userInterfaceStyle == .dark)
        }
    }

    static var dynamicSecondaryLabel: UIColor {
        UIColor { tc in
            secondaryLabel(isDark: tc.userInterfaceStyle == .dark)
        }
    }
}
