//
//  MiniPlayerBar.swift
//  EQtargetsMusic
//
//  Liquid Glass mini player for iOS 26.
//  Floating capsule above the tab dock — slightly narrower than the dock width-wise.
//  Tap / drag-up opens the full player. Rides the dock when it scroll-minimizes.
//

import SwiftUI

struct MiniPlayerBar: View {
    @EnvironmentObject private var player: AudioPlayerEngine
    @Environment(\.grokTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var onTapExpand: () -> Void
    var onExpandDragChanged: (_ translationY: CGFloat) -> Void
    var onExpandDragEnded: (_ translationY: CGFloat, _ predictedY: CGFloat) -> Void
    var contentFade: CGFloat = 1

    @State private var displayTime: TimeInterval = 0

    // MARK: Metrics
    // Full glass size (reverted from the short 48pt experiment).
    // horizontalInset keeps overall width slightly under the system tab bar.

    static let barHeight: CGFloat = 64
    /// Slightly inset so the pill is a bit narrower than the full-width tab dock.
    static let horizontalInset: CGFloat = 22

    private static let artSide: CGFloat = 44
    private static let artCorner: CGFloat = 12
    private static let hPad: CGFloat = 10
    private static let controlW: CGFloat = 44
    /// Apple Music–style edge rail: thin, flush to the capsule chin.
    private static let progressH: CGFloat = 2

    private var isDark: Bool { scheme == .dark }

    private var progress: Double {
        let d = max(player.duration, 0.001)
        return min(max(displayTime / d, 0), 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                openHitRegion
                transport
            }
            .padding(.horizontal, Self.hPad)
            .padding(.vertical, 8)
        }
        .frame(height: Self.barHeight)
        .frame(maxWidth: .infinity)
        .background { glassChrome }
        // Progress is part of the chrome rim — full width, zero inset, clipped by capsule.
        .overlay(alignment: .bottom) {
            edgeProgressRail
                .allowsHitTesting(false)
        }
        .clipShape(Capsule(style: .continuous))
        .shadow(color: .black.opacity(isDark ? 0.35 : 0.12), radius: 16, y: 6)
        .shadow(color: .black.opacity(isDark ? 0.18 : 0.06), radius: 4, y: 1)
        .accessibilityElement(children: .contain)
        .accessibilityValue(progressA11y)
        .onAppear { displayTime = player.currentTime }
        .onChange(of: player.currentTrack?.id) { _ in
            displayTime = player.currentTime
        }
        .onReceive(player.progressSubject) { displayTime = $0 }
    }

    // MARK: - Regions

    private var openHitRegion: some View {
        Button(action: onTapExpand) {
            HStack(spacing: 12) {
                artwork
                    .frame(width: Self.artSide, height: Self.artSide)
                    .clipShape(RoundedRectangle(cornerRadius: Self.artCorner, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.artCorner, style: .continuous)
                            .strokeBorder(Color.white.opacity(isDark ? 0.12 : 0.28), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                    .opacity(Double(contentFade))
                    .reportMiniPlayerArtFrame()

                VStack(alignment: .leading, spacing: 3) {
                    Text(player.currentTrack?.title ?? "Nothing Playing")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(Double(contentFade))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(openA11y)
        .accessibilityHint("Opens the full player")
        .simultaneousGesture(expandDragGesture)
        .layoutPriority(0)
    }

    private var transport: some View {
        HStack(spacing: 2) {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .frame(width: Self.controlW, height: Self.controlW)
                    .contentShape(Circle())
            }
            .buttonStyle(MiniGlassControlStyle())
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button {
                player.skipForward()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.primaryText.opacity(0.9))
                    .frame(width: Self.controlW, height: Self.controlW)
                    .contentShape(Circle())
            }
            .buttonStyle(MiniGlassControlStyle())
            .accessibilityLabel("Next track")
        }
        .opacity(Double(contentFade))
        .layoutPriority(1)
    }

    // MARK: - Liquid Glass

    @ViewBuilder
    private var glassChrome: some View {
        if #available(iOS 26.0, *) {
            Capsule(style: .continuous)
                .fill(Color.clear)
                .glassEffect(
                    .regular
                        .tint(theme.accent.opacity(isDark ? 0.18 : 0.12))
                        .interactive(),
                    in: Capsule(style: .continuous)
                )
        } else {
            ZStack {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                Capsule(style: .continuous)
                    .fill(
                        isDark
                            ? Color.white.opacity(0.06)
                            : Color.white.opacity(0.35)
                    )
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isDark ? 0.22 : 0.55),
                                Color.white.opacity(isDark ? 0.04 : 0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
            }
        }
    }

    /// Thin edge rail flush to the bottom of the glass pill (Apple Music energy).
    /// No side padding, no gradient candy, no always-on stub — fill grows from 0.
    private var edgeProgressRail: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let fill = w * progress
            ZStack(alignment: .bottomLeading) {
                // Soft unplayed track — barely there so glass still reads first.
                Rectangle()
                    .fill(theme.primaryText.opacity(isDark ? 0.10 : 0.08))
                    .frame(height: Self.progressH)

                // Solid played fill (accent, single color — not a gradient strip).
                // No animation: progress ticks every frame; animating would smear.
                Rectangle()
                    .fill(theme.accent.opacity(isDark ? 0.92 : 0.88))
                    .frame(width: max(0, fill), height: Self.progressH)
            }
            .frame(width: w, height: geo.size.height, alignment: .bottom)
        }
        .frame(height: Self.progressH)
        .accessibilityHidden(true)
    }

    // MARK: - Data

    private var subtitle: String {
        guard let t = player.currentTrack else { return " " }
        let base = t.artist.isEmpty ? (t.album.isEmpty ? " " : t.album) : t.artist
        if let sleep = player.sleepTimerRemainingLabel {
            return "\(base) · ☾ \(sleep)"
        }
        return base
    }

    private var openA11y: String {
        let title = player.currentTrack?.title ?? "Nothing"
        let artist = player.currentTrack?.artist ?? ""
        return artist.isEmpty ? "Now playing: \(title)" : "Now playing: \(title) by \(artist)"
    }

    private var progressA11y: String {
        guard player.duration > 0.5 else { return "" }
        return "\(Int((progress * 100).rounded())) percent played"
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
                theme.elevated
                Image(systemName: "music.note")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
    }

    private var expandDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
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

// MARK: - Control press

private struct MiniGlassControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.90 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

// MARK: - Scroll runway

extension View {
    /// Extra bottom scroll space so last content (Limiter, last tracks, etc.) can
    /// clear the floating mini player into open air. `safeAreaInset` alone still
    /// leaves the final controls half under the pill.
    ///
    /// - Parameter hasTrack: taller runway when the mini is mounted.
    @ViewBuilder
    func miniPlayerScrollRunway(hasTrack: Bool) -> some View {
        // Mini (~64) is already partially covered by root safeAreaInset; this is
        // pure empty runway *beyond* that so users can scroll content fully up.
        let extra: CGFloat = hasTrack ? 160 : 48
        if #available(iOS 17.0, *) {
            self.contentMargins(.bottom, extra, for: .scrollContent)
        } else {
            self
        }
    }
}
