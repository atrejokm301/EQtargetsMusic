//
//  QueueSheet.swift
//  EQtargetsMusic
//
//  Playing Next — bound to AudioPlayerEngine.queue / queueIndex only.
//  Full-bleed glass (no white sheet bottom). Remove Up Next by track id.
//

import SwiftUI

// MARK: - Glass surface (full-bleed — never shows system white under the list)

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
            // Base fill always covers the entire sheet (including empty list bottom).
            // Prevents the system white card from showing through when presentationBackground is clear.
            Color.black.opacity(isDark ? 0.88 : 0.78)

            if hasArt {
                roomFill(stops: stops, intensity: reduceTransparency ? 0.50 : (isDark ? 0.72 : 0.60))
            }

            if !reduceTransparency {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(isDark ? 0.50 : 0.42)
            } else {
                Color.black.opacity(isDark ? 0.35 : 0.25)
            }

            // Soft top sheen only — no partial bottom strip (that caused uneven gray/white bands).
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color.white.opacity(isDark ? 0.07 : 0.08),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 28)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)

            // Subtle bottom vignette matching the rest of the surface (not a different color).
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(isDark ? 0.28 : 0.22)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private func roomFill(stops: [Color], intensity: Double) -> some View {
        let c0 = stops.indices.contains(0) ? stops[0] : Color.clear
        let c1 = stops.indices.contains(1) ? stops[1] : c0
        let c2 = stops.indices.contains(2) ? stops[2] : c1
        return ZStack {
            RadialGradient(
                colors: [c0.opacity(0.9 * intensity), c1.opacity(0.35 * intensity), .clear],
                center: UnitPoint(x: 0.5, y: 0.18),
                startRadius: 10,
                endRadius: 420
            )
            RadialGradient(
                colors: [c1.opacity(0.50 * intensity), c2.opacity(0.18 * intensity), .clear],
                center: UnitPoint(x: 0.12, y: 0.75),
                startRadius: 8,
                endRadius: 340
            )
            .blendMode(.plusLighter)
            LinearGradient(
                colors: stops.isEmpty ? [.clear] : stops.map { $0.opacity(0.40 * intensity) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.plusLighter)
            .opacity(0.45)
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
                        .textCase(nil)
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
                        // Identity = track id only (never enumerated index) so swipe remove is correct.
                        ForEach(upNext) { track in
                            Button {
                                guard !editsBlocked else { return }
                                if let idx = upNext.firstIndex(where: { $0.id == track.id }) {
                                    player.playUpNextItem(at: idx)
                                }
                                dismiss()
                            } label: {
                                TrackRowView(track: track, isPlaying: false)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(upNextRowBackground)
                            .swipeActions(edge: .trailing, allowsFullSwipe: !editsBlocked) {
                                Button(role: .destructive) {
                                    guard !editsBlocked else { return }
                                    player.removeUpNext(trackID: track.id)
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
                    .textCase(nil)
                } footer: {
                    if editsBlocked {
                        Text("Queue edits pause briefly during crossfade.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .listRowSeparatorTint(Color.white.opacity(scheme == .dark ? 0.12 : 0.10))
            .background {
                QueueGlassSurface(
                    visuals: resolvedVisuals,
                    reduceTransparency: reduceTransparency
                )
                .animation(.easeInOut(duration: 0.30), value: resolvedVisuals.trackID)
            }
            // Extra bottom pad so last rows aren't over home indicator; glass still fills behind.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 8)
            }
            .environment(\.editMode, .constant(upNext.isEmpty || editsBlocked ? .inactive : .active))
            .navigationTitle("Playing Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
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
        // Keep chrome dark so grouped system whites never flash through.
        .preferredColorScheme(.dark)
    }

    private var nowPlayingRowBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white.opacity(scheme == .dark ? 0.08 : 0.10))
            .background {
                if !reduceTransparency {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.55)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.accent.opacity(0.12))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.16),
                                theme.accent.opacity(0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
    }

    private var upNextRowBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .padding(.vertical, 1)
            .padding(.horizontal, 2)
    }
}
