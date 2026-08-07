//
//  AppTypography.swift
//  EQtargetsMusic
//
//  App-wide typeface: Inter Variable (bundled).
//  Use Font.app(...) instead of Font.system(...) for UI chrome.
//  Monospaced metrics (time, BPM) stay system monospaced for alignment.
//

import SwiftUI
import UIKit

enum AppTypography {
    /// Default PostScript name (Regular instance of Inter Variable).
    static let postScriptName = "InterVariable"
    static let displayName = "Inter"

    /// Register at launch (also listed in Info.plist UIAppFonts).
    static func registerIfNeeded() {
        // UIAppFonts handles normal loading; belt-and-suspenders for previews.
        _ = UIFont(name: postScriptName, size: 16)
        _ = UIFont(name: "InterVariable-Medium", size: 16)
        _ = UIFont(name: "InterVariable-Bold", size: 16)
    }

    /// Named instance for a SwiftUI weight (Inter Variable ships discrete masters).
    static func postScriptName(for weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight: return "InterVariable-Thin"
        case .thin: return "InterVariable-Thin"
        case .light: return "InterVariable-Light"
        case .regular: return "InterVariable"
        case .medium: return "InterVariable-Medium"
        case .semibold: return "InterVariable-SemiBold"
        case .bold: return "InterVariable-Bold"
        case .heavy: return "InterVariable-ExtraBold"
        case .black: return "InterVariable-Black"
        default: return "InterVariable"
        }
    }

    static func postScriptName(forUIFontWeight weight: UIFont.Weight) -> String {
        switch weight {
        case .ultraLight: return "InterVariable-Thin"
        case .thin: return "InterVariable-Thin"
        case .light: return "InterVariable-Light"
        case .regular: return "InterVariable"
        case .medium: return "InterVariable-Medium"
        case .semibold: return "InterVariable-SemiBold"
        case .bold: return "InterVariable-Bold"
        case .heavy: return "InterVariable-ExtraBold"
        case .black: return "InterVariable-Black"
        default: return "InterVariable"
        }
    }

    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(postScriptName(for: weight), size: size)
    }

    static func uiFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let name = postScriptName(forUIFontWeight: weight)
        if let font = UIFont(name: name, size: size) {
            return font
        }
        // Fallback: try Regular + traits, then system.
        if let base = UIFont(name: postScriptName, size: size) {
            let traits: [UIFontDescriptor.TraitKey: Any] = [.weight: weight]
            let desc = base.fontDescriptor.addingAttributes([.traits: traits])
            return UIFont(descriptor: desc, size: size)
        }
        return .systemFont(ofSize: size, weight: weight)
    }
}

extension Font {
    /// App typeface (Inter). Prefer this over `.system` for UI text.
    /// Pass `design: .monospaced` to keep system mono for times / numeric columns.
    /// `design: .rounded` still uses Inter (no separate rounded face).
    static func app(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        if design == .monospaced {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return AppTypography.font(size: size, weight: weight)
    }
}
