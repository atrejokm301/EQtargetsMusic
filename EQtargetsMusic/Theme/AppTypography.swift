//
//  AppTypography.swift
//  EQtargetsMusic
//
//  App-wide typeface: Google Sans Flex (bundled variable font).
//  Use Font.app(...) instead of Font.system(...) for UI chrome.
//  Monospaced metrics (time, BPM) stay system monospaced for alignment.
//

import SwiftUI
import UIKit

enum AppTypography {
    /// PostScript name from the bundled TTF (`GoogleSansFlex-Regular`).
    static let postScriptName = "GoogleSansFlex-Regular"
    static let displayName = "Google Sans Flex"

    /// Register at launch (also listed in Info.plist UIAppFonts).
    static func registerIfNeeded() {
        // UIAppFonts handles normal loading; this is a belt-and-suspenders for previews.
        _ = UIFont(name: postScriptName, size: 16)
    }

    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // Variable-font weight via SwiftUI; falls back gracefully if unavailable.
        Font.custom(postScriptName, size: size).weight(weight)
    }

    static func uiFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        guard let base = UIFont(name: postScriptName, size: size) else {
            return .systemFont(ofSize: size, weight: weight)
        }
        let traits: [UIFontDescriptor.TraitKey: Any] = [.weight: weight]
        let desc = base.fontDescriptor.addingAttributes([.traits: traits])
        return UIFont(descriptor: desc, size: size)
    }
}

extension Font {
    /// App typeface (Google Sans Flex). Prefer this over `.system` for UI text.
    /// Pass `design: .monospaced` to keep system mono for times / numeric columns.
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
