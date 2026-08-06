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
        PerformanceMemory.install()
        // Ultra-thin material nav bar (Messages-style). Must not be re-cleared later.
        AppChrome.configureNavigationBar()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(\.font, AppTypography.font(size: 16, weight: .regular))
        }
    }
}
