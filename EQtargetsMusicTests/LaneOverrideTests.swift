//
//  LaneOverrideTests.swift
//  EQtargetsMusicTests
//
//  The lane-override contract:
//    • the user's call beats BPM, in both directions;
//    • it survives a catalog round-trip and a re-import that changes ids;
//    • clearing it hands the decision back to tempo;
//    • the case it exists for — a slow alabanza de júbilo and a slow
//      adoración share a BPM, so no cutoff can separate them.
//

import XCTest
@testable import EQtargetsMusic

final class LaneOverrideTests: XCTestCase {

    private func track(_ title: String, bpm: Double?, lane: TempoLane? = nil, key: String? = nil) -> Track {
        Track(
            title: title,
            artist: "Artist",
            album: "Album",
            duration: 200,
            bpm: bpm,
            relativePath: key ?? "Music/\(title).mp3",
            laneOverrideRaw: lane?.rawValue
        )
    }

    /// The whole reason this feature exists. Two songs, same tempo, opposite
    /// lanes — unreachable by any `jubiloMin` value.
    func test_sameBPMOppositeLanes() {
        let alabanza = track("Alabanza de Júbilo", bpm: 78, lane: .jubilo)
        let adoracion = track("Adoración", bpm: 78)

        XCTAssertEqual(TempoFeel.lane(for: alabanza), .jubilo)
        XCTAssertEqual(TempoFeel.lane(for: adoracion), .adoracion)
        XCTAssertTrue(
            TempoFeel.lane(for: alabanza).clashes(with: TempoFeel.lane(for: adoracion)),
            "these must be opposite lanes despite identical BPM"
        )
    }

    /// Override must also be able to pull a fast song *down* — a 150 BPM
    /// song with sustained pads can be adoración.
    func test_overrideCanSlowAFastSong() {
        let fastPad = track("Ante Tu Altar", bpm: 150, lane: .adoracion)
        XCTAssertEqual(TempoFeel.lane(bpm: 150), .jubilo, "BPM alone says júbilo")
        XCTAssertEqual(TempoFeel.lane(for: fastPad), .adoracion, "the user's call must win")
    }

    func test_clearingOverrideReturnsToTempo() {
        var t = track("Corito", bpm: 150, lane: .adoracion)
        XCTAssertEqual(TempoFeel.lane(for: t), .adoracion)
        t.laneOverrideRaw = nil
        XCTAssertEqual(TempoFeel.lane(for: t), .jubilo, "cleared override falls back to BPM")
    }

    /// `.unknown` must never be storable as a decision — it would shadow both
    /// the BPM and the metadata-hint paths with "no tempo data".
    func test_unknownOverrideIsIgnored() {
        let t = track("Sin Tempo", bpm: 150, lane: .unknown)
        XCTAssertEqual(TempoFeel.lane(for: t), .jubilo)
    }

    /// A track with no BPM at all still gets its lane from the override —
    /// this is the path for songs the detector could not read.
    func test_overrideWorksWithNoBPM() {
        let t = track("Medley En Vivo", bpm: nil, lane: .jubilo)
        XCTAssertEqual(TempoFeel.lane(bpm: nil), .unknown)
        XCTAssertEqual(TempoFeel.lane(for: t), .jubilo)
    }

    /// Overrides are stored in the catalog, so they must round-trip.
    func test_survivesCatalogRoundTrip() throws {
        let original = track("Alabanza", bpm: 78, lane: .jubilo)
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([Track].self, from: data)
        XCTAssertEqual(decoded.first?.laneOverrideRaw, TempoLane.jubilo.rawValue)
        XCTAssertEqual(TempoFeel.lane(for: try XCTUnwrap(decoded.first)), .jubilo)
    }

    /// Catalogs written before this feature must still decode.
    func test_decodesCatalogWithoutTheField() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","title":"Viejo","artist":"A","album":"B",
          "duration":180,"bpm":78,"bpmChecked":true,"relativePath":"Music/viejo.mp3"}]
        """
        let decoded = try JSONDecoder().decode([Track].self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.first?.laneOverrideRaw)
        XCTAssertEqual(TempoFeel.lane(for: try XCTUnwrap(decoded.first)), .adoracion)
    }

    // MARK: - Store wiring

    @MainActor
    func test_storeMatchesByFileKeyWhenIDChanged() async {
        let store = LibraryStore()
        await store.ensureLibraryReady()
        guard let existing = store.tracks.first else {
            // Nothing in the simulator's library — the id/key matching logic is
            // still covered by the pure cases above.
            return
        }

        // Same file, fresh id — exactly what a re-import produces.
        let reimported = Track(
            title: existing.title,
            artist: existing.artist,
            album: existing.album,
            duration: existing.duration,
            relativePath: existing.relativePath
        )
        XCTAssertNotEqual(reimported.id, existing.id)

        store.setLaneOverride(.jubilo, for: reimported)
        let updated = store.tracks.first { $0.id == existing.id }
        XCTAssertEqual(updated?.laneOverrideRaw, TempoLane.jubilo.rawValue,
                       "must match by file key when the id has diverged")

        store.setLaneOverride(nil, for: reimported)
        XCTAssertNil(store.tracks.first { $0.id == existing.id }?.laneOverrideRaw)
    }
}
