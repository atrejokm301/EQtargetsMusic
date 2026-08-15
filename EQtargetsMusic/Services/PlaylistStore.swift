//
//  PlaylistStore.swift
//  EQtargetsMusic
//
//  Persistence + mutations for user playlists. Selection only — this never
//  touches AVAudioEngine, the EQ chain, the queue, or LibraryStore's catalog.
//
//  Stored as JSON in Documents rather than UserDefaults: a 500-track playlist
//  is ~30 KB of ids and keys, and a handful of those is past the size
//  UserDefaults is meant for. LibraryStore already keeps its catalog next to
//  this, so playlists back up and restore with the rest of the user's library.
//

import Foundation
import os

@MainActor
final class PlaylistStore: ObservableObject {

    @Published private(set) var playlists: [Playlist] = []

    private static let fileName = "playlists.v1.json"
    private static let log = Logger(subsystem: "com.eqtargets.music", category: "Playlists")

    /// Writes happen off the main actor — encoding is cheap but the file write
    /// is not something the UI should ever wait on.
    private let ioQueue = DispatchQueue(label: "com.eqtargets.music.playlists.io", qos: .utility)

    private var fileURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.fileName)
    }

    init() {
        load()
    }

    // MARK: - Load / save

    private func load() {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            playlists = try JSONDecoder().decode([Playlist].self, from: data)
        } catch {
            // A corrupt file must not take the app down or wipe itself — leave it
            // on disk so it can be recovered, and start from empty this launch.
            Self.log.error("playlist load failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func save() {
        let snapshot = playlists
        let url = fileURL
        ioQueue.async {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                Self.log.error("playlist save failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Lookup

    func playlist(id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    /// Playlists already containing `track` — drives the checkmarks in the
    /// add sheet so the user can see where a song already lives.
    func playlistsContaining(_ track: Track) -> Set<UUID> {
        Set(playlists.filter { $0.contains(track) }.map(\.id))
    }

    /// Case- and whitespace-insensitive name collision check.
    func nameExists(_ name: String, excluding id: UUID? = nil) -> Bool {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return false }
        return playlists.contains {
            $0.id != id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target
        }
    }

    // MARK: - Mutations

    @discardableResult
    func create(name: String, tracks: [Track] = []) -> Playlist? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var playlist = Playlist(name: trimmed)
        playlists.append(playlist)
        // Route the initial batch through add() so it gets the same duplicate
        // handling as any later addition — creating from a selection that spans
        // two albums must not smuggle a duplicate in.
        if !tracks.isEmpty {
            add(tracks, to: playlist.id)
            playlist = playlists.last ?? playlist
        } else {
            save()
        }
        return playlist
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].name = trimmed
        playlists[idx].updatedAt = Date()
        save()
    }

    func delete(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func delete(at offsets: IndexSet) {
        playlists.remove(atOffsets: offsets)
        save()
    }

    func movePlaylists(from source: IndexSet, to destination: Int) {
        playlists.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Append tracks, skipping ones already there.
    ///
    /// Skips both the identical file and the *same song* as a different file —
    /// the same track in two folders, or on an album and a compilation. See
    /// `TrackSignature`. Duplicates inside the incoming batch are caught too, so
    /// selecting a song twice across two albums files it once.
    ///
    /// - Returns: how many were added and how many were skipped, so the caller
    ///   can say "3 added, 1 duplicate" rather than appearing to do nothing.
    @discardableResult
    func add(_ tracks: [Track], to id: UUID, skipDuplicates: Bool = true) -> (added: Int, duplicates: Int) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }), !tracks.isEmpty else {
            return (0, 0)
        }
        var added = 0
        var duplicates = 0
        for track in tracks {
            let isDuplicate = skipDuplicates
                ? playlists[idx].containsSameSong(as: track)
                : playlists[idx].contains(track)
            if isDuplicate {
                duplicates += 1
                continue
            }
            playlists[idx].entries.append(PlaylistEntry(track: track))
            added += 1
        }
        if added > 0 {
            playlists[idx].updatedAt = Date()
            save()
        }
        return (added, duplicates)
    }

    /// Collapse a playlist that already has duplicates in it, keeping the first
    /// occurrence of each song so the user's ordering survives.
    /// - Returns: how many entries were removed.
    @discardableResult
    func removeDuplicates(in id: UUID) -> Int {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return 0 }
        var kept: [PlaylistEntry] = []
        var removed = 0
        for entry in playlists[idx].entries {
            let clash = kept.contains { existing in
                if existing.trackID == entry.trackID { return true }
                if let a = existing.fileKey, let b = entry.fileKey, !a.isEmpty, a == b { return true }
                guard let sa = existing.signature, let sb = entry.signature else { return false }
                return TrackSignature.isDuplicate(
                    key: sa, duration: existing.duration,
                    of: sb, duration: entry.duration
                )
            }
            if clash { removed += 1 } else { kept.append(entry) }
        }
        guard removed > 0 else { return 0 }
        playlists[idx].entries = kept
        playlists[idx].updatedAt = Date()
        save()
        return removed
    }

    func remove(_ track: Track, from id: UUID) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        let before = playlists[idx].entries.count
        playlists[idx].entries.removeAll { $0.matches(track) }
        guard playlists[idx].entries.count != before else { return }
        playlists[idx].updatedAt = Date()
        save()
    }

    /// Remove by *resolved* offsets — the indices the user sees, which skip any
    /// unresolvable entries, so they cannot be applied to `entries` directly.
    func removeResolved(at offsets: IndexSet, from id: UUID, resolved: [Track]) {
        let targets = offsets.compactMap { $0 < resolved.count ? resolved[$0] : nil }
        guard !targets.isEmpty, let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[idx].entries.removeAll { entry in targets.contains { entry.matches($0) } }
        playlists[idx].updatedAt = Date()
        save()
    }

    /// Reorder by resolved offsets. Rebuilds the stored order from the visible
    /// one, then re-appends any unresolvable entries at the end so a missing
    /// file never silently drops out of the playlist during a drag.
    func moveResolved(from source: IndexSet, to destination: Int, in id: UUID, resolved: [Track]) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }

        var visible = resolved
        visible.move(fromOffsets: source, toOffset: destination)

        let stored = playlists[idx].entries
        var reordered: [PlaylistEntry] = []
        reordered.reserveCapacity(stored.count)
        for track in visible {
            if let entry = stored.first(where: { $0.matches(track) }) {
                reordered.append(entry)
            }
        }
        let unresolved = stored.filter { entry in !visible.contains { entry.matches($0) } }
        playlists[idx].entries = reordered + unresolved
        playlists[idx].updatedAt = Date()
        save()
    }
}
