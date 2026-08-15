//
//  PlaylistTests.swift
//  EQtargetsMusicTests
//
//  The playlist contract, not its internals:
//    • a playlist survives a library rescan that regenerates every Track id;
//    • playlist order is the user's order, never the library's;
//    • entries that cannot resolve are hidden from the UI but never dropped
//      from storage, so re-importing a file restores it in place.
//

import XCTest
@testable import EQtargetsMusic

final class PlaylistTests: XCTestCase {

    private func track(_ title: String, key: String, id: UUID = UUID()) -> Track {
        Track(id: id, title: title, artist: "Artist", album: "Album", duration: 180, relativePath: key)
    }

    // MARK: - Identity

    func test_playlistSurvivesARescanThatRegeneratesEveryTrackID() {
        // The failure this exists to prevent: Track.id defaults to a fresh
        // UUID() and LibraryStore re-matches files by fileKey, so a catalog
        // rebuild changes every id. A playlist keyed on ids alone would still
        // look intact on disk and resolve to nothing.
        let before = [
            track("Alabanza", key: "Music/alabanza.mp3"),
            track("Adoración", key: "Music/adoracion.mp3")
        ]
        let playlist = Playlist(name: "Domingo", entries: before.map(PlaylistEntry.init(track:)))
        XCTAssertEqual(playlist.resolvedTracks(in: before).map(\.title), ["Alabanza", "Adoración"])

        // Same files, all-new ids — exactly what a rescan into an empty catalog does.
        let after = [
            track("Alabanza", key: "Music/alabanza.mp3"),
            track("Adoración", key: "Music/adoracion.mp3")
        ]
        XCTAssertNotEqual(Set(before.map(\.id)), Set(after.map(\.id)), "test needs fresh ids")

        XCTAssertEqual(
            playlist.resolvedTracks(in: after).map(\.title),
            ["Alabanza", "Adoración"],
            "playlist emptied after a rescan — entries are not falling back to fileKey"
        )
    }

    func test_contains_matchesByEitherIdentity() {
        let original = track("Song", key: "Music/song.mp3")
        let playlist = Playlist(name: "P", entries: [PlaylistEntry(track: original)])

        XCTAssertTrue(playlist.contains(original))
        // Same file, new id.
        XCTAssertTrue(playlist.contains(track("Song", key: "Music/song.mp3")))
        // Different file.
        XCTAssertFalse(playlist.contains(track("Other", key: "Music/other.mp3")))
    }

    func test_entryWithNoFileKey_stillMatchesItsOwnID() {
        let id = UUID()
        let entry = PlaylistEntry(trackID: id, fileKey: nil)
        let t = Track(id: id, title: "Bookmarked", duration: 10)
        XCTAssertTrue(entry.matches(t))
    }

    // MARK: - Order

    func test_resolutionKeepsPlaylistOrderNotLibraryOrder() {
        let a = track("A", key: "Music/a.mp3")
        let b = track("B", key: "Music/b.mp3")
        let c = track("C", key: "Music/c.mp3")
        // A worship set is a sequence — resolving must not re-sort it.
        let playlist = Playlist(name: "Set", entries: [c, a, b].map(PlaylistEntry.init(track:)))

        XCTAssertEqual(playlist.resolvedTracks(in: [a, b, c]).map(\.title), ["C", "A", "B"])
    }

    // MARK: - Missing files

    func test_unresolvableEntriesAreHiddenButNotLost() {
        let present = track("Here", key: "Music/here.mp3")
        let missing = track("Gone", key: "Music/gone.mp3")
        let playlist = Playlist(name: "P", entries: [present, missing].map(PlaylistEntry.init(track:)))

        // The missing file is not shown…
        XCTAssertEqual(playlist.resolvedTracks(in: [present]).map(\.title), ["Here"])
        XCTAssertEqual(playlist.resolvedCount(in: [present]), 1)
        // …but it is still stored, so re-importing brings it back in position.
        XCTAssertEqual(playlist.entries.count, 2)
        XCTAssertEqual(
            playlist.resolvedTracks(in: [present, missing]).map(\.title),
            ["Here", "Gone"],
            "re-imported file did not return to its original position"
        )
    }

    func test_duplicateEntriesResolveOnce() {
        let t = track("Song", key: "Music/song.mp3")
        // Two entries pointing at the same file by different identities.
        let playlist = Playlist(name: "P", entries: [
            PlaylistEntry(track: t),
            PlaylistEntry(trackID: UUID(), fileKey: "Music/song.mp3")
        ])
        XCTAssertEqual(playlist.resolvedTracks(in: [t]).count, 1, "same file resolved twice")
    }

    func test_emptyCases() {
        let empty = Playlist(name: "Empty")
        XCTAssertTrue(empty.resolvedTracks(in: [track("A", key: "a")]).isEmpty)
        XCTAssertEqual(empty.subtitle, "No songs")

        let some = Playlist(name: "P", entries: [PlaylistEntry(track: track("A", key: "a"))])
        XCTAssertTrue(some.resolvedTracks(in: []).isEmpty)
        XCTAssertEqual(some.subtitle, "1 song")
    }

    // MARK: - Duplicate detection

    private func song(_ title: String, _ artist: String, key: String, dur: TimeInterval = 200) -> Track {
        Track(id: UUID(), title: title, artist: artist, album: "Album", duration: dur, relativePath: key)
    }

    func test_normalization_foldsAccentsCaseAndPunctuation() {
        XCTAssertEqual(
            TrackSignature.normalize("Alabaré  al Señor!"),
            TrackSignature.normalize("alabare al senor")
        )
    }

    func test_normalization_keepsLiveMarkersDistinct() {
        // "(En Vivo)" is a real difference in a worship library — folding it
        // away would silently merge a live cut with its studio version.
        XCTAssertNotEqual(
            TrackSignature.normalize("Dios de Pactos (En Vivo)"),
            TrackSignature.normalize("Dios de Pactos")
        )
    }

    func test_sameSongInTwoFolders_isCaughtEvenThoughTheFileDiffers() {
        let album = song("Alabaré", "Marcos Witt", key: "Music/album/alabare.mp3")
        let comp = song("alabare", "marcos witt", key: "Music/comp/01 alabare.mp3", dur: 202)
        let playlist = Playlist(name: "P", entries: [PlaylistEntry(track: album)])

        XCTAssertFalse(playlist.contains(comp), "different file should not be an exact match")
        XCTAssertTrue(playlist.containsSameSong(as: comp), "same song was not detected")
    }

    func test_differentSongsAreNotMerged() {
        let a = song("Santo", "Artist A", key: "Music/a.mp3", dur: 200)
        let playlist = Playlist(name: "P", entries: [PlaylistEntry(track: a)])

        XCTAssertFalse(playlist.containsSameSong(as: song("Santo", "Artist B", key: "b", dur: 200)),
                       "same title by a different artist must stay separate")
        XCTAssertFalse(playlist.containsSameSong(as: song("Santo", "Artist A", key: "c", dur: 40)),
                       "a 40s intro is not the 200s song")
        XCTAssertTrue(playlist.containsSameSong(as: song("Santo", "Artist A", key: "d", dur: 203)),
                      "a few seconds of mastering drift is still the same song")
    }

    func test_durationToleranceBoundary() {
        let playlist = Playlist(name: "P", entries: [PlaylistEntry(track: song("X", "Y", key: "a", dur: 200))])
        XCTAssertTrue(playlist.containsSameSong(as: song("X", "Y", key: "b", dur: 205)))
        XCTAssertFalse(playlist.containsSameSong(as: song("X", "Y", key: "c", dur: 205.5)))
    }

    func test_entriesWrittenBeforeSignaturesExisted_stillResolve() {
        let t = song("Old", "Artist", key: "Music/old.mp3")
        let legacy = PlaylistEntry(trackID: t.id, fileKey: t.fileKey)
        XCTAssertNil(legacy.signature)
        XCTAssertTrue(Playlist(name: "P", entries: [legacy]).containsSameSong(as: t),
                      "must fall back to exact identity rather than missing")
    }

    @MainActor
    func test_removeDuplicates_keepsTheFirstOccurrence() {
        let store = PlaylistStore()
        let first = song("Alabaré", "Witt", key: "Music/a/alabare.mp3")
        let other = song("Otra", "Witt", key: "Music/a/otra.mp3")
        let dupe = song("alabare", "witt", key: "Music/b/alabare.mp3", dur: 201)

        guard let p = store.create(name: "Dedup \(UUID().uuidString)") else { return XCTFail("create") }
        defer { store.delete(p.id) }

        // Bypass the add-time check so there is something to clean up.
        store.add([first], to: p.id)
        store.add([other], to: p.id)
        store.add([dupe], to: p.id, skipDuplicates: false)
        XCTAssertEqual(store.playlist(id: p.id)?.entries.count, 3)

        XCTAssertEqual(store.removeDuplicates(in: p.id), 1)
        let kept = store.playlist(id: p.id)?.entries ?? []
        XCTAssertEqual(kept.count, 2)
        // Compare against the Track's own key, not a literal path: `fileKey`
        // is deliberately lower-cased so matching survives a case-insensitive
        // filesystem, and asserting the raw casing here would invite someone
        // to "fix" that normalization and break track matching everywhere.
        XCTAssertEqual(kept.first?.fileKey, first.fileKey, "kept the wrong occurrence")
        XCTAssertEqual(store.removeDuplicates(in: p.id), 0, "second pass should find nothing")
    }

    // MARK: - Store mutations

    @MainActor
    func test_addSkipsDuplicatesAndReportsCounts() {
        let store = PlaylistStore()
        let a = track("A", key: "Music/a.mp3")
        let b = track("B", key: "Music/b.mp3")
        guard let playlist = store.create(name: "Test \(UUID().uuidString)", tracks: [a]) else {
            return XCTFail("create failed")
        }
        defer { store.delete(playlist.id) }

        let result = store.add([a, b], to: playlist.id)
        XCTAssertEqual(result.added, 1, "B should have been added")
        XCTAssertEqual(result.duplicates, 1, "A was already present")
        XCTAssertEqual(store.playlist(id: playlist.id)?.entries.count, 2)
    }

    @MainActor
    func test_createRejectsBlankNames() {
        let store = PlaylistStore()
        XCTAssertNil(store.create(name: "   "))
        XCTAssertNil(store.create(name: ""))
    }
}
