//
//  MiniPlayerBar.swift
//  EQtargetsMusic
//
//  Pill-shaped mini player — parked just above the system dock.
//  Expand gesture reports continuous progress to the root transition host.
//  Play / Next keep tap priority outside the expand region.
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
    /// Fade art/title early during expand (layout/frame of pill stays fixed).
    var contentFade: CGFloat = 1

    @State private var displayTime: TimeInterval = 0

    /// Slightly shorter than the dock content row.
    static let barHeight: CGFloat = 56
    /// Horizontal inset so the pill is a bit shorter than full dock width.
    static let horizontalInset: CGFloat = 12

    private var progress: Double {
        let d = max(player.duration, 0.001)
        return min(max(displayTime / d, 0), 1)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Expand region — art + title only (not transport buttons).
            Button(action: onTapExpand) {
                HStack(spacing: 12) {
                    artwork
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .reportMiniPlayerArtFrame()

                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.currentTrack?.title ?? "Nothing Playing")
                            .font(.app(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.app(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
                .opacity(Double(contentFade))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(openAccessibilityLabel)
            .accessibilityHint("Opens the full player")
            .simultaneousGesture(expandDragGesture)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.app(size: 16, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 40, height: 40)
                    .background {
                        Circle()
                            .fill(theme.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button {
                player.skipForward()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.app(size: 14, weight: .bold))
                    .foregroundStyle(theme.primaryText)
                    .frame(width: 40, height: 40)
                    .background {
                        Circle()
                            .fill(theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next track")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .frame(height: Self.barHeight)
        .background {
            ZStack {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                Capsule(style: .continuous)
                    .fill(
                        theme.isDark
                            ? Color.white.opacity(0.06)
                            : Color.white.opacity(0.55)
                    )
                VStack(spacing: 0) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(scheme == .dark ? 0.12 : 0.08))
                            Capsule()
                                .fill(theme.accent)
                                .frame(width: max(6, (geo.size.width - 20) * progress))
                        }
                        .padding(.horizontal, 14)
                    }
                    .frame(height: 3)
                    .padding(.top, 6)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)

                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(scheme == .dark ? 0.28 : 0.65),
                                Color.white.opacity(scheme == .dark ? 0.06 : 0.20)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.9
                    )
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.40 : 0.12), radius: 14, y: 4)
        }
        .clipShape(Capsule(style: .continuous))
        .onAppear { displayTime = player.currentTime }
        .onChange(of: player.currentTrack?.id) { _ in
            displayTime = player.currentTime
        }
        .onReceive(player.progressSubject) { t in
            displayTime = t
        }
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
                theme.elevated
                Image(systemName: "music.note")
                    .font(.app(size: 15, weight: .medium))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
    }

    private var expandDragGesture: some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .local)
            .onChanged { value in
                // Upward only for expand.
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
