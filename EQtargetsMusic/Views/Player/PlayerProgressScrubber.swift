//
//  PlayerProgressScrubber.swift
//  EQtargetsMusic
//
//  Aesthetic mirrored waveform scrubber for full player + Now Playing.
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

    // MARK: Palette

    private var playedTop: Color {
        switch chrome {
        case .immersive:
            return Color.white.opacity(0.98)
        case .nowPlaying:
            return theme.accent
        }
    }

    private var playedBottom: Color {
        switch chrome {
        case .immersive:
            return Color.white.opacity(0.55)
        case .nowPlaying:
            return theme.accentSecondary.opacity(0.92)
        }
    }

    private var restTop: Color {
        switch chrome {
        case .immersive:
            return Color.white.opacity(0.28)
        case .nowPlaying:
            return theme.primaryText.opacity(isDark ? 0.22 : 0.16)
        }
    }

    private var restBottom: Color {
        switch chrome {
        case .immersive:
            return Color.white.opacity(0.10)
        case .nowPlaying:
            return theme.primaryText.opacity(isDark ? 0.08 : 0.06)
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

    private var playheadGlow: Color {
        switch chrome {
        case .immersive:
            return Color.white.opacity(0.35)
        case .nowPlaying:
            return theme.accent.opacity(0.45)
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

    private var centerLineColor: Color {
        switch chrome {
        case .immersive:
            return Color.white.opacity(0.08)
        case .nowPlaying:
            return theme.primaryText.opacity(isDark ? 0.06 : 0.05)
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 10) {
            waveformBody
                // Taller canvas reads more like a real waveform, less like a thin EQ bar.
                .frame(height: isScrubbing ? 48 : 44)
                .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isScrubbing)
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

    private func drawWaveform(context: GraphicsContext, size: CGSize) {
        let bars = waveHeights.count
        guard bars > 0, size.width > 1, size.height > 1 else { return }

        let gap: CGFloat = 1.5
        let totalGap = gap * CGFloat(max(bars - 1, 0))
        let barW = max(1.75, (size.width - totalGap) / CGFloat(bars))
        let midY = size.height * 0.5
        // Leave a hairline gutter at the center for the reflection seam.
        let halfMax = size.height * 0.46
        let progressX = size.width * progress
        let corner = min(barW * 0.5, 2.2)

        // Soft center guide — anchors the mirror without looking like a scrub track.
        var guide = Path()
        guide.move(to: CGPoint(x: 0, y: midY))
        guide.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(guide, with: .color(centerLineColor), lineWidth: 0.5)

        for i in 0 ..< bars {
            let amp = waveHeights[i]
            // Slight lift while scrubbing so the wave feels alive under the finger.
            let lift: CGFloat = isScrubbing ? 1.06 : 1.0
            let halfH = max(2.5, amp * halfMax * lift)
            let x = CGFloat(i) * (barW + gap)
            let barMid = x + barW * 0.5

            // Smooth edge: partial bars at the playhead (not a hard column cutoff).
            let barStart = x
            let barEnd = x + barW
            let playedFrac: CGFloat
            if progressX <= barStart {
                playedFrac = 0
            } else if progressX >= barEnd {
                playedFrac = 1
            } else {
                playedFrac = (progressX - barStart) / max(barW, 0.001)
            }

            // Upper lobe
            drawLobe(
                context: context,
                rect: CGRect(x: x, y: midY - halfH, width: barW, height: halfH),
                corner: corner,
                playedFrac: playedFrac,
                mirrorDown: false
            )
            // Lower reflection — slightly dimmer so the top reads as the primary form.
            drawLobe(
                context: context,
                rect: CGRect(x: x, y: midY, width: barW, height: halfH),
                corner: corner,
                playedFrac: playedFrac,
                mirrorDown: true
            )
        }

        // Soft playhead glow + crisp core.
        if progress > 0.002, progress < 0.998 {
            let hx = min(size.width - 0.5, max(0.5, progressX))

            var glow = Path(
                roundedRect: CGRect(x: hx - 3, y: 1, width: 6, height: size.height - 2),
                cornerRadius: 3
            )
            context.fill(glow, with: .color(playheadGlow))

            var core = Path(
                roundedRect: CGRect(x: hx - 1, y: 0, width: 2, height: size.height),
                cornerRadius: 1
            )
            context.fill(core, with: .color(playheadColor.opacity(0.95)))
        }
    }

    /// Draws one half of a bar with optional horizontal played/unplayed split + vertical gradient.
    private func drawLobe(
        context: GraphicsContext,
        rect: CGRect,
        corner: CGFloat,
        playedFrac: CGFloat,
        mirrorDown: Bool
    ) {
        let restAlpha: Double = mirrorDown ? 0.72 : 1.0
        let playedAlpha: Double = mirrorDown ? 0.78 : 1.0

        func fill(_ r: CGRect, played: Bool) {
            guard r.width > 0.05, r.height > 0.05 else { return }
            let path = Path(roundedRect: r, cornerRadius: min(corner, r.width * 0.5))
            let top = played ? playedTop.opacity(playedAlpha) : restTop.opacity(restAlpha)
            let bot = played ? playedBottom.opacity(playedAlpha) : restBottom.opacity(restAlpha)
            // Vertical fade: bright at outer tips, softer toward the center seam.
            let start = mirrorDown
                ? CGPoint(x: r.midX, y: r.maxY)
                : CGPoint(x: r.midX, y: r.minY)
            let end = CGPoint(x: r.midX, y: r.midY)
            context.fill(
                path,
                with: .linearGradient(
                    Gradient(colors: [top, bot]),
                    startPoint: start,
                    endPoint: end
                )
            )
        }

        if playedFrac <= 0 {
            fill(rect, played: false)
        } else if playedFrac >= 1 {
            fill(rect, played: true)
        } else {
            let playedW = rect.width * playedFrac
            fill(CGRect(x: rect.minX, y: rect.minY, width: playedW, height: rect.height), played: true)
            fill(
                CGRect(x: rect.minX + playedW, y: rect.minY, width: rect.width - playedW, height: rect.height),
                played: false
            )
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

// MARK: - Deterministic aesthetic waveform

private enum WaveformGeometry {
    /// Dense enough to feel continuous; still cheap to draw.
    static let barCount = 72

    /// Organic, song-like envelope: multi-frequency noise + neighbor smoothing.
    /// Same track id always produces the same shape (no PCM decode on the main thread).
    static func heights(seed: UInt64) -> [CGFloat] {
        var s = seed == 0 ? 0xC0FFEE : seed
        func nextUnit() -> Double {
            s ^= s >> 12
            s ^= s << 25
            s ^= s >> 27
            let u = s &* 0x2545F4914F6CDD1D
            return Double(u % 10_000) / 10_000.0
        }

        let phaseA = Double(seed % 97) * 0.07
        let phaseB = Double(seed % 53) * 0.11
        let phaseC = Double(seed % 31) * 0.17

        var raw: [Double] = []
        raw.reserveCapacity(barCount)
        for i in 0 ..< barCount {
            let t = Double(i) / Double(max(barCount - 1, 1))
            // Classic song arc: soft intro/outro, energy in the body.
            let arc = pow(sin(t * .pi), 0.72)
            // Layered “bands” so it doesn’t look like pure noise sticks.
            let low = 0.55 + 0.45 * sin(t * .pi * 2.2 + phaseA)
            let mid = 0.50 + 0.50 * sin(t * .pi * 7.0 + phaseB)
            let high = 0.45 + 0.55 * sin(t * .pi * 15.0 + phaseC)
            let noise = 0.35 + 0.65 * nextUnit()
            // Occasional transient peaks (drums / hits).
            let hit = nextUnit() > 0.92 ? 0.25 * nextUnit() : 0
            let mix = (0.42 * low + 0.28 * mid + 0.12 * high + 0.18 * noise + hit)
            let h = 0.10 + 0.90 * arc * mix
            raw.append(min(1, max(0.08, h)))
        }

        // Neighbor blur → continuous silhouette instead of random comb.
        var smooth: [CGFloat] = Array(repeating: 0, count: barCount)
        for i in 0 ..< barCount {
            let a = raw[max(0, i - 1)]
            let b = raw[i]
            let c = raw[min(barCount - 1, i + 1)]
            let d = raw[min(barCount - 1, i + 2)]
            let v = (a * 0.15 + b * 0.45 + c * 0.28 + d * 0.12)
            smooth[i] = CGFloat(min(1, max(0.10, v)))
        }
        return smooth
    }

    static func seed(for trackID: UUID?) -> UInt64 {
        guard let trackID else { return 1 }
        var hash: UInt64 = 5381
        withUnsafeBytes(of: trackID.uuid) { raw in
            for b in raw {
                hash = ((hash << 5) &+ hash) &+ UInt64(b)
            }
        }
        return hash == 0 ? 1 : hash
    }
}
