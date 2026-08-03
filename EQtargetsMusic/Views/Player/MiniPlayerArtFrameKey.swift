//
//  MiniPlayerArtFrameKey.swift
//  EQtargetsMusic
//
//  Reports the MiniPlayer artwork frame in global coordinates for
//  progress-driven hero interpolation (no matchedGeometryEffect on chrome).
//

import SwiftUI

struct MiniPlayerArtFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 1, next.height > 1 {
            value = next
        }
    }
}

extension View {
    /// Publish this view’s global frame as the MiniPlayer artwork source rect.
    func reportMiniPlayerArtFrame() -> some View {
        background {
            GeometryReader { geo in
                Color.clear
                    .preference(key: MiniPlayerArtFrameKey.self, value: geo.frame(in: .global))
            }
        }
    }
}
