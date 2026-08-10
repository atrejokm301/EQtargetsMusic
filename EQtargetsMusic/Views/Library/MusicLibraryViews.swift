//
//  MusicLibraryViews.swift
//  EQtargetsMusic
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Music (all tracks)

private enum MusicSortMode: String, CaseIterable, Identifiable {
    case title, artist, album, duration
    var id: String { rawValue }
    var title: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .album: return "Album"
        case .duration: return "Duration"
        }
    }
    var systemImage: String {
        switch self {
        case .title: return "textformat.abc"
        case .artist: return "person"
        case .album: return "square.stack"
        case .duration: return "clock"
        }
    }
}

struct MusicListView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerEngine
    @Environment(\.grokTheme) private var theme

    @State private var showFileImporter = false
    @State private var showFolderImporter = false
    @AppStorage("eqtargets.musicSortMode") private var sortModeRaw: String = MusicSortMode.title.rawValue

    private var sortMode: MusicSortMode {
        MusicSortMode(rawValue: sortModeRaw) ?? .title
    }

    private var sortedTracks: [Track] {
        let tracks = library.tracks
        switch sortMode {
        case .title:
            return tracks.sorted {
                let c = $0.title.localizedCaseInsensitiveCompare($1.title)
                if c != .orderedSame { return c == .orderedAscending }
                return $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending
            }
        case .artist:
            return tracks.sorted {
                let c = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                if c != .orderedSame { return c == .orderedAscending }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .album:
            // Album name, then same disc/track rules as album detail (live albums stay sequential).
            return tracks.sorted {
                let c = $0.album.localizedCaseInsensitiveCompare($1.album)
                if c != .orderedSame { return c == .orderedAscending }
                let art = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                if art != .orderedSame { return art == .orderedAscending }
                return LibraryStore.albumPlaybackOrder($0, $1)
            }
        case .duration:
            return tracks.sorted {
                if $0.duration != $1.duration { return $0.duration < $1.duration }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    var body: some View {
        Group {
            if library.tracks.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(sortedTracks) { track in
                        Button {
                            let list = sortedTracks
                            player.play(tracks: list, startAt: list.firstIndex(where: { $0.id == track.id }) ?? 0)
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
                            Button {
                                player.addToQueue(track)
                            } label: {
                                Label("Add to Queue", systemImage: "text.append")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                library.deleteTrack(track)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                player.playNext(track)
                            } label: {
                                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            .tint(theme.accent)
                            Button {
                                player.addToQueue(track)
                            } label: {
                                Label("Queue", systemImage: "text.append")
                            }
                            .tint(.indigo)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .grokScrollEdgeBlur()
                // Faster list scrolling — fewer offscreen views retained.
                .environment(\.defaultMinListRowHeight, 56)
            }
        }
        // Solid black behind lists (blur blobs are expensive while scrolling).
        .background { theme.background.ignoresSafeArea() }
        .grokStyleNavigationChrome(title: "Music") {
            Menu {
                Section("Sort by") {
                    ForEach(MusicSortMode.allCases) { mode in
                        Button {
                            sortModeRaw = mode.rawValue
                        } label: {
                            Label(mode.title, systemImage: mode.systemImage)
                            if sortMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button {
                    showFolderImporter = true
                } label: {
                    Label("Import Folder…", systemImage: "folder.badge.plus")
                }
                Button {
                    showFileImporter = true
                } label: {
                    Label("Import Files…", systemImage: "doc.badge.plus")
                }
                Button {
                    Task { await library.rescan() }
                } label: {
                    Label("Rescan Library", systemImage: "arrow.clockwise")
                }
                Button {
                    Task { await library.analyzeMissingBPMs() }
                } label: {
                    Label("Analyze BPM (pending)", systemImage: "metronome")
                }
                Button {
                    Task { await library.forceRedetectMissingBPMValues() }
                } label: {
                    Label("Re-scan all missing BPMs", systemImage: "metronome.fill")
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.app(size: 20, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Add and library actions")
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: audioTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await library.importURLs(urls) }
            }
        }
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await library.importURLs(urls) }
            }
        }
        .overlay {
            if library.isScanning {
                ProgressView(library.statusMessage.isEmpty ? "Scanning…" : library.statusMessage)
                    .padding(20)
                    .glassCard(corner: 16)
            }
        }
        .task {
            // Wait for catalog JSON first — never race empty tracks into a full folder rescan.
            await library.ensureLibraryReady()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.app(size: 48))
                .foregroundStyle(theme.accent)
            Text("No tracks yet")
                .font(.app(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text("Import a whole folder of music, or pick individual files (MP3, M4A, FLAC, WAV…).")
                .font(.app(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showFileImporter = true
            } label: {
                Label("Import Audio Files", systemImage: "square.and.arrow.down")
                    .font(.app(size: 15, weight: .bold, design: .rounded))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
        }
    }

    private var audioTypes: [UTType] {
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        if let flac = UTType(filenameExtension: "flac") { types.append(flac) }
        if let m4a = UTType(filenameExtension: "m4a") { types.append(m4a) }
        if let alac = UTType(filenameExtension: "alac") { types.append(alac) }
        if let ogg = UTType(filenameExtension: "ogg") { types.append(ogg) }
        return types
    }
}

// MARK: - Artists

struct ArtistsListView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerEngine
    @Environment(\.grokTheme) private var theme

    var body: some View {
        List {
            ForEach(library.artistGroups) { artist in
                NavigationLink {
                    ArtistDetailView(artist: artist)
                } label: {
                    HStack(spacing: 12) {
                        artistArt(artist)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(artist.name)
                                .font(.app(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                            Text("\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s") · \(artist.tracks.count) track\(artist.tracks.count == 1 ? "" : "s")")
                                .font(.app(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        library.deleteArtist(artist)
                    } label: {
                        Label("Delete Artist", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        library.deleteArtist(artist)
                    } label: {
                        Label("Delete Artist", systemImage: "trash")
                    }
                }
            }
            .onDelete { indexSet in
                for idx in indexSet {
                    if idx < library.artistGroups.count {
                        let art = library.artistGroups[idx]
                        library.deleteArtist(art)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .grokScrollEdgeBlur()
        .background { theme.background.ignoresSafeArea() }
        .grokStyleNavigationChrome(title: "Artists")
    }

    @ViewBuilder
    private func artistArt(_ artist: ArtistGroup) -> some View {
        if let img = ArtworkImageCache.image(dataKey: "artist-\(artist.id)", data: artist.artworkData) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                theme.elevated
                Image(systemName: "person.fill")
                    .foregroundStyle(theme.tertiaryText)
            }
        }
    }
}

struct ArtistDetailView: View {
    let artist: ArtistGroup
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerEngine
    @Environment(\.grokTheme) private var theme

    var body: some View {
        List {
            ForEach(artist.albums) { album in
                Section {
                    let ordered = album.tracks.sorted(by: LibraryStore.albumPlaybackOrder)
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, track in
                        Button {
                            player.play(tracks: ordered, startAt: index)
                        } label: {
                            TrackRowView(
                                track: track,
                                isPlaying: player.currentTrack?.id == track.id,
                                trackIndex: LibraryStore.inferredTrackNumber(for: track) ?? (index + 1)
                            )
                        }
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                library.deleteTrack(track)
                            } label: {
                                Label("Delete Track", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                library.deleteTrack(track)
                            } label: {
                                Label("Delete Track", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 10) {
                        albumArt(album)
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.name)
                                .font(.app(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                            Text("\(album.tracks.count) track\(album.tracks.count == 1 ? "" : "s")")
                                .font(.app(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.tertiaryText)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            library.deleteAlbum(album)
                        } label: {
                            Image(systemName: "trash")
                                .font(.app(size: 12, weight: .semibold))
                                .foregroundStyle(theme.danger)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .grokScrollEdgeBlur()
        .background { theme.background.ignoresSafeArea() }
        // Keep hamburger available on detail (back + menu); users expect Settings from album art flows.
        .grokStyleNavigationChrome(title: artist.name, showsBack: true, showsMenu: true) {
            Button(role: .destructive) {
                library.deleteArtist(artist)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(theme.danger)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Delete artist")
        }
    }

    @ViewBuilder
    private func albumArt(_ album: AlbumGroup) -> some View {
        if let img = ArtworkImageCache.image(dataKey: "album-\(album.id)", data: album.artworkData) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            ZStack {
                theme.elevated
                Image(systemName: "square.stack")
                    .foregroundStyle(theme.tertiaryText)
            }
        }
    }
}

// MARK: - Albums

struct AlbumsListView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerEngine
    @Environment(\.grokTheme) private var theme

    var body: some View {
        List {
            // Stable identity: artist|album — equal titles no longer fight over one row.
            ForEach(library.albumGroups) { album in
                NavigationLink {
                    AlbumDetailView(album: album)
                } label: {
                    HStack(spacing: 12) {
                        albumArt(album)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(album.name.isEmpty ? "Unknown Album" : album.name)
                                .font(.app(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                            Text("\(album.artist) · \(album.tracks.count) track\(album.tracks.count == 1 ? "" : "s")")
                                .font(.app(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        library.deleteAlbum(album)
                    } label: {
                        Label("Delete Album", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        library.deleteAlbum(album)
                    } label: {
                        Label("Delete Album", systemImage: "trash")
                    }
                }
            }
            .onDelete { indexSet in
                for idx in indexSet {
                    if idx < library.albumGroups.count {
                        let alb = library.albumGroups[idx]
                        library.deleteAlbum(alb)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .grokScrollEdgeBlur()
        .background { theme.background.ignoresSafeArea() }
        .grokStyleNavigationChrome(title: "Albums")
    }

    @ViewBuilder
    private func albumArt(_ album: AlbumGroup) -> some View {
        if let img = ArtworkImageCache.image(dataKey: "album-\(album.id)", data: album.artworkData) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            ZStack {
                theme.elevated
                Image(systemName: "square.stack")
                    .foregroundStyle(theme.tertiaryText)
            }
        }
    }
}

struct AlbumDetailView: View {
    let album: AlbumGroup
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerEngine
    @Environment(\.grokTheme) private var theme

    /// Always re-apply album playback order (tags + filename) so stale groups can’t A–Z live sets.
    private var orderedTracks: [Track] {
        album.tracks.sorted(by: LibraryStore.albumPlaybackOrder)
    }

    var body: some View {
        List {
            ForEach(Array(orderedTracks.enumerated()), id: \.element.id) { index, track in
                Button {
                    player.play(tracks: orderedTracks, startAt: index)
                } label: {
                    TrackRowView(
                        track: track,
                        isPlaying: player.currentTrack?.id == track.id,
                        trackIndex: LibraryStore.inferredTrackNumber(for: track) ?? (index + 1)
                    )
                }
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        library.deleteTrack(track)
                    } label: {
                        Label("Delete Track", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        player.playNext(track)
                    } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .tint(theme.accent)
                    Button {
                        player.addToQueue(track)
                    } label: {
                        Label("Queue", systemImage: "text.append")
                    }
                    .tint(.indigo)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .grokScrollEdgeBlur()
        .background { theme.background.ignoresSafeArea() }
        .grokStyleNavigationChrome(title: album.name, showsBack: true, showsMenu: true) {
            Button(role: .destructive) {
                library.deleteAlbum(album)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(theme.danger)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Delete album")
        }
    }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayerEngine
    @Environment(\.grokTheme) private var theme

    @State private var query = ""

    private var results: [Track] {
        library.search(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.tertiaryText)
                TextField("Songs, artists, albums", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(theme.primaryText)
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.tertiaryText)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .glassCard(corner: 14)
            .padding(16)

            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.app(size: 40, weight: .medium))
                        .foregroundStyle(theme.tertiaryText)
                    Text("Search your library")
                        .font(.app(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("Find songs by title, artist, or album.")
                        .font(.app(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    if !library.tracks.isEmpty {
                        Text("\(library.tracks.count) tracks · \(library.knownBPMCount) BPM · \(library.missingBPMCount) missing")
                            .font(.app(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.tertiaryText)
                            .padding(.top, 4)
                    }
                    Spacer()
                }
            } else if results.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "music.note.list")
                        .font(.app(size: 36, weight: .medium))
                        .foregroundStyle(theme.tertiaryText)
                    Text("No matches")
                        .font(.app(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("Nothing matched “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                        .font(.app(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                }
            } else {
                List {
                    Section {
                        ForEach(results) { track in
                            Button {
                                player.play(
                                    tracks: results,
                                    startAt: results.firstIndex(where: { $0.id == track.id }) ?? 0
                                )
                            } label: {
                                TrackRowView(track: track, isPlaying: player.currentTrack?.id == track.id)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
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
                                Button {
                                    player.addToQueue(track)
                                } label: {
                                    Label("Add to Queue", systemImage: "text.append")
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    library.deleteTrack(track)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    player.playNext(track)
                                } label: {
                                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                }
                                .tint(theme.accent)
                            }
                        }
                    } header: {
                        Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                            .font(.app(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.tertiaryText)
                            .textCase(nil)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .grokScrollEdgeBlur()
            }
        }
        .background { theme.background.ignoresSafeArea() }
        .grokStyleNavigationChrome(title: "Search")
    }
}
