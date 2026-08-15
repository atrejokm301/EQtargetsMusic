//
//  PlayerProgressScrubber.swift
//  EQtargetsMusic
//
//  Edge-rail scrubber (same language as the mini player chin) for full player
//  + Now Playing. Honest progress — no fake waveform. Thin flush rail, soft
//  playhead, time labels, drag-to-seek. Isolates progress ticks from parents.
//

import SwiftUI

// MARK: - Chrome

enum PlayerScrubberChrome {
    /// Full-player wash: light ink on dark atmosphere. Trailing = remaining.
    case immersive
    /// Now Playing card: theme text on glass. Trailing = total duration.
    case nowPlaying
}

// MARK: - Scrubber

struct PlayerProgressScrubber: View {
    @EnvironmentObject private var player: AudioPlayerEngine
    @Environment(\.grokTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var isInteractive: Bool = true
    var isCollapseDragging: Bool = false
    var chrome: PlayerScrubberChrome = .immersive

    @State private var displayTime: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    private var duration: TimeInterval {
        max(player.duration, 0.001)
    }

    private var activeTime: TimeInterval {
        isScrubbing ? scrubTime : displayTime
    }

    private var progress: CGFloat {
        CGFloat(min(max(activeTime / duration, 0), 1))
    }

    private var canScrub: Bool {
        player.currentTrack != nil
            && player.duration > 0
            && isInteractive
            && !isCollapseDragging
    }

    private var isDark: Bool { scheme == .dark }

    // MARK: Palette — matches mini edge rail language

    private var trackRest: Color {
        switch chrome {
        case .immersive:
            return Color.white.opacity(0.18)
        case .nowPlaying:
            return theme.primaryText.opacity(isDark ? 0.12 : 0.10)
        }
    }

    private var trackPlayed: Color {
        switch chrome {
        case .immersive:
            return Color.white.opacity(0.92)
        case .nowPlaying:
            return theme.accent.opacity(isDark ? 0.92 : 0.88)
        }
    }

    private var playheadColor: Color {
        switch chrome {
        case .immersive:
            return Color.white
        case .nowPlaying:
            return theme.primaryText.opacity(0.9)
        }
    }

    private var labelColor: Color {
        switch chrome {
        case .immersive:
            return Color.white.opacity(0.6)
        case .nowPlaying:
            return theme.tertiaryText
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 10) {
            edgeRail
                // Tall hit target; visual rail stays thin (mini language).
                .frame(height: 28)
                .contentShape(Rectangle())
                .accessibilityElement()
                .accessibilityLabel("Playback position")
                .accessibilityValue(progressA11y)
                .accessibilityAdjustableAction { direction in
                    guard canScrub else { return }
                    let step = max(duration * 0.05, 1)
                    switch direction {
                    case .increment:
                        commitSeek(min(duration, activeTime + step))
                    case .decrement:
                        commitSeek(max(0, activeTime - step))
                    @unknown default:
                        break
                    }
                }

            HStack {
                Text(formatTime(activeTime))
                Spacer()
                switch chrome {
                case .immersive:
                    Text(formatTime(max(0, player.duration - activeTime)))
                case .nowPlaying:
                    Text(formatTime(player.duration))
                }
            }
            .font(.app(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(labelColor)
            .transaction { $0.animation = nil }
        }
        .opacity(player.currentTrack != nil ? 1 : 0.45)
        .onAppear { displayTime = player.currentTime }
        .onChange(of: player.currentTrack?.id) { _, _ in
            displayTime = player.currentTime
            isScrubbing = false
        }
        .onReceive(player.progressSubject) { t in
            guard !isScrubbing, !isCollapseDragging else { return }
            displayTime = t
        }
    }

    // MARK: - Edge rail (mini chin, larger + scrubbable)

    private var edgeRail: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            // A touch taller than the mini chin so the full-player rail feels soft, not a hairline.
            let railH: CGFloat = isScrubbing ? 7 : 5
            let fill = width * progress
            let y = geo.size.height * 0.5

            ZStack(alignment: .leading) {
                // Rest track — continuous capsule so start/end caps are soft, not square.
                Capsule(style: .continuous)
                    .fill(trackRest)
                    .frame(width: width, height: railH)
                    .position(x: width * 0.5, y: y)

                // Played fill — same capsule language; min width keeps the leading cap round.
                if fill > 0.5 {
                    Capsule(style: .continuous)
                        .fill(trackPlayed)
                        .frame(width: max(railH, fill), height: railH)
                        .position(x: max(railH, fill) * 0.5, y: y)
                }

                // Soft playhead pip (round, not a square tick)
                if progress > 0.002 {
                    let hx = min(width - railH * 0.5, max(railH * 0.5, fill))
                    Circle()
                        .fill(playheadColor.opacity(isScrubbing ? 1 : 0.92))
                        .frame(
                            width: isScrubbing ? 8 : 6,
                            height: isScrubbing ? 8 : 6
                        )
                        .shadow(color: playheadColor.opacity(isScrubbing ? 0.35 : 0.12), radius: isScrubbing ? 4 : 2, y: 0)
                        .position(x: hx, y: y)
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: isScrubbing)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard canScrub else { return }
                        if !isScrubbing { isScrubbing = true }
                        scrubTime = time(atX: value.location.x, width: width)
                    }
                    .onEnded { value in
                        guard canScrub else {
                            isScrubbing = false
                            return
                        }
                        commitSeek(time(atX: value.location.x, width: width))
                    }
            )
            .allowsHitTesting(canScrub)
        }
    }

    // MARK: - Seek

    private func time(atX x: CGFloat, width: CGFloat) -> TimeInterval {
        let p = min(max(x / max(width, 1), 0), 1)
        return TimeInterval(p) * duration
    }

    private func commitSeek(_ t: TimeInterval) {
        let clamped = min(max(t, 0), duration)
        player.seek(to: clamped)
        displayTime = clamped
        scrubTime = clamped
        isScrubbing = false
    }

    private var progressA11y: String {
        let pct = Int((progress * 100).rounded())
        return "\(formatTime(activeTime)) of \(formatTime(player.duration)), \(pct) percent"
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, !t.isNaN else { return "0:00" }
        let s = max(0, Int(t.rounded()))
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}
