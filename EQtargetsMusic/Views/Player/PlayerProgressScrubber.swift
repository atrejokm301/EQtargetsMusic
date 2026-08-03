//
//  PlayerProgressScrubber.swift
//  EQtargetsMusic
//
//  Isolates high-frequency currentTime updates so the full-player transition
//  hierarchy is not rebuilt on every progress tick.
//

import SwiftUI

struct PlayerProgressScrubber: View {
    @EnvironmentObject private var player: AudioPlayerEngine
    @Environment(\.grokTheme) private var theme

    var isInteractive: Bool
    var isCollapseDragging: Bool

    @State private var displayTime: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime : displayTime },
                    set: { scrubTime = $0 }
                ),
                in: 0 ... max(player.duration, 0.001),
                onEditingChanged: { editing in
                    if editing {
                        if !isScrubbing { scrubTime = displayTime }
                        isScrubbing = true
                    } else {
                        player.seek(to: scrubTime)
                        displayTime = scrubTime
                        isScrubbing = false
                    }
                }
            )
            .tint(theme.accent)
            .disabled(player.currentTrack == nil || player.duration <= 0 || isCollapseDragging || !isInteractive)

            HStack {
                Text(formatTime(isScrubbing ? scrubTime : displayTime))
                Spacer()
                Text(formatTime(max(0, player.duration - (isScrubbing ? scrubTime : displayTime))))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.6))
        }
        .onAppear { displayTime = player.currentTime }
        .onChange(of: player.currentTrack?.id) { _ in
            displayTime = player.currentTime
        }
        .onReceive(player.progressSubject) { t in
            guard !isScrubbing, !isCollapseDragging else { return }
            displayTime = t
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, !t.isNaN else { return "0:00" }
        let s = max(0, Int(t.rounded()))
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}
