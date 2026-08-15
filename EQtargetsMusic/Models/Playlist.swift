//
//  Playlist.swift
//  EQtargetsMusic
//
//  User-created playlists. Selection/order only — playlists never own audio,
//  never touch the EQ chain, and never duplicate Track payloads.
//
//  IDENTITY (the reason entries are not plain UUIDs)
//  ------------------------------------------------------------------
//  `Track.id` defaults to a fresh `UUID()` at init, and `LibraryStore` matches
//  re-discovered files by `fileKey`, not by id. So a track keeps its id only
//  while the catalog JSON survives — delete it, or rescan into an empty
//  catalog, and every id in the library is regenerated.
//
//  A playlist storing bare UUIDs would therefore look intact on disk and
//  resolve to nothing, silently emptying every playlist the user built. Each
//  entry stores the id *and* the `fileKey`, and resolution falls back to the
//  key, which is what LibraryStore itself treats as file identity.
//

import Foundation

// MARK: - Duplicate detection

/// Normalised song identity, for catching the *same song imported twice* — the
/// same track sitting in two folders, or on both an album and a compilation.
/// `fileKey` only catches the identical file.
///
/// **What it compares, and why not artwork.** Title + artist, normalised, with
/// duration as a tiebreak. Artwork was considered and rejected: two encodings of
/// the same cover differ byte for byte, so a byte compare finds nothing, and a
/// perceptual hash is a lot of machinery to answer a question duration already
/// answers. Album is deliberately *not* required — the same song on an album and
/// on a compilation is exactly the duplicate worth catching.
enum TrackSignature {

    /// Songs within this many seconds of each other count as the same length.
    /// Different masterings of one song drift by a second or two; genuinely
    /// different songs sharing a title and artist rarely land this close.
    static let durationTolerance: TimeInterval = 5

    /// Lowercased, diacritic-folded, punctuation-stripped, whitespace-collapsed.
    /// "Alabaré  al Señor!" and "alabare al senor" become the same string.
    ///
    /// Parenthetical suffixes are deliberately **kept**: "(En Vivo)" is a real
    /// difference in a worship library, and folding it away would silently merge
    /// a live cut with its studio version.
    static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let stripped = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// "title|artist" — the key duplicates are grouped by.
    static func key(title: String, artist: String) -> String {
        "\(normalize(title))|\(normalize(artist))"
    }

    static func key(for track: Track) -> String {
        key(title: track.title, artist: track.artist)
    }

    /// True when two entries look like the same song.
    static func isDuplicate(
        key lhsKey: String,
        duration lhsDuration: TimeInterval?,
        of rhsKey: String,
        duration rhsDuration: TimeInterval?
    ) -> Bool {
        guard !lhsKey.isEmpty, lhsKey == rhsKey else { return false }
        // A missing duration on either side falls back to the key alone rather
        // than refusing to match — an unknown length is not evidence of a
        // different song.
        guard let a = lhsDuration, let b = rhsDuration, a > 0, b > 0 else { return true }
        return abs(a - b) <= durationTolerance
    }
}

// MARK: - Entry

/// One track reference inside a playlist.
struct PlaylistEntry: Codable, Equatable, Identifiable, Hashable {
    /// Fast path — valid for as long as the catalog keeps its ids.
    var trackID: UUID
    /// Durable identity: relative path / resolved file key. Nil only for tracks
    /// that had no resolvable path when they were added.
    var fileKey: String?
    /// Normalised "title|artist" captured at add time, so duplicate detection
    /// works without the library and keeps working for entries whose file is
    /// currently missing. See `TrackSignature`.
    var signature: String?
    /// Length in seconds at add time — the tiebreak for duplicate detection.
    var duration: TimeInterval?

    var id: UUID { trackID }

    init(trackID: UUID, fileKey: String?, signature: String? = nil, duration: TimeInterval? = nil) {
        self.trackID = trackID
        self.fileKey = fileKey
        self.signature = signature
        self.duration = duration
    }

    init(track: Track) {
        self.trackID = track.id
        self.fileKey = track.fileKey
        self.signature = TrackSignature.key(for: track)
        self.duration = track.duration
    }

    /// True when `track` is the same *song* as this entry, even if it is a
    /// different file. Falls back to exact identity when no signature was
    /// stored (entries written before duplicate detection existed).
    func isSameSong(as track: Track) -> Bool {
        guard let signature else { return matches(track) }
        return TrackSignature.isDuplicate(
            key: signature,
            duration: duration,
            of: TrackSignature.key(for: track),
            duration: track.duration
        )
    }

    /// True when this entry refers to `track` by either identity.
    func matches(_ track: Track) -> Bool {
        if track.id == trackID { return true }
        if let fileKey, let other = track.fileKey, !fileKey.isEmpty { return fileKey == other }
        return false
    }
}

// MARK: - Playlist

struct Playlist: Codable, Equatable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// User order — never sorted implicitly. A worship set is a sequence.
    var entries: [PlaylistEntry]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        entries: [PlaylistEntry] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.entries = entries
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var count: Int { entries.count }

    var subtitle: String {
        entries.isEmpty ? "No songs" : "\(entries.count) song\(entries.count == 1 ? "" : "s")"
    }

    /// Exact match — the same file.
    func contains(_ track: Track) -> Bool {
        entries.contains { $0.matches(track) }
    }

    /// The same song, even as a different file (other folder, other album).
    func containsSameSong(as track: Track) -> Bool {
        entries.contains { $0.matches(track) || $0.isSameSong(as: track) }
    }

    /// Resolve entries against the live library, in playlist order.
    ///
    /// Entries that no longer resolve (file deleted outside the app) are simply
    /// dropped from the result rather than surfaced as blank rows — but they are
    /// **not** removed from the stored playlist, so re-importing the file brings
    /// the song back where it was instead of silently losing the user's order.
    func resolvedTracks(in tracks: [Track]) -> [Track] {
        guard !entries.isEmpty, !tracks.isEmpty else { return [] }

        var byID: [UUID: Track] = [:]
        var byKey: [String: Track] = [:]
        byID.reserveCapacity(tracks.count)
        for t in tracks {
            byID[t.id] = t
            if let k = t.fileKey, !k.isEmpty, byKey[k] == nil { byKey[k] = t }
        }

        var seen = Set<UUID>()
        var out: [Track] = []
        out.reserveCapacity(entries.count)
        for entry in entries {
            let match = byID[entry.trackID] ?? entry.fileKey.flatMap { byKey[$0] }
            guard let track = match, !seen.contains(track.id) else { continue }
            seen.insert(track.id)
            out.append(track)
        }
        return out
    }

    /// How many entries currently resolve — for "3 songs missing" style UI.
    func resolvedCount(in tracks: [Track]) -> Int {
        resolvedTracks(in: tracks).count
    }
}
