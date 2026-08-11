//
//  PlayerProgressScrubber.swift
//  EQtargetsMusic
//
//  Honest Apple Music–style line scrubber for full player + Now Playing.
//  Thin track + soft thumb — no fake waveform. Isolates progress ticks so
//  parent trees are not rebuilt every frame. Seek via AudioPlayerEngine.
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

    // MARK: Palette (honest materials — no “audio analysis” colors)

    private var trackRest: Color {
        switch chrome {
        case .immersive:
            return Color.white.opacity(0.22)
        case .nowPlaying:
            return theme.primaryText.opacity(isDark ? 0.16 : 0.12)
        }
    }

    private var trackPlayed: Color {
        switch chrome {
        case .immersive:
            return Color.white.opacity(0.92)
        case .nowPlaying:
            return theme.accent
        }
    }

    private var thumbFill: Color {
        switch chrome {
        case .immersive:
            return Color.white
        case .nowPlaying:
            return Color.white
        }
    }

    private var thumbStroke: Color {
        switch chrome {
        case .immersive:
            return Color.white.opacity(0.15)
        case .nowPlaying:
            return theme.primaryText.opacity(isDark ? 0.12 : 0.10)
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
        VStack(spacing: 8) {
            lineScrubber
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
        .onChange(of: player.currentTrack?.id) { _ in
            displayTime = player.currentTime
            isScrubbing = false
        }
        .onReceive(player.progressSubject) { t in
            guard !isScrubbing, !isCollapseDragging else { return }
            displayTime = t
        }
    }

    // MARK: - Line scrubber (Apple Music energy)

    private var lineScrubber: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let trackH: CGFloat = isScrubbing ? 5 : 3
            let thumbR: CGFloat = isScrubbing ? 8 : 6
            let y = geo.size.height * 0.5
            let x = width * progress

            ZStack(alignment: .leading) {
                // Unplayed track
                Capsule(style: .continuous)
                    .fill(trackRest)
                    .frame(height: trackH)
                    .frame(maxWidth: .infinity)
                    .position(x: width * 0.5, y: y)

                // Played track
                Capsule(style: .continuous)
                    .fill(trackPlayed)
                    .frame(width: max(trackH, x), height: trackH)
                    .position(x: max(trackH, x) * 0.5, y: y)

                // Soft thumb — scales up slightly while scrubbing
                Circle()
                    .fill(thumbFill)
                    .frame(width: thumbR * 2, height: thumbR * 2)
                    .overlay {
                        Circle()
                            .strokeBorder(thumbStroke, lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(isScrubbing ? 0.22 : 0.14), radius: isScrubbing ? 5 : 3, y: 1)
                    .position(x: min(max(x, thumbR), width - thumbR), y: y)
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isScrubbing)
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
