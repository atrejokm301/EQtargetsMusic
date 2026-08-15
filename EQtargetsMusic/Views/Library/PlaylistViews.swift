//
//  PlaylistViews.swift
//  EQtargetsMusic
//
//  Library tab: user playlists + the album browser that used to own a tab slot.
//  Selection and ordering only — nothing here touches the audio graph.
//

import SwiftUI

// MARK: - Shared "add to playlist" plumbing
//
// Every screen that lists music can file tracks into a playlist, so the sheet,
// the confirmation toast and the selection bar live here once. Screens only
// decide *what* is selectable — songs, albums, artists — and hand over `[Track]`.

/// Presents the add sheet whenever `pending` is non-empty, and shows the result.
///
/// The sheet is driven off the array rather than a separate Bool so there is
/// exactly one source of truth; a stale flag cannot open an empty sheet.
struct PlaylistAddingModifier: ViewModifier {
    @Binding var pending: [Track]

    @EnvironmentObject private var playlists: PlaylistStore
    @Environment(\.grokTheme) private var theme
    @State private var toast: String?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { !pending.isEmpty },
                set: { if !$0 { pending = [] } }
            )) {
                AddToPlaylistSheet(tracks: pending) { message in
                    toast = message
                }
                .environmentObject(playlists)
                .environment(\.grokTheme, theme)
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.app(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassCard(corner: 14)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 120)
                        .transition(.opacity)
                        .task {
                            try? await Task.sleep(for: .seconds(2))
                            self.toast = nil
                        }
                }
            }
            .animation(.easeOut(duration: 0.2), value: toast)
    }
}

extension View {
    /// Attach the add-to-playlist sheet + toast to a screen.
    func playlistAdding(pending: Binding<[Track]>) -> some View {
        modifier(PlaylistAddingModifier(pending: pending))
    }
}

/// Bottom bar for any multi-select mode. `noun` is already pluralised by the
/// caller, since "2 albums" and "2 songs" are counted differently upstream.
struct SelectionActionBar: View {
    let count: Int
    let noun: String
    let onDone: () -> Void
    let onAdd: () -> Void

    @Environment(\.grokTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var player: AudioPlayerEngine

    /// The mini player capsule is drawn at zIndex 10 over the content area, so a
    /// plain bottom inset lands *underneath* it and buries the Add button. Lift
    /// this bar clear of the capsule instead of moving the capsule — the mini
    /// player's position is deliberate and shared by every screen.
    private static let miniDockGap: CGFloat = 8
    private var liftAboveMiniPlayer: CGFloat {
        player.currentTrack != nil ? MiniPlayerBar.barHeight + Self.miniDockGap : 0
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onDone) {
                Text("Done")
                    .font(.app(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Text(count == 0 ? "Select \(noun)" : "\(count) selected")
                .font(.app(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .monospacedDigit()

            Spacer(minLength: 0)

            Button(action: onAdd) {
                Label("Add", systemImage: "text.badge.plus")
                    .font(.app(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(count == 0 ? theme.tertiaryText : theme.accent)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(count == 0)
        }
        .padding(.horizontal, MiniPlayerBar.horizontalInset * 0.7)
        // Same capsule, inset and shadows as the mini player, one notch shorter
        // so it reads as secondary chrome rather than a second player.
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .glassCapsule(isDark: scheme == .dark)
        .padding(.horizontal, MiniPlayerBar.horizontalInset)
        .padding(.bottom, 8 + liftAboveMiniPlayer)
        .animation(.easeOut(duration: 0.2), value: liftAboveMiniPlayer)
    }
}

/// Small header strip giving any list an "Add All" shortcut and a way into
/// select mode. Used instead of extending each screen's nav chrome so the
/// affordance sits in the same place everywhere, including on screens the
/// Library tab embeds and whose chrome is therefore not their own.
struct ListActionHeader: View {
    var addAllTitle: String?
    var onAddAll: (() -> Void)?
    var selectTitle: String = "Select"
    let onSelect: () -> Void

    @Environment(\.grokTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            if let addAllTitle, let onAddAll {
                Button(action: onAddAll) {
                    Label(addAllTitle, systemImage: "text.badge.plus")
                        .font(.app(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.accent)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Button(action: onSelect) {
                Label(selectTitle, systemImage: "checkmark.circle")
                    .font(.app(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.accent)
                    .frame(height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }
}

// MARK: - Library tab (Playlists | Albums)

struct LibraryTabView: View {
    @Environment(\.grokTheme) private var theme
    @AppStorage("eqtargets.librarySection") private var sectionRaw: String = LibrarySection.playlists.rawValue

    private enum LibrarySection: String, CaseIterable, Identifiable {
        case playlists, albums
        var id: String { rawValue }
        var title: String {
            switch self {
            case .playlists: return "Playlists"
            case .albums: return "Albums"
            }
        }
    }

    private var section: LibrarySection {
        LibrarySection(rawValue: sectionRaw) ?? .playlists
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $sectionRaw) {
                ForEach(LibrarySection.allCases) { s in
                    Text(s.title).tag(s.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)

            switch section {
            case .playlists:
                PlaylistsListView()
            case .albums:
                // Embedded: the Library tab owns the nav chrome, so the album
                // browser must not install a second title of its own.
                AlbumsListView(embedded: true)
            }
        }
        .background { theme.background.ignoresSafeArea() }
        .grokStyleNavigationChrome(title: "Library")
    }
}

// MARK: - Playlists list

struct PlaylistsListView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerEngine
    @EnvironmentObject private var playlists: PlaylistStore
    @Environment(\.grokTheme) private var theme

    @State private var showCreate = false
    @State private var newName = ""
    @State private var renameTarget: Playlist?
    @State private var renameText = ""
    @State private var toast: String?

    var body: some View {
        Group {
            if playlists.playlists.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(playlists.playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlistID: playlist.id)
                        } label: {
                            row(playlist)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(theme.separator)
                        .contextMenu {
                            Button {
                                play(playlist)
                            } label: {
                                Label("Play", systemImage: "play.fill")
                            }
                            Button {
                                queue(playlist)
                            } label: {
                                Label("Add to Queue", systemImage: "text.append")
                            }
                            Button {
                                renameText = playlist.name
                                renameTarget = playlist
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) {
                                playlists.delete(playlist.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                playlists.delete(playlist.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onMove { playlists.movePlaylists(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .grokScrollEdgeBlur()
                .miniPlayerScrollRunway(hasTrack: player.currentTrack != nil)
                .environment(\.defaultMinListRowHeight, 56)
            }
        }
        .safeAreaInset(edge: .top) {
            newPlaylistButton
        }
        .alert("New playlist", isPresented: $showCreate) {
            TextField("Name", text: $newName)
            Button("Create") {
                if playlists.create(name: newName) != nil {
                    toast = "Created “\(newName.trimmingCharacters(in: .whitespacesAndNewlines))”"
                }
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Give the playlist a name. You can add songs from Music, an album, or an artist.")
        }
        .alert("Rename playlist", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget { playlists.rename(target.id, to: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.app(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassCard(corner: 14)
                    .padding(.bottom, 120)
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(for: .seconds(2))
                        self.toast = nil
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: toast)
    }

    private var newPlaylistButton: some View {
        Button {
            newName = ""
            showCreate = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.app(size: 16, weight: .semibold))
                Text("New Playlist")
                    .font(.app(size: 15, weight: .bold, design: .rounded))
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassCard(corner: 14)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityLabel("New playlist")
    }

    private func row(_ playlist: Playlist) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.elevated)
                Image(systemName: "music.note.list")
                    .font(.app(size: 20, weight: .semibold))
                    .foregroundStyle(theme.accentSecondary)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.app(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(playlist.subtitle)
                    .font(.app(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.app(size: 48))
                .foregroundStyle(theme.accentSecondary)
            Text("No playlists yet")
                .font(.app(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text("Create a playlist, then add songs from Music with a long press — or tap Select to add several at once.")
                .font(.app(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxHeight: .infinity)
    }

    private func play(_ playlist: Playlist) {
        let tracks = playlist.resolvedTracks(in: library.tracks)
        guard !tracks.isEmpty else { return }
        player.play(tracks: tracks, startAt: 0)
    }

    private func queue(_ playlist: Playlist) {
        for track in playlist.resolvedTracks(in: library.tracks) {
            player.addToQueue(track)
        }
    }
}

// MARK: - Playlist detail

struct PlaylistDetailView: View {
    let playlistID: UUID

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerEngine
    @EnvironmentObject private var playlists: PlaylistStore
    @Environment(\.grokTheme) private var theme

    /// A set is a sequence, so reordering matters — but `onMove` only fires in
    /// edit mode, which needs an explicit toggle or the gesture is unreachable.
    @State private var isEditing = false
    @State private var dedupeMessage: String?

    private var playlist: Playlist? { playlists.playlist(id: playlistID) }

    private var tracks: [Track] {
        playlist?.resolvedTracks(in: library.tracks) ?? []
    }

    /// Entries stored but not resolvable right now — the file was removed or
    /// has not been re-imported yet. Surfaced as a count, never as blank rows.
    private var missingCount: Int {
        guard let playlist else { return 0 }
        return max(0, playlist.entries.count - tracks.count)
    }

    var body: some View {
        Group {
            if tracks.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            player.play(tracks: tracks, startAt: index)
                        } label: {
                            TrackRowView(
                                track: track,
                                isPlaying: player.currentTrack?.id == track.id
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(theme.separator)
                        .contextMenu {
                            Button {
                                player.playNow(track)
                            } label: {
                                Label("Play Now", systemImage: "play.fill")
                            }
                            Button {
                                player.playNext(track)
                            } label: {
                                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            Divider()
                            LaneOverrideMenu(track: track)
                            Divider()
                            Button(role: .destructive) {
                                playlists.remove(track, from: playlistID)
                            } label: {
                                Label("Remove from Playlist", systemImage: "minus.circle")
                            }
                        }
                    }
                    .onDelete { offsets in
                        playlists.removeResolved(at: offsets, from: playlistID, resolved: tracks)
                    }
                    .onMove { source, dest in
                        playlists.moveResolved(from: source, to: dest, in: playlistID, resolved: tracks)
                    }

                    if missingCount > 0 {
                        Text("\(missingCount) song\(missingCount == 1 ? "" : "s") not in your library right now. They stay in the playlist — re-import the files and they come back in place.")
                            .font(.app(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.tertiaryText)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .grokScrollEdgeBlur()
                .miniPlayerScrollRunway(hasTrack: player.currentTrack != nil)
                .environment(\.defaultMinListRowHeight, 56)
                .environment(\.editMode, .constant(isEditing ? EditMode.active : EditMode.inactive))
            }
        }
        .background { theme.background.ignoresSafeArea() }
        .overlay(alignment: .bottom) {
            if let dedupeMessage {
                Text(dedupeMessage)
                    .font(.app(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassCard(corner: 14)
                    .padding(.bottom, 120)
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(for: .seconds(2))
                        self.dedupeMessage = nil
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: dedupeMessage)
        .grokStyleNavigationChrome(title: playlist?.name ?? "Playlist", showsBack: true, showsMenu: false) {
            Menu {
                Button {
                    isEditing.toggle()
                } label: {
                    Label(isEditing ? "Done Reordering" : "Reorder & Remove",
                          systemImage: isEditing ? "checkmark" : "arrow.up.arrow.down")
                }
                Divider()
                Button {
                    guard !tracks.isEmpty else { return }
                    player.play(tracks: tracks, startAt: 0)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                Button {
                    guard !tracks.isEmpty else { return }
                    player.play(tracks: tracks.shuffled(), startAt: 0)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                Button {
                    for track in tracks { player.addToQueue(track) }
                } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }
                Divider()
                Button {
                    let removed = playlists.removeDuplicates(in: playlistID)
                    dedupeMessage = removed == 0
                        ? "No duplicates found"
                        : "Removed \(removed) duplicate\(removed == 1 ? "" : "s")"
                } label: {
                    Label("Remove Duplicates", systemImage: "square.on.square.dashed")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.app(size: 18, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Playlist actions")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.app(size: 44))
                .foregroundStyle(theme.accentSecondary)
            Text("Nothing here yet")
                .font(.app(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text(missingCount > 0
                 ? "\(missingCount) song\(missingCount == 1 ? "" : "s") in this playlist aren't in your library right now."
                 : "Add songs from Music — long press a song, or tap Select to add several at once.")
                .font(.app(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Add to playlist

/// Sheet for filing one or many tracks into a playlist. Also creates one on the
/// spot, because "add to a playlist that doesn't exist yet" is the common case
/// the first few times.
struct AddToPlaylistSheet: View {
    let tracks: [Track]
    var onDone: ((String) -> Void)? = nil

    @EnvironmentObject private var playlists: PlaylistStore
    @Environment(\.grokTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var showCreate = false
    @State private var newName = ""

    private var title: String {
        tracks.count == 1 ? "Add to Playlist" : "Add \(tracks.count) Songs"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        newName = ""
                        showCreate = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus.circle.fill")
                                .font(.app(size: 17, weight: .semibold))
                            Text("New Playlist")
                                .font(.app(size: 15, weight: .bold, design: .rounded))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(theme.accent)
                        .padding(14)
                        .glassCard(corner: 14)
                    }
                    .buttonStyle(.plain)

                    if playlists.playlists.isEmpty {
                        Text("No playlists yet. Create one and these songs go straight into it.")
                            .font(.app(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.tertiaryText)
                            .padding(.horizontal, 4)
                    } else {
                        ForEach(playlists.playlists) { playlist in
                            Button {
                                add(to: playlist)
                            } label: {
                                row(playlist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .background(Color.clear)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .font(.app(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .frostedBleedSheet(accent: theme.accentSecondary)
        .presentationDetents([.medium, .large])
        .alert("New playlist", isPresented: $showCreate) {
            TextField("Name", text: $newName)
            Button("Create") {
                if let created = playlists.create(name: newName, tracks: tracks) {
                    let added = playlists.playlist(id: created.id)?.entries.count ?? tracks.count
                    onDone?(summary(
                        added: added,
                        duplicates: tracks.count - added,
                        playlist: created.name
                    ))
                    dismiss()
                }
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text(tracks.count == 1
                 ? "The song is added as soon as the playlist is created."
                 : "All \(tracks.count) songs are added as soon as the playlist is created.")
        }
    }

    private func row(_ playlist: Playlist) -> some View {
        // How many of these tracks are already filed here — so the sheet can say
        // "already added" instead of silently doing nothing on tap.
        let already = tracks.filter { playlist.containsSameSong(as: $0) }.count
        let allPresent = already == tracks.count && !tracks.isEmpty

        return HStack(spacing: 12) {
            Image(systemName: allPresent ? "checkmark.circle.fill" : "music.note.list")
                .font(.app(size: 17, weight: .semibold))
                .foregroundStyle(allPresent ? theme.accent : theme.accentSecondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.app(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                Text(allPresent
                     ? "Already in this playlist"
                     : (already > 0 ? "\(playlist.subtitle) · \(already) already here" : playlist.subtitle))
                    .font(.app(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassCard(corner: 14)
        .opacity(allPresent ? 0.6 : 1)
    }

    private func add(to playlist: Playlist) {
        let result = playlists.add(tracks, to: playlist.id)
        onDone?(summary(added: result.added, duplicates: result.duplicates, playlist: playlist.name))
        dismiss()
    }

    private func summary(added: Int, duplicates: Int, playlist name: String) -> String {
        if added == 0 && duplicates > 0 {
            return duplicates == 1 ? "Already in “\(name)”" : "All \(duplicates) already in “\(name)”"
        }
        let songs = added == 1 ? "1 song" : "\(added) songs"
        if duplicates > 0 {
            let dup = duplicates == 1 ? "1 duplicate" : "\(duplicates) duplicates"
            return "\(songs) added to “\(name)” · \(dup) skipped"
        }
        return "\(songs) added to “\(name)”"
    }
}
