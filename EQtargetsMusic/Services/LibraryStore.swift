//
//  LibraryStore.swift
//  EQtargetsMusic
//
//  Scans Documents/Music + user imports (files or whole folders).
//  Supports large imports (up to maxFilesPerImport) without embedding
//  full-size album art (thumbnails only) so the catalog stays light.
//

import Foundation
import AVFoundation
import UIKit
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var tracks: [Track] = [] {
        didSet { rebuildGroups() }
    }
    /// Cached — rebuilt only when `tracks` changes (not every SwiftUI body / scroll frame).
    @Published private(set) var artistGroups: [ArtistGroup] = []
    @Published private(set) var albumGroups: [AlbumGroup] = []
    @Published private(set) var isScanning = false
    /// True while offline BPM analysis is running (backend only — no Now Playing chrome).
    @Published private(set) var isAnalyzingBPM = false
    /// Catalog JSON finished loading (success or missing file). Prevents empty→rescan race on cold start.
    @Published private(set) var isCatalogReady = false
    @Published var statusMessage: String = ""

    /// Soft cap per import session — high enough for full libraries (was never a hard 100 limit in code;
    /// memory from full-res art was the real bottleneck). Raise freely if needed.
    static let maxFilesPerImport = 10_000
    /// Offline BPM analysis cap per idle session (battery). Already-checked tracks are skipped.
    static let maxBPMAnalysesPerScan = 48
    /// Bump when detector improves — re-runs tracks that were “checked” but got no BPM.
    /// v4 = spectral-flux multi-window detector rewrite.
    private static let bpmEngineVersion = 4
    private static let bpmEngineVersionKey = "eqtargets.bpmEngineVersion"

    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "alac", "mp4", "wav", "aiff", "aif", "caf",
        "flac", "ogg", "opus", "wma"
    ]

    private let catalogURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var autoBPMTask: Task<Void, Never>?
    private var catalogLoadTask: Task<Void, Never>?

    /// How many tracks still need a first-time / retry BPM analysis pass.
    var uncheckedBPMCount: Int { tracks.filter { !$0.bpmChecked }.count }

    /// How many tracks have a usable BPM value.
    var knownBPMCount: Int { tracks.filter(\.hasBPM).count }

    /// Tracks with no usable BPM yet (whether or not a previous detector attempt ran).
    var missingBPMCount: Int { tracks.filter { !$0.hasBPM }.count }

    /// Lookup helpers for player ↔ library sync (id first, then file path).
    func track(matching other: Track) -> Track? {
        if let t = tracks.first(where: { $0.id == other.id }) { return t }
        if let key = other.fileKey {
            return tracks.first(where: { $0.fileKey == key })
        }
        // Last resort: title+artist+duration (handles re-import with new ids)
        return tracks.first(where: {
            $0.title == other.title
                && $0.artist == other.artist
                && abs($0.duration - other.duration) < 0.5
        })
    }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let music = docs.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        catalogURL = docs.appendingPathComponent("library_catalog.json")
        loadCatalog()
    }

    /// Wait for catalog decode, then only folder-scan if the library is truly empty (first launch).
    /// Fixes hard-stop reopen: UI used to see empty tracks before JSON loaded and trigger a full rescan.
    func ensureLibraryReady() async {
        if let catalogLoadTask {
            await catalogLoadTask.value
        }
        // Catalog present (even 0 tracks after load) → never auto-rescan on every launch.
        guard isCatalogReady else { return }
        guard tracks.isEmpty else {
            startAutoBPMIfNeeded()
            return
        }
        // Empty catalog file or first install — one folder scan only when Music dir may have files.
        await rescan()
        startAutoBPMIfNeeded()
    }

    /// Quiet background BPM for unchecked tracks only (no UI chrome).
    /// Skips when backgrounded, thermally warm, or low power mode.
    func startAutoBPMIfNeeded() {
        guard isCatalogReady else { return }
        guard !isAnalyzingBPM, !isScanning else { return }
        applyBPMEngineMigrationIfNeeded()
        guard uncheckedBPMCount > 0 else { return }
        guard Self.deviceAllowsBackgroundWork else { return }
        // Already scheduled.
        if let autoBPMTask, !autoBPMTask.isCancelled { return }
        autoBPMTask = Task(priority: .utility) { [weak self] in
            // Wait until UI is idle so first frame / playback stays snappy.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard Self.deviceAllowsBackgroundWork else { return }
            await self.analyzeMissingBPMs(limit: Self.maxBPMAnalysesPerScan)
        }
    }

    /// Cheap gates so BPM never fights the user for battery/thermals.
    private static var deviceAllowsBackgroundWork: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return false
        default: break
        }
        // Don't start heavy decode while app is not active.
        if UIApplication.shared.applicationState == .background { return false }
        return true
    }

    /// When the detector is upgraded, re-open tracks that were marked checked with no BPM.
    private func applyBPMEngineMigrationIfNeeded() {
        let stored = UserDefaults.standard.integer(forKey: Self.bpmEngineVersionKey)
        guard stored < Self.bpmEngineVersion else { return }
        var next = tracks
        var reset = 0
        for i in next.indices {
            // Re-run anything without a usable tempo. Tag BPMs keep hasBPM and stay.
            if !next[i].hasBPM {
                next[i].bpmChecked = false
                // Clear garbage values outside the usable band.
                if let b = next[i].bpm, !(b.isFinite && b > 20 && b < 400) {
                    next[i].bpm = nil
                }
                reset += 1
            }
        }
        if reset > 0 {
            tracks = next
            saveCatalog()
            statusMessage = "\(tracks.count) tracks · BPM engine v\(Self.bpmEngineVersion) · re-scan \(reset)"
        }
        UserDefaults.standard.set(Self.bpmEngineVersion, forKey: Self.bpmEngineVersionKey)
    }

    /// Back-compat accessors used by views.
    var artists: [ArtistGroup] { artistGroups }
    var albums: [AlbumGroup] { albumGroups }

    /// Rebuild artist/album indexes once per tracks mutation (stable order — no list jumpiness).
    private func rebuildGroups() {
        // Artists
        artistGroups = Dictionary(
            grouping: tracks,
            by: { $0.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        .compactMap { _, list -> ArtistGroup? in
            guard let first = list.first else { return nil }
            let albumsForArtist = Dictionary(
                grouping: list,
                by: { $0.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            )
            .compactMap { _, albList -> AlbumGroup? in
                guard let albFirst = albList.first else { return nil }
                return AlbumGroup(
                    name: albFirst.album.trimmingCharacters(in: .whitespacesAndNewlines),
                    artist: albFirst.artist.trimmingCharacters(in: .whitespacesAndNewlines),
                    tracks: Self.sortTracks(albList)
                )
            }
            // Stable: album name, then artist (identity already includes both).
            .sorted(by: Self.albumSort)

            return ArtistGroup(
                name: first.artist.trimmingCharacters(in: .whitespacesAndNewlines),
                tracks: list,
                albums: albumsForArtist
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Global albums — keyed by artist|album so "Unknown Album" is per-artist.
        albumGroups = Dictionary(
            grouping: tracks,
            by: {
                "\($0.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\($0.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            }
        )
        .compactMap { _, list -> AlbumGroup? in
            guard let first = list.first else { return nil }
            return AlbumGroup(
                name: first.album.trimmingCharacters(in: .whitespacesAndNewlines),
                artist: first.artist.trimmingCharacters(in: .whitespacesAndNewlines),
                tracks: Self.sortTracks(list)
            )
        }
        // CRITICAL: sort by name THEN artist so equal titles ("Unknown Album") never reshuffle.
        .sorted(by: Self.albumSort)
    }

    private static func sortTracks(_ list: [Track]) -> [Track] {
        list.sorted { a, b in
            let discA = a.discNumber ?? 1
            let discB = b.discNumber ?? 1
            if discA != discB { return discA < discB }
            let trkA = a.trackNumber ?? 999
            let trkB = b.trackNumber ?? 999
            if trkA != trkB { return trkA < trkB }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    private static func albumSort(_ a: AlbumGroup, _ b: AlbumGroup) -> Bool {
        let byName = a.name.localizedCaseInsensitiveCompare(b.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        let byArtist = a.artist.localizedCaseInsensitiveCompare(b.artist)
        if byArtist != .orderedSame { return byArtist == .orderedAscending }
        // Final tie-break: stable id string
        return a.id < b.id
    }

    func search(_ query: String) -> [Track] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.artist.localizedCaseInsensitiveContains(q)
                || $0.album.localizedCaseInsensitiveContains(q)
        }
    }

    func rescan() async {
        isScanning = true
        statusMessage = "Scanning Music folder…"
        defer { isScanning = false }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let musicDir = docs.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)

        var fileURLs: [URL] = []
        collectAudioFiles(from: musicDir, into: &fileURLs, limit: Self.maxFilesPerImport)

        var found: [Track] = []
        found.reserveCapacity(fileURLs.count)

        // Reuse existing thumbs + BPM state by relative path (never re-analyze checked tracks).
        var existingByPath: [String: Track] = [:]
        for t in tracks {
            if let rel = t.relativePath {
                existingByPath[rel] = t
            }
        }

        for (i, url) in fileURLs.enumerated() {
            if i % 40 == 0 {
                statusMessage = "Scanning \(i + 1)/\(fileURLs.count)…"
                await Task.yield()
            }
            var relHint: String?
            let path = url.path
            let base = docs.path
            if path.hasPrefix(base) {
                relHint = String(path.dropFirst(base.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            let existing = relHint.flatMap { existingByPath[$0] }
            let haveArt = existing?.artworkData != nil
            if var track = await metadataTrack(for: url, relativeTo: docs, loadArtwork: !haveArt) {
                if haveArt, track.artworkData == nil {
                    track.artworkData = existing?.artworkData
                }
                // Preserve offline BPM work / "already checked" flags across rescan.
                if let existing {
                    if track.bpm == nil, let oldBPM = existing.bpm {
                        track.bpm = oldBPM
                    }
                    track.bpmChecked = existing.bpmChecked || track.bpm != nil || existing.bpm != nil
                    // Keep stable id so now-playing / queue identity survives rescan.
                    track = Track(
                        id: existing.id,
                        title: track.title,
                        artist: track.artist,
                        album: track.album,
                        duration: track.duration,
                        trackNumber: track.trackNumber,
                        discNumber: track.discNumber,
                        bpm: track.bpm,
                        bpmChecked: track.bpmChecked,
                        fileBookmark: track.fileBookmark,
                        relativePath: track.relativePath,
                        artworkData: track.artworkData
                    )
                } else if track.bpm != nil {
                    track.bpmChecked = true
                }
                found.append(track)
            }
        }

        // Keep external bookmark tracks still valid
        for existing in tracks where existing.fileBookmark != nil {
            if existing.resolvedURL() != nil,
               !found.contains(where: { $0.relativePath == existing.relativePath || $0.id == existing.id }) {
                found.append(existing)
            }
        }

        tracks = found.sorted(by: Self.trackSort)
        saveCatalog()

        // One-shot offline BPM for untagged files only (not while playing).
        await analyzeMissingBPMs(limit: Self.maxBPMAnalysesPerScan)

        statusMessage = "\(tracks.count) track\(tracks.count == 1 ? "" : "s")"
    }

    /// Detect BPM from audio for tracks not yet successfully checked.
    /// Batched — one `@Published` write + catalog save at the end (battery/UI thrash).
    func analyzeMissingBPMs(limit: Int = maxBPMAnalysesPerScan) async {
        applyBPMEngineMigrationIfNeeded()

        let pending = tracks.filter { !$0.bpmChecked }
        guard !pending.isEmpty else { return }
        guard !isAnalyzingBPM else { return }
        guard Self.deviceAllowsBackgroundWork else { return }

        isAnalyzingBPM = true
        defer { isAnalyzingBPM = false }

        let batch = Array(pending.prefix(limit))
        statusMessage = "BPM \(knownBPMCount)/\(tracks.count) · analyzing…"

        // Results staged off the hot path — no per-track SwiftUI invalidation.
        // `resolved` false → leave unchecked so a later pass can retry (missing file).
        var results: [(id: UUID, key: String?, bpm: Double?, resolved: Bool)] = []
        results.reserveCapacity(batch.count)

        for (offset, track) in batch.enumerated() {
            if Task.isCancelled { break }
            if offset % 2 == 0 {
                guard Self.deviceAllowsBackgroundWork else { break }
                await Task.yield()
            }

            if let url = track.resolvedURL() {
                let bpm = await Task.detached(priority: .utility) {
                    BPMDetector.estimateBPM(fileURL: url)
                }.value
                results.append((track.id, track.fileKey, bpm, true))
            } else {
                // File not available yet — do NOT mark checked (retry later).
                results.append((track.id, track.fileKey, nil, false))
            }

            // Breathing room so playback / UI keep CPU.
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        guard !results.isEmpty else { return }

        var next = tracks
        var foundCount = 0
        var attempted = 0
        for r in results {
            guard let idx = next.firstIndex(where: { $0.id == r.id })
                    ?? r.key.flatMap({ key in next.firstIndex(where: { $0.fileKey == key }) })
            else { continue }
            guard r.resolved else { continue }
            attempted += 1
            next[idx].bpmChecked = true
            if let bpm = r.bpm, bpm.isFinite, bpm > 20, bpm < 400 {
                // Always store detector result when we didn't already have a tag BPM.
                if next[idx].bpm == nil || !next[idx].hasBPM {
                    next[idx].bpm = bpm
                    foundCount += 1
                }
            }
        }
        tracks = next
        saveCatalog()

        let remaining = tracks.filter { !$0.bpmChecked }.count
        let known = tracks.filter(\.hasBPM).count
        statusMessage = "\(tracks.count) tracks · \(known) BPM · \(remaining) pending"
        if remaining > 0 {
            scheduleFollowUpBPMBatch()
        }
        _ = attempted
        _ = foundCount
    }

    private func scheduleFollowUpBPMBatch() {
        autoBPMTask?.cancel()
        autoBPMTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s cool-down between batches
            guard let self, !Task.isCancelled else { return }
            guard Self.deviceAllowsBackgroundWork else { return }
            await self.analyzeMissingBPMs(limit: Self.maxBPMAnalysesPerScan)
        }
    }

    /// Force re-detect on every track that still has no BPM (menu / power-user).
    func forceRedetectMissingBPMValues() async {
        var next = tracks
        var reset = 0
        for i in next.indices where !next[i].hasBPM {
            next[i].bpmChecked = false
            reset += 1
        }
        tracks = next
        if reset > 0 {
            statusMessage = "Re-analyzing BPM on \(reset) tracks…"
            saveCatalog()
        }
        // Drain in larger batches until done or device gates stop us.
        var safety = 0
        while uncheckedBPMCount > 0, safety < 40 {
            safety += 1
            let before = uncheckedBPMCount
            await analyzeMissingBPMs(limit: min(Self.maxBPMAnalysesPerScan * 2, 96))
            if uncheckedBPMCount >= before { break } // stalled (thermal / missing files)
            if !Self.deviceAllowsBackgroundWork { break }
        }
    }

    /// Import files and/or folders (recursive). No practical small cap — up to maxFilesPerImport.
    func importURLs(_ urls: [URL]) async {
        isScanning = true
        statusMessage = "Collecting files…"
        defer { isScanning = false }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let musicDir = docs.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)

        // Hold security scope open for root picks while we enumerate
        var scoped: [URL] = []
        for url in urls {
            if url.startAccessingSecurityScopedResource() {
                scoped.append(url)
            }
        }
        defer {
            for u in scoped { u.stopAccessingSecurityScopedResource() }
        }

        var fileURLs: [URL] = []
        for url in urls {
            collectAudioFiles(from: url, into: &fileURLs, limit: Self.maxFilesPerImport)
            if fileURLs.count >= Self.maxFilesPerImport { break }
        }

        // De-dupe by last path component + size if available
        var seen = Set<String>()
        fileURLs = fileURLs.filter { url in
            let key = url.path
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        let total = fileURLs.count
        if total == 0 {
            statusMessage = "No audio files found"
            return
        }

        statusMessage = "Importing 0/\(total)…"
        var imported = 0

        for (i, url) in fileURLs.enumerated() {
            if i % 25 == 0 {
                statusMessage = "Importing \(i)/\(total)…"
                await Task.yield()
            }

            // Nested security scope for children of a folder pick
            let childAccess = url.startAccessingSecurityScopedResource()
            defer { if childAccess { url.stopAccessingSecurityScopedResource() } }

            let destName = uniqueDestName(for: url, in: musicDir)
            let dest = musicDir.appendingPathComponent(destName)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    // Same name already present — skip copy; rescan will index it.
                    // Prefer updating from source only when sizes differ (true new file collision).
                    if let srcSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                       let dstSize = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                       srcSize != dstSize {
                        let alt = uniqueDestName(for: url, in: musicDir)
                        let altDest = musicDir.appendingPathComponent(alt)
                        if !FileManager.default.fileExists(atPath: altDest.path) {
                            try FileManager.default.copyItem(at: url, to: altDest)
                        }
                    }
                    imported += 1
                    continue
                }
                try FileManager.default.copyItem(at: url, to: dest)
                imported += 1
            } catch {
                // Fallback: bookmark only (no copy)
                if let bookmark = try? url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ), let track = await metadataTrack(for: url, relativeTo: nil, bookmark: bookmark, loadArtwork: false) {
                    if !tracks.contains(where: {
                        $0.title == track.title && $0.artist == track.artist && $0.album == track.album
                    }) {
                        tracks.append(track)
                        imported += 1
                    }
                }
            }
        }

        statusMessage = "Imported \(imported). Building library…"
        await rescan()
        statusMessage = "\(tracks.count) tracks"
    }

    // MARK: - Collect

    private func collectAudioFiles(from url: URL, into result: inout [URL], limit: Int) {
        guard result.count < limit else { return }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }

        if isDir.boolValue {
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for case let child as URL in enumerator {
                if result.count >= limit { break }
                let ext = child.pathExtension.lowercased()
                if Self.supportedExtensions.contains(ext) {
                    result.append(child)
                }
            }
        } else {
            let ext = url.pathExtension.lowercased()
            if Self.supportedExtensions.contains(ext) {
                result.append(url)
            }
        }
    }

    private func uniqueDestName(for url: URL, in musicDir: URL) -> String {
        let base = url.lastPathComponent
        let dest = musicDir.appendingPathComponent(base)
        if !FileManager.default.fileExists(atPath: dest.path) { return base }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            if !FileManager.default.fileExists(atPath: musicDir.appendingPathComponent(name).path) {
                return name
            }
            i += 1
        }
    }

    // MARK: - Metadata (lightweight art)

    private func metadataTrack(
        for url: URL,
        relativeTo docs: URL?,
        bookmark: Data? = nil,
        loadArtwork: Bool = true
    ) async -> Track? {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = "Unknown Artist"
        var album = "Unknown Album"
        var duration: TimeInterval = 0
        var art: Data?

        do {
            let cm = try await asset.load(.duration)
            duration = CMTimeGetSeconds(cm)
            if duration.isNaN || duration.isInfinite { duration = 0 }
        } catch { }

        var trackNum: Int?
        var discNum: Int?

        do {
            let meta = try await asset.load(.commonMetadata)
            for item in meta {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let s = try? await item.load(.stringValue), !s.isEmpty { title = s }
                case .commonKeyArtist:
                    if let s = try? await item.load(.stringValue), !s.isEmpty { artist = s }
                case .commonKeyAlbumName:
                    if let s = try? await item.load(.stringValue), !s.isEmpty { album = s }
                case .commonKeyArtwork:
                    guard loadArtwork else { break }
                    if let d = try? await item.load(.dataValue) {
                        art = Self.thumbnailJPEG(from: d) // tiny — bulk import safe
                    }
                default: break
                }
            }
        } catch { }

        var bpmVal: Double?

        // Track / disc / BPM from full metadata set (ID3 TBPM, iTunes, QuickTime, etc.)
        do {
            let meta = try await asset.load(.metadata)
            for item in meta {
                let idRaw = item.identifier?.rawValue.lowercased() ?? ""
                let keyRaw = (item.key as? NSString as String?)?.lowercased()
                    ?? (item.key as? String)?.lowercased()
                    ?? ""
                let commonRaw = item.commonKey?.rawValue.lowercased() ?? ""
                let blob = idRaw + " " + keyRaw + " " + commonRaw

                if trackNum == nil, Self.looksLikeTrackNumberKey(blob) {
                    trackNum = await Self.intMetadata(item)
                } else if discNum == nil, Self.looksLikeDiscNumberKey(blob) {
                    discNum = await Self.intMetadata(item)
                } else if bpmVal == nil, Self.looksLikeBPMKey(blob) {
                    bpmVal = await Self.bpmMetadata(item)
                }
            }
        } catch { }

        // Explicit identifier pass (more reliable than string matching alone).
        if bpmVal == nil {
            bpmVal = await Self.loadBPM(from: asset)
        }

        var rel: String?
        if let docs {
            let path = url.path
            let base = docs.path
            if path.hasPrefix(base) {
                rel = String(path.dropFirst(base.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }

        var bm = bookmark
        if bm == nil, rel == nil {
            bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }

        return Track(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            trackNumber: trackNum,
            discNumber: discNum,
            bpm: bpmVal,
            bpmChecked: bpmVal != nil, // tag hit = no need to analyze later
            fileBookmark: bm,
            relativePath: rel,
            artworkData: art
        )
    }

    func deleteTrack(_ track: Track) {
        if let idx = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks.remove(at: idx)
        }
        if let rel = track.relativePath {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileURL = docs.appendingPathComponent(rel)
            try? FileManager.default.removeItem(at: fileURL)
        }
        saveCatalog()
        statusMessage = "\(tracks.count) track\(tracks.count == 1 ? "" : "s")"
    }

    func deleteAlbum(_ album: AlbumGroup) {
        let toDeleteIDs = Set(album.tracks.map(\.id))
        let deletedTracks = tracks.filter { toDeleteIDs.contains($0.id) }
        tracks.removeAll { toDeleteIDs.contains($0.id) }

        for trk in deletedTracks {
            if let rel = trk.relativePath {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let fileURL = docs.appendingPathComponent(rel)
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        saveCatalog()
        statusMessage = "\(tracks.count) track\(tracks.count == 1 ? "" : "s")"
    }

    func deleteArtist(_ artist: ArtistGroup) {
        let toDeleteIDs = Set(artist.tracks.map(\.id))
        let deletedTracks = tracks.filter { toDeleteIDs.contains($0.id) }
        tracks.removeAll { toDeleteIDs.contains($0.id) }

        for trk in deletedTracks {
            if let rel = trk.relativePath {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let fileURL = docs.appendingPathComponent(rel)
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        saveCatalog()
        statusMessage = "\(tracks.count) track\(tracks.count == 1 ? "" : "s")"
    }

    // MARK: - Metadata helpers (BPM / track / disc)

    private static func looksLikeBPMKey(_ blob: String) -> Bool {
        blob.contains("bpm")
            || blob.contains("beatsperminute")
            || blob.contains("beats per minute")
            || blob.contains("tmpo")
            || blob.contains("tbpm")
            || blob.hasSuffix(".tempo")
            || blob.contains("tempo") && !blob.contains("temporary")
    }

    private static func looksLikeTrackNumberKey(_ blob: String) -> Bool {
        (blob.contains("track") && (blob.contains("number") || blob.contains("num") || blob.hasSuffix("trkn")))
            || blob.contains("trkn")
            || blob.contains("tracknumber")
    }

    private static func looksLikeDiscNumberKey(_ blob: String) -> Bool {
        (blob.contains("disc") && (blob.contains("number") || blob.contains("num") || blob.hasSuffix("disk")))
            || blob.contains("disknumber")
            || blob.contains("discnumber")
            || blob.contains("tpos")
    }

    private static func intMetadata(_ item: AVMetadataItem) async -> Int? {
        if let n = try? await item.load(.numberValue) {
            return n.intValue
        }
        if let s = try? await item.load(.stringValue) {
            let head = s.split(whereSeparator: { $0 == "/" || $0 == " " || $0 == "\t" }).first.map(String.init) ?? s
            if let v = Int(head.trimmingCharacters(in: .whitespacesAndNewlines)) { return v }
        }
        if let data = try? await item.load(.dataValue), data.count >= 2 {
            // iTunes-style binary track pairs sometimes appear as data
            let bytes = [UInt8](data)
            if bytes.count >= 8 {
                // common QuickTime track number layout: 4 zero bytes + 2-byte track + 2-byte total
                let hi = Int(bytes[bytes.count - 4])
                let lo = Int(bytes[bytes.count - 3])
                let n = (hi << 8) | lo
                if n > 0, n < 10_000 { return n }
            }
        }
        return nil
    }

    private static func bpmMetadata(_ item: AVMetadataItem) async -> Double? {
        if let n = try? await item.load(.numberValue) {
            let v = n.doubleValue
            if v > 20, v < 400 { return v }
        }
        if let s = try? await item.load(.stringValue) {
            let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: ".")
            if let v = Double(cleaned), v > 20, v < 400 { return v }
            // e.g. "128 BPM"
            let digits = cleaned.split(whereSeparator: { !$0.isNumber && $0 != "." && $0 != "-" }).first.map(String.init)
            if let d = digits, let v = Double(d), v > 20, v < 400 { return v }
        }
        return nil
    }

    private static func loadBPM(from asset: AVURLAsset) async -> Double? {
        // Prefer well-known identifiers when present on the asset formats.
        let candidates: [AVMetadataIdentifier] = [
            .id3MetadataBeatsPerMinute,   // ID3 TBPM
            .iTunesMetadataBeatsPerMin    // iTunes / M4A
        ]
        for id in candidates {
            let items = AVMetadataItem.metadataItems(from: (try? await asset.load(.metadata)) ?? [], filteredByIdentifier: id)
            for item in items {
                if let v = await bpmMetadata(item) { return v }
            }
        }
        return nil
    }

    /// Downscale cover art so 1000+ tracks don't blow memory / crash catalog save.
    /// 96px @ 0.65 quality is plenty for list rows and lock-screen thumbnails.
    private static func thumbnailJPEG(from data: Data, maxSide: CGFloat = 96) -> Data? {
        guard let image = UIImage(data: data) else {
            // Keep tiny raw blobs only
            return data.count < 24_000 ? data : nil
        }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let newSize = CGSize(width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
        guard newSize.width >= 1, newSize.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1 // fixed pixel size, not screen-scaled (saves RAM)
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let thumb = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return thumb.jpegData(compressionQuality: 0.65)
    }

    /// Music List sorting: Alphabetical A to Z by song title
    private static func trackSort(_ a: Track, _ b: Track) -> Bool {
        let tc = a.title.localizedCaseInsensitiveCompare(b.title)
        if tc != .orderedSame { return tc == .orderedAscending }
        let ac = a.artist.localizedCaseInsensitiveCompare(b.artist)
        if ac != .orderedSame { return ac == .orderedAscending }
        return a.album.localizedCaseInsensitiveCompare(b.album) == .orderedAscending
    }

    // MARK: - Persistence

    private func saveCatalog() {
        // Persist without re-encoding giant images if any slipped through
        do {
            let data = try encoder.encode(tracks)
            try data.write(to: catalogURL, options: .atomic)
        } catch {
            // Retry without artwork if encode/write fails (memory)
            let stripped = tracks.map { t -> Track in
                var c = t
                c.artworkData = nil
                return c
            }
            if let data = try? encoder.encode(stripped) {
                try? data.write(to: catalogURL, options: .atomic)
                tracks = stripped
            }
            print("catalog save: \(error)")
        }
    }

    private func loadCatalog() {
        let url = catalogURL
        catalogLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let decoded: [Track]? = {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode([Track].self, from: data)
            }()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let decoded {
                    self.tracks = decoded
                    self.statusMessage = "\(decoded.count) track\(decoded.count == 1 ? "" : "s")"
                } else {
                    // No catalog yet — leave tracks empty; ensureLibraryReady may rescan once.
                    self.statusMessage = ""
                }
                self.isCatalogReady = true
                // Soft BPM fill only after catalog is ready (no full folder scan).
                self.startAutoBPMIfNeeded()
            }
        }
    }
}
