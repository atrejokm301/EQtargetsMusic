//
//  Track.swift
//  EQtargetsMusic
//

import Foundation
import UIKit

struct Track: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var trackNumber: Int?
    var discNumber: Int?
    var bpm: Double?
    /// True once we have a tag BPM **or** finished an offline analysis pass (even if no BPM found).
    /// Prevents re-scanning the same files every Rescan / Detect Missing BPMs.
    var bpmChecked: Bool
    /// Bookmark data or relative path under Documents
    var fileBookmark: Data?
    var relativePath: String?
    var artworkData: Data?
    /// User's own lane call, stored as `TempoLane.rawValue`. Wins over BPM
    /// everywhere — see `TempoFeel.lane(for:)`.
    ///
    /// Tempo cannot decide this: an alabanza de júbilo at 78 BPM and an
    /// adoración at 78 BPM are the same number and opposite lanes, so no
    /// cutoff separates them. Kevin's ear is the ground truth.
    var laneOverrideRaw: Int?

    /// Has a usable tempo for Banger Shuffle / UI badge.
    var hasBPM: Bool {
        guard let bpm else { return false }
        return bpm.isFinite && bpm > 20 && bpm < 400
    }

    /// Stable file key for matching library ↔ player copies (IDs can diverge after re-import).
    var fileKey: String? {
        if let relativePath, !relativePath.isEmpty {
            return relativePath.lowercased()
        }
        return nil
    }

    init(
        id: UUID = UUID(),
        title: String,
        artist: String = "Unknown Artist",
        album: String = "Unknown Album",
        duration: TimeInterval = 0,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        bpm: Double? = nil,
        bpmChecked: Bool = false,
        fileBookmark: Data? = nil,
        relativePath: String? = nil,
        artworkData: Data? = nil,
        laneOverrideRaw: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.bpm = bpm
        // Tag present ⇒ already checked
        self.bpmChecked = bpmChecked || (bpm != nil)
        self.fileBookmark = fileBookmark
        self.relativePath = relativePath
        self.artworkData = artworkData
        self.laneOverrideRaw = laneOverrideRaw
    }

    // Backward-compatible decode for catalogs saved before `bpmChecked`.
    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration
        case trackNumber, discNumber, bpm, bpmChecked
        case fileBookmark, relativePath, artworkData
        case laneOverrideRaw
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        album = try c.decode(String.self, forKey: .album)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        trackNumber = try c.decodeIfPresent(Int.self, forKey: .trackNumber)
        discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber)
        bpm = try c.decodeIfPresent(Double.self, forKey: .bpm)
        let checked = try c.decodeIfPresent(Bool.self, forKey: .bpmChecked) ?? false
        bpmChecked = checked || (bpm != nil)
        fileBookmark = try c.decodeIfPresent(Data.self, forKey: .fileBookmark)
        relativePath = try c.decodeIfPresent(String.self, forKey: .relativePath)
        artworkData = try c.decodeIfPresent(Data.self, forKey: .artworkData)
        laneOverrideRaw = try c.decodeIfPresent(Int.self, forKey: .laneOverrideRaw)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encode(album, forKey: .album)
        try c.encode(duration, forKey: .duration)
        try c.encodeIfPresent(trackNumber, forKey: .trackNumber)
        try c.encodeIfPresent(discNumber, forKey: .discNumber)
        try c.encodeIfPresent(bpm, forKey: .bpm)
        try c.encode(bpmChecked, forKey: .bpmChecked)
        try c.encodeIfPresent(fileBookmark, forKey: .fileBookmark)
        try c.encodeIfPresent(relativePath, forKey: .relativePath)
        try c.encodeIfPresent(artworkData, forKey: .artworkData)
        try c.encodeIfPresent(laneOverrideRaw, forKey: .laneOverrideRaw)
    }

    var artworkImage: UIImage? {
        guard let artworkData else { return nil }
        return UIImage(data: artworkData)
    }

    func resolvedURL() -> URL? {
        // Prefer sandboxed copy under Documents/Music
        if let relativePath {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            // relativePath may be "Music/song.mp3" or just a name
            let url = docs.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            // Fallback: filename only under Music/
            let name = (relativePath as NSString).lastPathComponent
            let music = docs.appendingPathComponent("Music", isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: music.path) {
                return music
            }
        }
        if let fileBookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: fileBookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url
            }
        }
        return nil
    }
}

// MARK: - Security-scoped URL helpers

/// Avoids `sandbox_extension_consume failed: 22` from calling
/// `startAccessingSecurityScopedResource()` on URLs that are **not** security-scoped.
///
/// On iOS, library audio under Documents is already in the app sandbox
/// (`NSHomeDirectory()`). Calling `startAccessing` on those paths returns false
/// and spams the console with Invalid argument (22).
enum SecurityScopedAccess {
    /// True when the file is already inside this app’s sandbox (or the app bundle).
    /// Prefer `NSHomeDirectory()` — covers Documents / Library / tmp after reinstall.
    nonisolated static func isAppContainerURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !path.isEmpty else { return false }

        let home = NSHomeDirectory()
        if path == home || path.hasPrefix(home + "/") { return true }

        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        if path == bundlePath || path.hasPrefix(bundlePath + "/") { return true }

        // tmp can theoretically sit outside home on some OS builds
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        if path == tmp || path.hasPrefix(tmp + "/") { return true }

        return false
    }

    /// Start scope only for **external** security-scoped URLs (document picker / bookmarks).
    /// Returns `true` if the caller must later `stop`.
    @discardableResult
    nonisolated static func startIfNeeded(_ url: URL) -> Bool {
        // Never call startAccessing inside the sandbox — that is the #1 source of
        // `sandbox_extension_consume failed: 22` during playback of Documents/Music.
        if isAppContainerURL(url) { return false }
        return url.startAccessingSecurityScopedResource()
    }

    nonisolated static func stopIfNeeded(_ url: URL, didStart: Bool) {
        guard didStart else { return }
        url.stopAccessingSecurityScopedResource()
    }
}

struct ArtistGroup: Identifiable, Hashable {
    var id: String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    let name: String
    let tracks: [Track]
    let albums: [AlbumGroup]

    var albumCount: Int {
        albums.count
    }

    var artworkData: Data? {
        tracks.first(where: { $0.artworkData != nil })?.artworkData
    }
}

struct AlbumGroup: Identifiable, Hashable {
    /// Always includes artist so "Unknown Album" / shared titles don't collide across artists.
    var id: String {
        let a = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Empty name still unique per artist.
        return "\(a)|\(n.isEmpty ? "unknown album" : n)"
    }
    let name: String
    let artist: String
    let tracks: [Track]

    /// Tracks are pre-sorted when groups are built — avoid re-sorting in every SwiftUI body.
    var sortedTracks: [Track] { tracks }

    var artworkData: Data? {
        tracks.first(where: { $0.artworkData != nil })?.artworkData
    }
}
