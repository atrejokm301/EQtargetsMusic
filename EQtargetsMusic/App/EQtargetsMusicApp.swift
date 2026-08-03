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
    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}
