//
//  ShuffleTests.swift
//  EQtargetsMusicTests
//
//  Banger shuffle (whole-queue ordering) and Smart Tempo Up Next (single pick).
//

import XCTest
@testable import EQtargetsMusic

final class BangerShuffleTests: XCTestCase {

    private func quality(_ q: [Track]) -> (artist: Double, album: Double, clash: Double) {
        var artistAdj = 0, albumAdj = 0, laneClash = 0
        for i in 1 ..< q.count {
            if BangerShuffle.normalized(q[i].artist) == BangerShuffle.normalized(q[i - 1].artist) { artistAdj += 1 }
            if q[i].album == q[i - 1].album, !q[i].album.isEmpty { albumAdj += 1 }
            if TempoFeel.lane(for: q[i - 1]).clashes(with: TempoFeel.lane(for: q[i])) { laneClash += 1 }
        }
        let n = Double(q.count - 1)
        return (Double(artistAdj) / n * 100, Double(albumAdj) / n * 100, Double(laneClash) / n * 100)
    }

    private func meanQuality(trials: Int = 12, missingAlbumFraction: Double = 0)
        -> (artist: Double, album: Double, clash: Double) {
        var a = 0.0, b = 0.0, c = 0.0
        for s in 0 ..< trials {
            let salt = UInt64(1000 + s * 37)
            let lib = Fixtures.library(500, missingAlbumFraction: missingAlbumFraction, seed: salt)
            let q = BangerShuffle.orderedQueue(from: lib, anchor: lib[0], salt: salt)
            let m = quality(q)
            a += m.artist; b += m.album; c += m.clash
        }
        return (a / Double(trials), b / Double(trials), c / Double(trials))
    }

    func testOutputCorrectness() {
        let lib = Fixtures.library(500)
        let anchor = lib[0]
        let q = BangerShuffle.orderedQueue(from: lib, anchor: anchor, salt: 99)
        XCTAssertEqual(q.count, lib.count)
        XCTAssertEqual(Set(q.map(\.id)).count, lib.count, "duplicates or drops")
        XCTAssertEqual(q.first?.id, anchor.id, "anchor must lead")

        let again = BangerShuffle.orderedQueue(from: lib, anchor: anchor, salt: 99)
        XCTAssertEqual(q.map(\.id), again.map(\.id), "not deterministic for equal salt")
        let other = BangerShuffle.orderedQueue(from: lib, anchor: anchor, salt: 100)
        XCTAssertNotEqual(q.map(\.id), other.map(\.id), "salt has no effect")
    }

    func testEdgeShapes() {
        for n in [1, 2, 3] {
            let lib = Fixtures.library(n)
            let out = BangerShuffle.orderedQueue(from: lib, anchor: lib[0], salt: 5)
            XCTAssertEqual(out.count, n)
            XCTAssertEqual(Set(out.map(\.id)).count, n)
        }
        let noBPM = (0 ..< 40).map {
            Track(title: "T\($0)", artist: "A\($0 % 5)", album: "Al\($0 % 3)", duration: 200)
        }
        let out = BangerShuffle.orderedQueue(from: noBPM, anchor: noBPM[0], salt: 3)
        XCTAssertEqual(Set(out.map(\.id)).count, noBPM.count, "BPM-less library lost tracks")
    }

    func testSequencingQuality() {
        let banger = meanQuality()
        XCTAssertLessThan(banger.clash, 2.0, "lane clash regressed to \(banger.clash)%")
        XCTAssertLessThan(banger.artist, 0.5, "artist adjacency regressed to \(banger.artist)%")
        XCTAssertLessThan(banger.album, 2.0, "album adjacency regressed to \(banger.album)%")

        // Must beat a plain shuffle by a wide margin on the metric it exists for.
        var plainClash = 0.0
        for s in 0 ..< 12 {
            let salt = UInt64(1000 + s * 37)
            var lib = Fixtures.library(500, seed: salt)
            var rng = SplitMix64(seed: salt)
            lib.shuffle(using: &rng)
            plainClash += quality(lib).clash
        }
        plainClash /= 12
        XCTAssertLessThan(banger.clash, plainClash / 5,
                          "banger \(banger.clash)% vs plain \(plainClash)%")
    }

    /// Regression: untagged albums were treated as one album.
    func testUntaggedAlbumsDoNotCollide() {
        XCTAssertEqual(BangerShuffle.normalizedAlbum(""), BangerShuffle.unknownAlbum)
        XCTAssertEqual(BangerShuffle.normalizedAlbum("  "), BangerShuffle.unknownAlbum)
        XCTAssertNotEqual(BangerShuffle.normalized(""), BangerShuffle.normalizedAlbum(""),
                          "artist and album sentinels must differ — sharing them was the bug")

        let sparse = meanQuality(trials: 8, missingAlbumFraction: 0.6)
        XCTAssertLessThan(sparse.artist, 0.5)
        XCTAssertLessThan(sparse.clash, 2.0)
    }

    /// Queue building runs on the main actor. Growth must stay ~linear; quadratic
    /// meant an 8-second freeze at 2,000 tracks.
    func testQueueBuildGrowsLinearly() {
        let small = Fixtures.library(500, seed: 1)
        let large = Fixtures.library(2_000, seed: 2)
        let tSmall = Fixtures.bestOf(3) {
            _ = BangerShuffle.orderedQueue(from: small, anchor: small[0], salt: 1)
        }
        let tLarge = Fixtures.bestOf(3) {
            _ = BangerShuffle.orderedQueue(from: large, anchor: large[0], salt: 1)
        }
        let growth = tLarge / max(tSmall, 1e-6)
        XCTAssertLessThan(growth, 8, "4x tracks took \(growth)x time — quadratic is ~16x")
        XCTAssertLessThan(tLarge, 3.0, "2,000-track build took \(tLarge)s")
    }

    func testLargeLibraryCompletes() {
        let huge = Fixtures.library(5_000, seed: 4)
        let out = BangerShuffle.orderedQueue(from: huge, anchor: huge[0], salt: 2)
        XCTAssertEqual(out.count, 5_000)
        XCTAssertEqual(Set(out.map(\.id)).count, 5_000)
    }

    func testHoistedThresholdsMatchLiveLookups() {
        let t = TempoFeel.thresholds
        for track in Fixtures.library(60, seed: 8) {
            XCTAssertEqual(TempoFeel.lane(for: track),
                           TempoFeel.lane(for: track, thresholds: t),
                           "hoisted and live lane lookups disagree")
        }
    }

    // MARK: - Energy arc

    private func arcProfile(trials: Int = 12, deciles: Int = 10) -> [Double] {
        var sums = [Double](repeating: 0, count: deciles)
        var counts = [Double](repeating: 0, count: deciles)
        for s in 0 ..< trials {
            let salt = UInt64(2000 + s * 53)
            let lib = Fixtures.library(600, seed: salt)
            let q = BangerShuffle.orderedQueue(from: lib, anchor: lib[0], salt: salt)
            for d in 0 ..< deciles {
                for t in q[(d * q.count / deciles) ..< ((d + 1) * q.count / deciles)] {
                    if let b = t.bpm { sums[d] += b; counts[d] += 1 }
                }
            }
        }
        return (0 ..< deciles).map { sums[$0] / max(counts[$0], 1) }
    }

    func testEnergyArcRisesThenFalls() {
        let profile = arcProfile()
        let peak = profile.max()!
        let peakIdx = profile.firstIndex(of: peak)!
        XCTAssertTrue((2 ... 7).contains(peakIdx), "arc peaks at decile \(peakIdx + 1)")
        XCTAssertGreaterThan(peak - profile[0], 8, "arc barely rises")
        XCTAssertGreaterThan(peak - profile[profile.count - 1], 8, "arc barely falls")
    }

    /// Libraries that cannot support an arc must stay neutral, not invent one.
    func testArcStaysNeutralWithoutTempoSpread() {
        let oneLane = (0 ..< 80).map {
            Track(title: "T\($0)", artist: "A\($0 % 9)", album: "Al\($0 % 5)",
                  duration: 200, bpm: 128 + Double($0 % 3))
        }
        XCTAssertEqual(BangerShuffle.orderedQueue(from: oneLane, anchor: oneLane[0], salt: 4).count,
                       oneLane.count)
        let noTempo = (0 ..< 40).map {
            Track(title: "T\($0)", artist: "A\($0 % 6)", album: "", duration: 200)
        }
        XCTAssertEqual(BangerShuffle.orderedQueue(from: noTempo, anchor: noTempo[0], salt: 6).count,
                       noTempo.count)
    }
}

@MainActor
final class SmartShuffleSelectorTests: XCTestCase {

    func testSelectionCorrectness() {
        let lib = Fixtures.library(300)
        let current = lib[0]
        var exclude: Set<UUID> = [current.id]
        var picks: [UUID] = []
        for i in 0 ..< 25 {
            guard let pick = SmartShuffleSelector.selectNext(
                current: current, library: lib, excludeIDs: exclude, salt: UInt64(100 + i)
            ) else { return XCTFail("nil pick at step \(i)") }
            XCTAssertFalse(exclude.contains(pick.id), "returned an excluded track")
            picks.append(pick.id)
            exclude.insert(pick.id)
        }
        XCTAssertEqual(Set(picks).count, 25, "duplicate picks despite exclusion")

        let a = SmartShuffleSelector.selectNext(current: current, library: lib,
                                                excludeIDs: [current.id], salt: 77)
        let b = SmartShuffleSelector.selectNext(current: current, library: lib,
                                                excludeIDs: [current.id], salt: 77)
        XCTAssertEqual(a?.id, b?.id, "not deterministic for equal salt")
    }

    func testEdgeShapes() {
        let lib = Fixtures.library(300)
        XCTAssertNil(SmartShuffleSelector.selectNext(
            current: lib[0], library: [lib[0]], excludeIDs: []),
            "single-track library should yield nil")

        let noBPM = (0 ..< 30).map {
            Track(title: "T\($0)", artist: "A\($0 % 4)", album: "", duration: 200)
        }
        XCTAssertNotNil(SmartShuffleSelector.selectNext(
            current: noBPM[0], library: noBPM, excludeIDs: [noBPM[0].id]),
            "BPM-less library should still pick")
    }

    private func laneMatchRate(_ library: [Track], trials: Int = 40) -> Double {
        var matches = 0, total = 0
        for i in 0 ..< trials {
            let cur = library[i % library.count]
            guard let pick = SmartShuffleSelector.selectNext(
                current: cur, library: library, excludeIDs: [cur.id], salt: UInt64(500 + i)
            ) else { continue }
            let a = TempoFeel.lane(for: cur), b = TempoFeel.lane(for: pick)
            guard a != .unknown, b != .unknown else { continue }
            total += 1
            if a == b || a.neighbors.contains(b) { matches += 1 }
        }
        return total == 0 ? 0 : Double(matches) / Double(total) * 100
    }

    func testPicksStayInTempoLane() {
        XCTAssertGreaterThan(laneMatchRate(Fixtures.library(300)), 85)
    }

    /// Regression: both untagged-album guards here tested for a string
    /// `normalized()` could never return, so they never fired.
    func testSparseAlbumLibraryStillBehaves() {
        let sparse = Fixtures.library(300, missingAlbumFraction: 0.7, seed: 9)
        var exclude: Set<UUID> = [sparse[0].id]
        var picks: Set<UUID> = []
        for i in 0 ..< 20 {
            guard let p = SmartShuffleSelector.selectNext(
                current: sparse[0], library: sparse, excludeIDs: exclude, salt: UInt64(31 + i)
            ) else { return XCTFail("nil pick at \(i)") }
            picks.insert(p.id)
            exclude.insert(p.id)
        }
        XCTAssertEqual(picks.count, 20)
        XCTAssertGreaterThan(laneMatchRate(sparse), 85)
    }
}
