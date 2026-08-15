//
//  LimiterPresetStoreTests.swift
//  EQtargetsMusicTests
//
//  Saving, overwriting, renaming and deleting your own limiter presets.
//

import XCTest
@testable import EQtargetsMusic

@MainActor
final class LimiterPresetStoreTests: XCTestCase {

    private let userLimitersKey = "eqtargets.userLimiterPresets.v1"
    private let knownDevicesKey = "eqtargets.knownAudioDevices.v1"

    override func setUp() {
        super.setUp()
        clearDefaults()
    }

    override func tearDown() {
        clearDefaults()
        super.tearDown()
    }

    private func clearDefaults() {
        for key in [userLimitersKey, knownDevicesKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Built-ins

    func test_store_shipsEveryGenrePresetAsABuiltIn() {
        let store = EQPresetStore()
        XCTAssertEqual(store.builtInLimiterPresets.count, LimiterGenre.allCases.count)
        for genre in LimiterGenre.allCases {
            XCTAssertNotNil(store.limiterPreset(named: genre.title), "missing \(genre.title)")
        }
        XCTAssertTrue(store.userLimiterPresets.isEmpty)
    }

    func test_builtIns_areRebuiltFromCodeNotPersisted() throws {
        // Tuning a genre in a future release must reach existing installs, so
        // built-ins are never written to disk.
        let store = EQPresetStore()
        store.saveLimiterPreset(name: "Mine", state: LimiterGenre.rock.state)

        let raw = try XCTUnwrap(UserDefaults.standard.data(forKey: userLimitersKey))
        let persisted = try JSONDecoder().decode([LimiterPreset].self, from: raw)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.name, "Mine")
    }

    // MARK: - Saving

    func test_savingAPreset_storesItEnabledAndSelectsIt() {
        let store = EQPresetStore()
        var state = LimiterGenre.hipHop.state
        state.isEnabled = false     // user saved while toggled off
        state.thresholdDB = -11

        let saved = store.saveLimiterPreset(name: "  Night Bus  ", state: state)

        XCTAssertEqual(saved, "Night Bus", "name should be trimmed")
        XCTAssertEqual(store.selectedLimiterName, "Night Bus")
        let stored = store.limiterPreset(named: "Night Bus")
        XCTAssertNotNil(stored)
        XCTAssertTrue(stored?.state.isEnabled ?? false, "recalling a preset must actually do something")
        XCTAssertEqual(stored?.state.thresholdDB ?? 0, -11, accuracy: 1e-9)
    }

    func test_savingOverAUserPreset_overwritesRatherThanDuplicating() {
        let store = EQPresetStore()
        store.saveLimiterPreset(name: "Mine", state: LimiterGenre.rock.state)
        store.saveLimiterPreset(name: "Mine", state: LimiterGenre.edm.state)

        XCTAssertEqual(store.userLimiterPresets.count, 1)
        XCTAssertTrue(
            store.limiterPreset(named: "Mine")?.state.matchesParameters(of: LimiterGenre.edm.state) ?? false
        )
    }

    func test_savingUnderABuiltInName_doesNotShadowTheGenrePreset() {
        let store = EQPresetStore()
        let genreName = LimiterGenre.pop.title
        let saved = store.saveLimiterPreset(name: genreName, state: LimiterGenre.edm.state)

        XCTAssertNotEqual(saved, genreName)
        XCTAssertEqual(saved, "\(genreName) (2)")
        // The original genre preset is untouched.
        XCTAssertTrue(
            store.limiterPreset(named: genreName)?.state.matchesParameters(of: LimiterGenre.pop.state) ?? false
        )
    }

    func test_savingAnEmptyName_isRejected() {
        let store = EQPresetStore()
        XCTAssertNil(store.saveLimiterPreset(name: "   ", state: LimiterGenre.pop.state))
        XCTAssertTrue(store.userLimiterPresets.isEmpty)
    }

    func test_userPresets_surviveAStoreReload() {
        let first = EQPresetStore()
        first.saveLimiterPreset(name: "Commute", state: LimiterGenre.podcast.state)

        let second = EQPresetStore()
        XCTAssertNotNil(second.limiterPreset(named: "Commute"))
        XCTAssertEqual(second.userLimiterPresets.count, 1)
    }

    // MARK: - Renaming

    func test_renamingAPreset_followsThroughToItsDeviceBindings() throws {
        let store = EQPresetStore()
        store.saveLimiterPreset(name: "Old", state: LimiterGenre.rock.state)
        let preset = try XCTUnwrap(store.limiterPreset(named: "Old"))
        store.renameLimiterPreset(preset, to: "New")

        XCTAssertNil(store.limiterPreset(named: "Old"))
        XCTAssertNotNil(store.limiterPreset(named: "New"))
        XCTAssertEqual(store.selectedLimiterName, "New")
    }

    func test_renamingOntoAnExistingName_isRefused() throws {
        let store = EQPresetStore()
        store.saveLimiterPreset(name: "A", state: LimiterGenre.rock.state)
        store.saveLimiterPreset(name: "B", state: LimiterGenre.pop.state)

        let a = try XCTUnwrap(store.limiterPreset(named: "A"))
        store.renameLimiterPreset(a, to: "B")

        XCTAssertNotNil(store.limiterPreset(named: "A"))
        XCTAssertEqual(store.userLimiterPresets.count, 2)
    }

    func test_renamingABuiltIn_isRefused() throws {
        let store = EQPresetStore()
        let builtIn = try XCTUnwrap(store.limiterPreset(named: LimiterGenre.edm.title))
        store.renameLimiterPreset(builtIn, to: "Whatever")
        XCTAssertNotNil(store.limiterPreset(named: LimiterGenre.edm.title))
        XCTAssertNil(store.limiterPreset(named: "Whatever"))
    }

    // MARK: - Matching

    func test_presetNameMatching_tracksTheLiveStateAndClearsOnEdit() {
        let store = EQPresetStore()
        let rock = LimiterGenre.rock.state
        XCTAssertEqual(store.limiterPresetName(matching: rock), LimiterGenre.rock.title)

        var edited = rock
        edited.thresholdDB -= 3
        XCTAssertEqual(store.limiterPresetName(matching: edited), "",
                       "an edited state must stop claiming to be a preset")
    }

}
