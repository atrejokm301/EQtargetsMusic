//
//  QueueSheet.swift
//  EQtargetsMusic
//
//  Playing Next — queue / queueIndex source of truth.
//  Swipe delete (both edges) + optional Edit reorder.
//  Full-bleed glass; high-contrast rows; modern soft pills.
//

import SwiftUI

// MARK: - Glass surface

struct QueueGlassSurface: View {
    var visuals: PlayerArtworkVisuals
    var reduceTransparency: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let isDark = true // queue is always dark glass
        let stops = visuals.atmosphericColors(maxStops: 4)
        let hasArt = visuals.hasArtwork && !stops.isEmpty

        ZStack {
            Color.black.opacity(0.90)

            if hasArt {
                roomFill(stops: stops, intensity: reduceTransparency ? 0.48 : 0.68)
            }

            if !reduceTransparency {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.42)
            } else {
                Color.black.opacity(0.30)
            }

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.white.opacity(0.08), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 32)
                Spacer(minLength: 0)
            }
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.35)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 140)
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
                colors: [c0.opacity(0.88 * intensity), c1.opacity(0.32 * intensity), .clear],
                center: UnitPoint(x: 0.5, y: 0.16),
                startRadius: 8,
                endRadius: 420
            )
            RadialGradient(
                colors: [c1.opacity(0.48 * intensity), c2.opacity(0.16 * intensity), .clear],
                center: UnitPoint(x: 0.12, y: 0.78),
                startRadius: 6,
                endRadius: 340
            )
            .blendMode(.plusLighter)
            LinearGradient(
                colors: stops.isEmpty ? [.clear] : stops.map { $0.opacity(0.38 * intensity) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.plusLighter)
            .opacity(0.42)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Sheet

struct QueueSheet: View {
    @EnvironmentObject private var player: AudioPlayerEngine
    @Environment(\.grokTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var artworkVisuals: PlayerArtworkVisuals? = nil

    /// Local edit mode for reorder only — must stay inactive for swipe-to-delete.
    @State private var isReordering = false

    private var upNext: [Track] { player.upNext }
    private var editsBlocked: Bool { player.isTransitioning }

    /// Always-dark theme for readable text on queue glass (ignore system light mode).
    private var queueTheme: GrokTheme {
        GrokTheme(isDark: true, accentTheme: theme.accentTheme)
    }

    private var resolvedVisuals: PlayerArtworkVisuals {
        if let artworkVisuals,
           artworkVisuals.trackID == nil || artworkVisuals.trackID == player.currentTrack?.id {
            return artworkVisuals
        }
        return PlayerArtworkVisualCache.visuals(for: player.currentTrack, accent: queueTheme.accent)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let current = player.currentTrack {
                        Button {
                            dismiss()
                        } label: {
                            TrackRowView(track: current, isPlaying: true, highContrast: true)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(nowPlayingPill)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .accessibilityLabel("Now playing \(current.title)")
                        .accessibilityHint("Closes queue and returns to player")
                    } else {
                        Text("Nothing playing")
                            .font(.app(size: 15, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.65))
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text("Now Playing")
                        .font(.app(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .textCase(nil)
                }

                Section {
                    if upNext.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No songs queued")
                                .font(.app(size: 15, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.92))
                            Text("The current track will finish normally. Add songs with Play Next or Add to Queue.")
                                .font(.app(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.62))
                        }
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(upNext) { track in
                            Button {
                                guard !editsBlocked, !isReordering else { return }
                                if let idx = upNext.firstIndex(where: { $0.id == track.id }) {
                                    player.playUpNextItem(at: idx)
                                }
                                dismiss()
                            } label: {
                                TrackRowView(track: track, isPlaying: false, highContrast: true)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(upNextPill)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .swipeActions(edge: .trailing, allowsFullSwipe: !editsBlocked && !isReordering) {
                                Button(role: .destructive) {
                                    guard !editsBlocked else { return }
                                    player.removeUpNext(trackID: track.id)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: !editsBlocked && !isReordering) {
                                Button(role: .destructive) {
                                    guard !editsBlocked else { return }
                                    player.removeUpNext(trackID: track.id)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                            .accessibilityHint(editsBlocked ? "Available after crossfade finishes" : "Plays this track")
                        }
                        .onDelete { indexSet in
                            guard !editsBlocked else { return }
                            let ids = indexSet.compactMap { upNext.indices.contains($0) ? upNext[$0].id : nil }
                            for id in ids {
                                player.removeUpNext(trackID: id)
                            }
                        }
                        .onMove { source, dest in
                            guard !editsBlocked else { return }
                            player.moveUpNext(from: source, to: dest)
                        }
                    }
                } header: {
                    HStack {
                        Text("Up Next")
                            .font(.app(size: 13, weight: .semibold))
                        if !upNext.isEmpty {
                            Text("· \(upNext.count)")
                                .font(.app(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                    }
                    .foregroundStyle(Color.white.opacity(0.62))
                    .textCase(nil)
                } footer: {
                    if editsBlocked {
                        Text("Queue edits pause briefly during crossfade.")
                            .font(.app(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.45))
                    } else if !upNext.isEmpty, !isReordering {
                        Text("Swipe to remove · tap Edit to reorder")
                            .font(.app(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.40))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .listRowSeparator(.hidden)
            .background {
                QueueGlassSurface(
                    visuals: resolvedVisuals,
                    reduceTransparency: reduceTransparency
                )
                .animation(.easeInOut(duration: 0.30), value: resolvedVisuals.trackID)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 8)
            }
            // Edit mode only while reordering — swipe-delete needs inactive edit mode.
            .environment(\.editMode, .constant(isReordering && !upNext.isEmpty && !editsBlocked ? .active : .inactive))
            .navigationTitle("Playing Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .font(.app(size: 15, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.95))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        if !upNext.isEmpty, !editsBlocked {
                            Button(isReordering ? "Done" : "Edit") {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isReordering.toggle()
                                }
                            }
                            .font(.app(size: 15, weight: .semibold))
                            .foregroundStyle(queueTheme.accent)
                        }
                        Button("Clear") {
                            guard !editsBlocked else { return }
                            isReordering = false
                            player.clearUpNext()
                        }
                        .font(.app(size: 15, weight: .semibold))
                        .foregroundStyle(queueTheme.danger)
                        .opacity(upNext.isEmpty || editsBlocked ? 0.4 : 1)
                        .allowsHitTesting(!(upNext.isEmpty || editsBlocked))
                        .accessibilityLabel("Clear Up Next")
                    }
                }
            }
        }
        .environment(\.grokTheme, queueTheme)
        .preferredColorScheme(.dark)
    }

    /// Soft modern “pill” under Now Playing — continuous corners, no boxy slab.
    private var nowPlayingPill: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.white.opacity(0.10))
            .background {
                if !reduceTransparency {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .opacity(0.35)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                queueTheme.accent.opacity(0.18),
                                queueTheme.accent.opacity(0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.22),
                                queueTheme.accent.opacity(0.20),
                                Color.white.opacity(0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
            .shadow(color: queueTheme.accent.opacity(0.18), radius: 12, y: 4)
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
    }

    private var upNextPill: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 2)
    }
}
