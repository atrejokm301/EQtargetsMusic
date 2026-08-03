//
//  EQtargetsMusicApp.swift
//  EQtargetsMusic
//
//  Local music player with dual Target + Fine-Tune PEQ.
//  iOS: EQ is in-app only — system-wide interception is not available to third-party apps.
//

import SwiftUI

@main
struct EQtargetsMusicApp: App {
    init() {
        AppTypography.registerIfNeeded()
        // Navigation / tab bar labels pick up Google Sans Flex where UIKit hosts them.
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        let titleFont = AppTypography.uiFont(size: 17, weight: .semibold)
        let largeFont = AppTypography.uiFont(size: 34, weight: .bold)
        nav.titleTextAttributes = [.font: titleFont]
        nav.largeTitleTextAttributes = [.font: largeFont]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(\.font, AppTypography.font(size: 16, weight: .regular))
        }
    }
}
