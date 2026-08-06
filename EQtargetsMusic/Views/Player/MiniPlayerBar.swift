//
//  MiniPlayerBar.swift
//  EQtargetsMusic
//
//  Compact floating mini player — true capsule, narrower than the dock,
//  warm glass matching tab chrome, clean art / title / transport spacing.
//  Progress hairline sits on the lower inner edge (never under chrome).
//

import SwiftUI

struct MiniPlayerBar: View {
    @EnvironmentObject private var player: AudioPlayerEngine
    @Environment(\.grokTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    /// Tap art/title → animate open.
    var onTapExpand: () -> Void
    /// Continuous upward drag progress in 0…1 (already clamped by host or raw translation).
    var onExpandDragChanged: (_ translationY: CGFloat) -> Void
    /// Drag released; host settles using translation + predicted end.
    var onExpandDragEnded: (_ translationY: CGFloat, _ predictedY: CGFloat) -> Void
    /// Fade art/title/chrome during expand (layout of pill stays fixed). Matches root host API.
    var contentFade: CGFloat = 1

    @State private var displayTime: TimeInterval = 0

    // MARK: - Sizing (8pt grid; tap targets ≥44pt)

    /// Capsule height — reads as a pill, not a fat dock row.
    static let barHeight: CGFloat = 52
    /// Noticeably narrower than the full-width dock.
    static let horizontalInset: CGFloat = 28
    private static let artSide: CGFloat = 36
    private static let artCorner: CGFloat = 8
    private static let progressTrackHeight: CGFloat = 2
    /// Hit columns ≥44pt wide; icons stay visually light inside.
    private static let controlWidth: CGFloat = 44
    private static let sideInset: CGFloat = 8
    private static let progressHorizontalInset: CGFloat = 16

    private var isDark: Bool { scheme == .dark }

    private var progress: Double {
        let d = max(player.duration, 0.001)
        return min(max(displayTime / d, 0), 1)
    }

    private var pillShape: Capsule {
        Capsule(style: .continuous)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Expand region: art + meta only. Title truncates before transport.
            Button(action: onTapExpand) {
                HStack(spacing: 8) {
                    artwork
                        .frame(width: Self.artSide, height: Self.artSide)
                        .clipShape(RoundedRectangle(cornerRadius: Self.artCorner, style: .continuous))
                        .opacity(Double(contentFade))
                        .reportMiniPlayerArtFrame()

                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentTrack?.title ?? "Nothing Playing")
                            .font(.app(size: 13, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                            .modifier(MiniPlayerLegibleText(isDark: isDark, strength: .title))
                        Text(subtitle)
                            .font(.app(size: 11, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .modifier(MiniPlayerLegibleText(isDark: isDark, strength: .subtitle))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(Double(contentFade))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(openAccessibilityLabel)
            .accessibilityHint("Opens the full player")
            .simultaneousGesture(expandDragGesture)
            .layoutPriority(0)

            // Fixed gap so meta never collides with transport.
            Spacer(minLength: 8)
                .frame(width: 8)

            // Transport: fixed columns, no overlapping hit frames.
            HStack(spacing: 0) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.app(size: 16, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .modifier(MiniPlayerLegibleText(isDark: isDark, strength: .icon))
                        .frame(width: Self.controlWidth, height: Self.barHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MiniPlayerControlButtonStyle())
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button {
                    player.skipForward()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.app(size: 14, weight: .semibold))
                        .foregroundStyle(theme.primaryText.opacity(0.88))
                        .modifier(MiniPlayerLegibleText(isDark: isDark, strength: .icon))
                        .frame(width: Self.controlWidth, height: Self.barHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MiniPlayerControlButtonStyle())
                .accessibilityLabel("Next track")
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .opacity(Double(contentFade))
        }
        // Equal side inset so art + buttons sit inside the capsule curves (no edge clipping).
        .padding(.horizontal, Self.sideInset)
        .frame(maxWidth: .infinity)
        .frame(height: Self.barHeight)
        .background { pillBackground }
        .overlay(alignment: .bottom) {
            progressHairline
                .frame(height: Self.progressTrackHeight)
                // Inset from capsule tips so the track follows the inner curve.
                .padding(.horizontal, Self.progressHorizontalInset)
                .padding(.bottom, 4)
                .allowsHitTesting(false)
        }
        .clipShape(pillShape)
        .shadow(
            color: Color.black.opacity(isDark ? 0.22 : 0.08),
            radius: isDark ? 8 : 10,
            y: isDark ? 2 : 3
        )
        .accessibilityElement(children: .contain)
        .accessibilityValue(progressAccessibilityValue)
        .onAppear { displayTime = player.currentTime }
        .onChange(of: player.currentTrack?.id) { _ in
            displayTime = player.currentTime
        }
        .onReceive(player.progressSubject) { t in
            displayTime = t
        }
    }

    // MARK: - Chrome

    /// Match system tab chrome material, then warm-tint so Light reads cream and Dark
    /// reads charcoal — never cool milky grey floating over lists.
    private var pillBackground: some View {
        ZStack {
            pillShape
                .fill(.bar)
            // Warm veil — same family as AppSurfacePalette elevated/card.
            pillShape
                .fill(
                    isDark
                        ? Color.appElevated(isDark: true).opacity(0.42)
                        : Color.appElevated(isDark: false).opacity(0.55)
                )
            // Hairline using warm glass stroke tokens (not Color.primary).
            pillShape
                .strokeBorder(
                    LinearGradient(
                        colors: [theme.glassStrokeTop, theme.glassStrokeBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
        }
    }

    private var progressHairline: some View {
        GeometryReader { geo in
            let trackW = max(geo.size.width, 1)
            let fillW = max(Self.progressTrackHeight * 2, trackW * progress)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(theme.primaryText.opacity(isDark ? 0.16 : 0.10))
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [theme.accent, theme.accentSecondary.opacity(0.92)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillW)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Copy / art / gesture

    private var progressAccessibilityValue: String {
        guard player.duration > 0.5 else { return "" }
        let pct = Int((progress * 100).rounded())
        return "\(pct) percent played"
    }

    private var subtitle: String {
        guard let t = player.currentTrack else { return "" }
        let base: String = {
            if !t.artist.isEmpty { return t.artist }
            return t.album
        }()
        if let sleep = player.sleepTimerRemainingLabel {
            return "\(base) · ☾ \(sleep)"
        }
        return base
    }

    private var openAccessibilityLabel: String {
        let title = player.currentTrack?.title ?? "Nothing"
        let artist = player.currentTrack?.artist ?? ""
        if artist.isEmpty { return "Now playing: \(title)" }
        return "Now playing: \(title) by \(artist)"
    }

    @ViewBuilder
    private var artwork: some View {
        if let track = player.currentTrack,
           let img = ArtworkImageCache.image(trackID: track.id, data: track.artworkData) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                theme.elevated.opacity(0.85)
                Image(systemName: "music.note")
                    .font(.app(size: 13, weight: .medium))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
    }

    private var expandDragGesture: some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .local)
            .onChanged { value in
                guard value.translation.height < 0 else {
                    onExpandDragChanged(0)
                    return
                }
                onExpandDragChanged(value.translation.height)
            }
            .onEnded { value in
                onExpandDragEnded(value.translation.height, value.predictedEndTranslation.height)
            }
    }
}

// MARK: - Press feedback

private struct MiniPlayerControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

// MARK: - Legibility over busy chrome

/// Soft counter-halo so labels stay readable when scroll content peeks through the glass.
/// Uses warm cream / warm black — never pure cool white.
private struct MiniPlayerLegibleText: ViewModifier {
    enum Strength {
        case title
        case subtitle
        case icon
    }

    var isDark: Bool
    var strength: Strength

    private var lightHalo: Color {
        Color.appElevated(isDark: false)
    }

    private var darkHalo: Color {
        Color.appBackground(isDark: true)
    }

    func body(content: Content) -> some View {
        switch strength {
        case .title:
            content
                .shadow(color: isDark ? darkHalo.opacity(0.70) : lightHalo.opacity(0.90), radius: 1.2, y: 0.5)
                .shadow(color: isDark ? darkHalo.opacity(0.40) : lightHalo.opacity(0.55), radius: 3, y: 0)
        case .subtitle:
            content
                .shadow(color: isDark ? darkHalo.opacity(0.60) : lightHalo.opacity(0.85), radius: 1.0, y: 0.5)
                .shadow(color: isDark ? darkHalo.opacity(0.35) : lightHalo.opacity(0.45), radius: 2.5, y: 0)
        case .icon:
            content
                .shadow(color: isDark ? darkHalo.opacity(0.55) : lightHalo.opacity(0.80), radius: 1.0, y: 0.4)
        }
    }
}
