//
//  PlayerProgressScrubber.swift
//  EQtargetsMusic
//
//  Waveform-style scrubber for full player + Now Playing.
//  Isolates high-frequency currentTime updates so parent trees are not rebuilt
//  on every progress tick. Seek still uses AudioPlayerEngine.seek(to:).
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
    @State private var waveHeights: [CGFloat] = WaveformGeometry.heights(seed: 1)

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

    private var playedColor: Color {
        switch chrome {
        case .immersive:
            return Color.white.opacity(0.92)
        case .nowPlaying:
            return theme.accent
        }
    }

    private var restColor: Color {
        switch chrome {
        case .immersive:
            return Color.white.opacity(0.22)
        case .nowPlaying:
            return theme.primaryText.opacity(isDark ? 0.18 : 0.14)
        }
    }

    private var playheadColor: Color {
        switch chrome {
        case .immersive:
            return Color.white.opacity(0.95)
        case .nowPlaying:
            return theme.primaryText.opacity(0.85)
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

    var body: some View {
        VStack(spacing: 8) {
            waveformBody
                .frame(height: 36)
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
        .onAppear {
            displayTime = player.currentTime
            refreshWaveform()
        }
        .onChange(of: player.currentTrack?.id) { _ in
            displayTime = player.currentTime
            isScrubbing = false
            refreshWaveform()
        }
        .onReceive(player.progressSubject) { t in
            guard !isScrubbing, !isCollapseDragging else { return }
            displayTime = t
        }
    }

    // MARK: - Waveform + drag

    private var waveformBody: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)

            Canvas { context, size in
                drawWaveform(context: context, size: size)
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard canScrub else { return }
                        if !isScrubbing {
                            isScrubbing = true
                        }
                        scrubTime = time(atX: value.location.x, width: width)
                    }
                    .onEnded { value in
                        guard canScrub else {
                            isScrubbing = false
                            return
                        }
                        let t = time(atX: value.location.x, width: width)
                        commitSeek(t)
                    }
            )
            .allowsHitTesting(canScrub)
        }
    }

    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        let bars = waveHeights.count
        guard bars > 0, size.width > 1, size.height > 1 else { return }

        let gap: CGFloat = 2
        let totalGap = gap * CGFloat(max(bars - 1, 0))
        let barW = max(1.5, (size.width - totalGap) / CGFloat(bars))
        let midY = size.height * 0.5
        let maxH = size.height * 0.92
        let progressX = size.width * progress

        for i in 0 ..< bars {
            let amp = waveHeights[i]
            let h = max(3, amp * maxH)
            let x = CGFloat(i) * (barW + gap)
            let y = midY - h * 0.5
            let barMid = x + barW * 0.5
            let isPlayed = barMid <= progressX

            let rect = CGRect(x: x, y: y, width: barW, height: h)
            let path = Path(roundedRect: rect, cornerRadius: min(barW, h) * 0.45)
            context.fill(path, with: .color(isPlayed ? playedColor : restColor))
        }

        // Slim playhead for quiet passages / exact scrub position.
        if progress > 0.002, progress < 0.998 {
            let hx = min(size.width - 1, max(0, progressX))
            let head = Path(
                roundedRect: CGRect(x: hx - 1, y: 2, width: 2, height: size.height - 4),
                cornerRadius: 1
            )
            context.fill(head, with: .color(playheadColor))
        }
    }

    // MARK: - Seek helpers

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

    private func refreshWaveform() {
        let seed = WaveformGeometry.seed(for: player.currentTrack?.id)
        waveHeights = WaveformGeometry.heights(seed: seed)
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

// MARK: - Deterministic waveform

private enum WaveformGeometry {
    static let barCount = 56

    /// Stable pseudo-waveform from a seed (track id). Looks musical without
    /// decoding PCM on the main thread every frame.
    static func heights(seed: UInt64) -> [CGFloat] {
        var s = seed == 0 ? 0xC0FFEE : seed
        func next() -> UInt64 {
            s ^= s >> 12
            s ^= s << 25
            s ^= s >> 27
            return s &* 0x2545F4914F6CDD1D
        }
        var out: [CGFloat] = []
        out.reserveCapacity(barCount)
        for i in 0 ..< barCount {
            let r = Double(next() % 10_000) / 10_000.0
            let t = Double(i) / Double(max(barCount - 1, 1))
            // Quieter near ends, livelier mid-track + light secondary pulse.
            let envelope = 0.35 + 0.65 * sin(t * .pi)
            let pulse = 0.75 + 0.25 * sin(t * .pi * 6 + Double(seed % 7))
            let h = 0.18 + 0.82 * r * envelope * pulse
            out.append(CGFloat(min(1, max(0.12, h))))
        }
        return out
    }

    static func seed(for trackID: UUID?) -> UInt64 {
        guard let trackID else { return 1 }
        // Fold UUID bytes into a stable 64-bit seed (same track → same wave).
        var hash: UInt64 = 5381
        withUnsafeBytes(of: trackID.uuid) { raw in
            for b in raw {
                hash = ((hash << 5) &+ hash) &+ UInt64(b)
            }
        }
        return hash == 0 ? 1 : hash
    }
}
