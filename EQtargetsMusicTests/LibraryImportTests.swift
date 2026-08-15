//
//  LibraryImportTests.swift
//  EQtargetsMusicTests
//
//  The import contract, not its internals:
//    • adding a song indexes that song only — it never re-derives the whole
//      catalog from disk (that is what made one import cost the library);
//    • re-picking a file already in the library adds nothing and copies
//      nothing (it used to land as "song 2.mp3", duplicating everything);
//    • a real name collision with different bytes still keeps both files;
//    • the explicit Rescan still picks up files added out of band.
//
//  Simulator only: the host app is the real EQtargets Music app, so these
//  tests write into its Documents/Music. On a device that is Kevin's actual
//  library — never touch it.
//

#if targetEnvironment(simulator)

import XCTest
@testable import EQtargetsMusic

@MainActor
final class LibraryImportTests: XCTestCase {

    private var sourceDir: URL!
    private var created: [URL] = []

    private var docs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var musicDir: URL {
        docs.appendingPathComponent("Music", isDirectory: true)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        created = []
    }

    override func tearDownWithError() throws {
        // Only ever remove what this test made.
        for url in created {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: sourceDir)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// A file the importer will accept by extension. The bytes are not real
    /// audio — `metadataTrack` falls back to the filename for the title and 0
    /// duration, which is all these tests assert on.
    @discardableResult
    private func makeSource(_ name: String, bytes: Int = 2048) throws -> URL {
        let url = sourceDir.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// Drops a file straight into Documents/Music, bypassing the importer —
    /// stands in for AirDrop / the Files app / a previous install.
    @discardableResult
    private func makeOutOfBandFile(_ name: String, bytes: Int = 2048) throws -> URL {
        let url = musicDir.appendingPathComponent(name)
        try Data(repeating: 0x42, count: bytes).write(to: url)
        created.append(url)
        return url
    }

    /// A store whose catalog has finished loading, plus its starting track count.
    private func makeReadyStore() async -> (LibraryStore, Int) {
        let store = LibraryStore()
        await store.ensureLibraryReady()
        return (store, store.tracks.count)
    }

    private func trackedURL(_ name: String) -> URL {
        let url = musicDir.appendingPathComponent(name)
        created.append(url)
        return url
    }

    // MARK: - Incremental import

    func test_addingOneSongDoesNotReindexTheWholeLibrary() async throws {
        let (store, baseline) = await makeReadyStore()

        let first = try makeSource("import-a-\(UUID().uuidString).mp3")
        _ = trackedURL(first.lastPathComponent)
        await store.importURLs([first])
        XCTAssertEqual(store.tracks.count, baseline + 1, "first import should add exactly one track")

        // The probe: a file that appears in Music/ without going through the
        // importer. A full folder rescan would sweep it in; an incremental
        // index of just-imported files cannot see it.
        try makeOutOfBandFile("out-of-band-\(UUID().uuidString).mp3")

        let second = try makeSource("import-b-\(UUID().uuidString).mp3")
        _ = trackedURL(second.lastPathComponent)
        await store.importURLs([second])

        XCTAssertEqual(
            store.tracks.count, baseline + 2,
            "importing one song must index that song only — the out-of-band file proves a full rescan ran"
        )
    }

    func test_rescanStillPicksUpFilesAddedOutOfBand() async throws {
        let store = LibraryStore()
        await store.ensureLibraryReady()
        // Reconcile with the folder first: rescan prunes catalog entries whose
        // files are gone, so a baseline taken before that would move under us.
        await store.rescan()
        let baseline = store.tracks.count

        let name = "out-of-band-\(UUID().uuidString).mp3"
        try makeOutOfBandFile(name)

        await store.rescan()

        XCTAssertEqual(store.tracks.count, baseline + 1)
        XCTAssertTrue(
            store.tracks.contains { $0.relativePath?.hasSuffix(name) == true },
            "explicit Rescan is the path that reconciles the catalog with the folder"
        )
    }

    func test_importPreservesIdentityOfTracksAlreadyInTheCatalog() async throws {
        let (store, _) = await makeReadyStore()

        let first = try makeSource("identity-a-\(UUID().uuidString).mp3")
        let firstURL = trackedURL(first.lastPathComponent)
        await store.importURLs([first])
        let existingID = try XCTUnwrap(
            store.tracks.first { $0.relativePath?.hasSuffix(firstURL.lastPathComponent) == true }?.id
        )

        let second = try makeSource("identity-b-\(UUID().uuidString).mp3")
        _ = trackedURL(second.lastPathComponent)
        await store.importURLs([second])

        let afterID = store.tracks.first {
            $0.relativePath?.hasSuffix(firstURL.lastPathComponent) == true
        }?.id
        XCTAssertEqual(afterID, existingID, "now-playing / queue / playlist identity must survive an import")
    }

    // MARK: - Duplicate protection

    func test_reimportingTheSameFileAddsNothingAndCopiesNothing() async throws {
        let (store, baseline) = await makeReadyStore()

        let name = "dupe-\(UUID().uuidString).mp3"
        let source = try makeSource(name)
        let dest = trackedURL(name)

        await store.importURLs([source])
        XCTAssertEqual(store.tracks.count, baseline + 1)

        await store.importURLs([source])

        XCTAssertEqual(store.tracks.count, baseline + 1, "re-picking the same file must not add a second track")

        // The old failure mode: uniqueDestName always hands back a free name,
        // so the copy ran unconditionally and produced "<stem> 2.mp3".
        let stem = (name as NSString).deletingPathExtension
        let sibling = musicDir.appendingPathComponent("\(stem) 2.mp3")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sibling.path),
            "re-import copied the file again as \(sibling.lastPathComponent)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
    }

    func test_sameNameDifferentBytesKeepsBothFiles() async throws {
        let (store, baseline) = await makeReadyStore()

        let name = "collision-\(UUID().uuidString).mp3"
        let original = try makeSource(name, bytes: 2048)
        _ = trackedURL(name)
        await store.importURLs([original])
        XCTAssertEqual(store.tracks.count, baseline + 1)

        // Different song, same filename — a real collision, not a re-pick.
        let otherDir = sourceDir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        let collision = otherDir.appendingPathComponent(name)
        try Data(repeating: 0x43, count: 4096).write(to: collision)

        let stem = (name as NSString).deletingPathExtension
        _ = trackedURL("\(stem) 2.mp3")
        await store.importURLs([collision])

        XCTAssertEqual(store.tracks.count, baseline + 2, "a genuine collision must keep both songs")
    }
}

#endif
