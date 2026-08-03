//
//  QueueSheet.swift
//  EQtargetsMusic
//
//  Playing Next — bound to AudioPlayerEngine.queue / queueIndex only.
//  Glass material + same cached real dominant colors as full player.
//

import SwiftUI

// MARK: - Glass surface

struct QueueGlassSurface: View {
    var visuals: PlayerArtworkVisuals
    var reduceTransparency: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.grokTheme) private var theme

    var body: some View {
        let isDark = scheme == .dark
        let hasArt = visuals.hasArtwork && !visuals.dominantColors.isEmpty
        let stops = visuals.gradientStops(maxStops: 4)

        ZStack {
            if !hasArt {
                Color.black
            } else if reduceTransparency {
                Color.black.opacity(isDark ? 0.65 : 0.40)
                // Preserve real album hues even with stronger surface.
                roomFill(stops: stops, intensity: isDark ? 0.55 : 0.42)
            } else {
                // Soft room-fill under glass — less intense than full player.
                roomFill(stops: stops, intensity: isDark ? 0.70 : 0.55)

                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(isDark ? 0.55 : 0.48)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Color.black.opacity(isDark ? 0.10 : 0.05)
                        .frame(height: 100)
                }
                .allowsHitTesting(false)
            }

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color.white.opacity(isDark ? 0.06 : 0.10),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 18)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)
        }
    }

    /// Softer multi-bloom of the same real dominant colors as the full player.
    private func roomFill(stops: [Color], intensity: Double) -> some View {
        let c0 = stops.indices.contains(0) ? stops[0] : Color.clear
        let c1 = stops.indices.contains(1) ? stops[1] : c0
        let c2 = stops.indices.contains(2) ? stops[2] : c1
        return ZStack {
            RadialGradient(
                colors: [c0.opacity(0.9 * intensity), c1.opacity(0.35 * intensity), .clear],
                center: UnitPoint(x: 0.5, y: 0.2),
                startRadius: 10,
                endRadius: 380
            )
            RadialGradient(
                colors: [c1.opacity(0.55 * intensity), c2.opacity(0.2 * intensity), .clear],
                center: UnitPoint(x: 0.15, y: 0.7),
                startRadius: 8,
                endRadius: 300
            )
            .blendMode(.plusLighter)
            LinearGradient(
                colors: stops.isEmpty ? [.clear] : stops.map { $0.opacity(0.45 * intensity) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.plusLighter)
            .opacity(0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Sheet

struct QueueSheet: View {
    @EnvironmentObject private var player: AudioPlayerEngine
    @Environment(\.grokTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var artworkVisuals: PlayerArtworkVisuals? = nil

    private var upNext: [Track] { player.upNext }
    /// Queue mutations blocked during crossfade — do NOT use View.disabled (greys out rows).
    private var editsBlocked: Bool { player.isTransitioning }

    private var resolvedVisuals: PlayerArtworkVisuals {
        if let artworkVisuals,
           artworkVisuals.trackID == nil || artworkVisuals.trackID == player.currentTrack?.id {
            return artworkVisuals
        }
        return PlayerArtworkVisualCache.visuals(for: player.currentTrack, accent: theme.accent)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let current = player.currentTrack {
                        Button {
                            dismiss()
                        } label: {
                            // TrackRowView already shows waveform when isPlaying.
                            TrackRowView(track: current, isPlaying: true)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(nowPlayingRowBackground)
                        .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                        .accessibilityLabel("Now playing \(current.title)")
                        .accessibilityHint("Closes queue and returns to player")
                    } else {
                        Text("Nothing playing")
                            .foregroundStyle(theme.secondaryText)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("Now Playing")
                        .foregroundStyle(theme.secondaryText)
                }

                Section {
                    if upNext.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No songs queued")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                            Text("The current track will finish normally. Add songs with Play Next or Add to Queue.")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(Array(upNext.enumerated()), id: \.element.id) { index, track in
                            Button {
                                guard !editsBlocked else { return }
                                player.playUpNextItem(at: index)
                                dismiss()
                            } label: {
                                TrackRowView(track: track, isPlaying: false)
                            }
                            .buttonStyle(.plain)
                            // Full opacity always — editsBlocked only gates actions, not look.
                            .listRowBackground(upNextRowBackground)
                            .swipeActions(edge: .trailing, allowsFullSwipe: !editsBlocked) {
                                Button(role: .destructive) {
                                    guard !editsBlocked else { return }
                                    player.removeUpNext(at: index)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                            .accessibilityHint(editsBlocked ? "Available after crossfade finishes" : "Plays this track")
                        }
                        .onMove { source, dest in
                            guard !editsBlocked else { return }
                            player.moveUpNext(from: source, to: dest)
                        }
                    }
                } header: {
                    HStack {
                        Text("Up Next")
                        if !upNext.isEmpty {
                            Text("· \(upNext.count)")
                                .foregroundStyle(theme.tertiaryText)
                        }
                    }
                    .foregroundStyle(theme.secondaryText)
                } footer: {
                    if editsBlocked {
                        Text("Queue edits pause briefly during crossfade.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background {
                QueueGlassSurface(
                    visuals: resolvedVisuals,
                    reduceTransparency: reduceTransparency
                )
                .ignoresSafeArea()
                // Animate only the glass surface, not list row opacity.
                .animation(.easeInOut(duration: 0.30), value: resolvedVisuals.trackID)
            }
            .environment(\.editMode, .constant(upNext.isEmpty || editsBlocked ? .inactive : .active))
            .navigationTitle("Playing Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        guard !editsBlocked else { return }
                        player.clearUpNext()
                    }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.danger)
                    .opacity(upNext.isEmpty || editsBlocked ? 0.4 : 1)
                    .allowsHitTesting(!(upNext.isEmpty || editsBlocked))
                    .accessibilityLabel("Clear Up Next")
                    .accessibilityHint(editsBlocked ? "Unavailable during crossfade" : "Removes all upcoming tracks")
                }
            }
        }
    }

    /// Soft island under Now Playing — no harsh accent outline “pill”.
    private var nowPlayingRowBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(reduceTransparency ? theme.elevated.opacity(0.92) : Color.clear)
            .background {
                if !reduceTransparency {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.accent.opacity(scheme == .dark ? 0.10 : 0.08))
            }
            .overlay {
                // Hairline edge only — not a thick accent border.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(scheme == .dark ? 0.14 : 0.35),
                                theme.accent.opacity(0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 2)
    }

    private var upNextRowBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                reduceTransparency
                    ? theme.elevated.opacity(0.50)
                    : Color.primary.opacity(scheme == .dark ? 0.07 : 0.06)
            )
            .padding(.vertical, 1)
    }
}
