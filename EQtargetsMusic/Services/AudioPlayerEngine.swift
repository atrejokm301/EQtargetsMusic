//
//  AudioPlayerEngine.swift
//  EQtargetsMusic
//
//  Dual-deck playback: each deck has its own Target + Fine-Tune PEQ.
//  Crossfade only moves deck mixer volumes (equal-power). Graph is built once.
//

import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit
import QuartzCore
import os

/// Device Console / Console.app: subsystem `com.eqtargets.music`
private let playerLog = Logger(subsystem: "com.eqtargets.music", category: "Player")

// MARK: - Streaming convert cursor

private final class StreamingCursor {
    var pos: AVAudioFramePosition
    init(_ pos: AVAudioFramePosition) { self.pos = pos }
}

// MARK: - Modes / settings

enum RepeatMode: String, CaseIterable, Identifiable, Codable {
    case off, all, one
    var id: String { rawValue }
    var iconName: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }
}

enum ShuffleMode: String, CaseIterable, Identifiable, Codable {
    case off, standard, banger
    var id: String { rawValue }
    var iconName: String {
        switch self {
        case .off, .standard: return "shuffle"
        case .banger: return "bolt.heart.fill"
        }
    }
}

// CrossfadeSettings / CrossfadeMath → CrossfadeEngine.swift
// BangerShuffle / SplitMix64 → BangerShuffle.swift

// MARK: - Playback deck (independent PEQ chain)

/// One fully independent deck: Player → Target PEQ → Fine-Tune PEQ → deck mixer.
final class PlaybackDeck {
    let player = AVAudioPlayerNode()
    let targetEQ: AVAudioUnitEQ
    let fineEQ: AVAudioUnitEQ
    let mixer = AVAudioMixerNode()

    var file: AVAudioFile?
    var track: Track?
    var playbackAnchorSeconds: TimeInterval = 0
    var fileSampleTimeBase: AVAudioFramePosition = 0
    var streamFeedGeneration: UInt64 = 0
    var duration: TimeInterval = 0
    /// After silence analysis: start of useful audio (file timeline).
    var playStartSeconds: TimeInterval = 0
    /// After silence analysis: end of useful audio (file timeline). Crossfade arms here.
    var playEndSeconds: TimeInterval = 0

    init(bandCount: Int = EQLayerState.bandCount) {
        targetEQ = AVAudioUnitEQ(numberOfBands: bandCount)
        fineEQ = AVAudioUnitEQ(numberOfBands: bandCount)
    }

    func attach(to engine: AVAudioEngine) {
        engine.attach(player)
        engine.attach(targetEQ)
        engine.attach(fineEQ)
        engine.attach(mixer)
    }

    func connect(engine: AVAudioEngine, format: AVAudioFormat) {
        engine.connect(player, to: targetEQ, format: format)
        engine.connect(targetEQ, to: fineEQ, format: format)
        engine.connect(fineEQ, to: mixer, format: format)
        engine.connect(mixer, to: engine.mainMixerNode, format: format)
    }

    func disconnect(engine: AVAudioEngine) {
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(targetEQ)
        engine.disconnectNodeOutput(fineEQ)
        engine.disconnectNodeOutput(mixer)
    }

    func silenceAndStop() {
        player.stop()
        player.reset()
        mixer.outputVolume = 0
        file = nil
        track = nil
        duration = 0
        playStartSeconds = 0
        playEndSeconds = 0
        playbackAnchorSeconds = 0
        fileSampleTimeBase = 0
        streamFeedGeneration &+= 1
    }

    /// Effective end for natural crossfade (silence-trimmed when available).
    var effectiveEndSeconds: TimeInterval {
        if playEndSeconds > playStartSeconds { return playEndSeconds }
        return duration
    }
}

// MARK: - Engine

@MainActor
final class AudioPlayerEngine: ObservableObject {
    @Published var dual: DualEQState = .flat {
        didSet {
            applyEQ()
            schedulePersistEQ()
        }
    }

    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    /// Not @Published — progress ticks must not rebuild library lists.
    private(set) var currentTime: TimeInterval = 0
    let progressSubject = PassthroughSubject<TimeInterval, Never>()
    @Published private(set) var duration: TimeInterval = 0
    @Published var queue: [Track] = []
    @Published var queueIndex: Int = 0
    @Published var toast: String?
    @Published private(set) var libraryMetadataEpoch: UInt64 = 0
    @Published var repeatMode: RepeatMode = .off {
        didSet {
            guard oldValue != repeatMode else { return }
            UserDefaults.standard.set(repeatMode.rawValue, forKey: Self.repeatDefaultsKey)
        }
    }
    @Published var shuffleMode: ShuffleMode = .off {
        didSet {
            guard oldValue != shuffleMode else { return }
            UserDefaults.standard.set(shuffleMode.rawValue, forKey: Self.shuffleDefaultsKey)
        }
    }
    @Published var crossfade: CrossfadeSettings = CrossfadeSettings() {
        didSet {
            schedulePersistCrossfade()
            // Changing duration mid-session: cancel in-flight fade so state stays consistent.
            if isTransitioning {
                cancelTransition(hardStopOutgoing: false)
            }
            // Skip-silence on/off invalidates cached trims (v2 analyzer).
            if oldValue.skipSilence != crossfade.skipSilence {
                silenceTrimCache.removeAll(keepingCapacity: true)
                // Re-arm natural fade window against the new playable end.
                if isPlaying, !isTransitioning {
                    armCrossfadeWatch()
                }
            }
        }
    }

    /// When non-nil, playback pauses at this wall-clock time (sleep timer).
    @Published private(set) var sleepTimerEndsAt: Date?
    /// Minutes chosen for the active sleep timer (nil when off).
    @Published private(set) var sleepTimerMinutes: Int?
    /// Human-readable remaining for chrome (e.g. "12:34" or nil when off).
    @Published private(set) var sleepTimerRemainingLabel: String?

    private var originalQueue: [Track] = []
    /// True while a dual-deck crossfade is in progress (UI may disable queue edits).
    @Published private(set) var isTransitioning = false
    private var isAdvancing = false
    /// Fresh entropy each time a shuffle order is built (prevents identical playlists).
    private var shuffleSalt: UInt64 = UInt64.random(in: 1 ... UInt64.max)
    /// IDs from the previous Banger lap — mild avoid penalty on wrap reshuffle.
    private var bangerRecentIDs: Set<UUID> = []

    private let engine = AVAudioEngine()
    private let deckA = PlaybackDeck()
    private let deckB = PlaybackDeck()
    /// Logical active / inactive — swap after every completed crossfade.
    private var activeDeck: PlaybackDeck
    private var inactiveDeck: PlaybackDeck

    private var progressTimer: Timer?
    private var crossfadeTimer: Timer?
    private var automixTimer: Timer?
    /// Always 48 kHz once the graph is up — stable hardware clock; files resample in.
    private var sampleRate: Double = 48_000
    private var graphFormat: AVAudioFormat?
    private var graphConnected = false

    private let eqDefaultsKey = "eqtargets.dualEQ"
    private let crossfadeDefaultsKey = "eqtargets.crossfadeSettings"
    private static let repeatDefaultsKey = "eqtargets.repeatMode"
    private static let shuffleDefaultsKey = "eqtargets.shuffleMode"
    private static let sessionDefaultsKey = "eqtargets.playbackSession.v1"

    /// Invalidates stale schedule / fade / automix callbacks.
    private var loadGeneration: UInt64 = 0
    private var transitionToken: UInt64 = 0
    private var seekSettleUntilUptime: TimeInterval = 0
    private var securityScopedURLs: Set<URL> = []

    private var eqPersistTask: Task<Void, Never>?
    private var crossfadePersistTask: Task<Void, Never>?
    private var sessionPersistTask: Task<Void, Never>?
    private var sleepTimerTask: Task<Void, Never>?
    private var sleepLabelTimer: Timer?
    /// Avoid restoring twice / overwriting an intentional empty state.
    private var didAttemptSessionRestore = false
    private var cachedNowPlayingArtwork: MPMediaItemArtwork?
    private var cachedArtworkTrackID: UUID?
    /// Bumps when track changes so a late high-res load cannot attach to the wrong song.
    private var nowPlayingArtLoadToken: UInt64 = 0
    private var lastNowPlayingPush: TimeInterval = 0
    /// Foreground UI / crossfade backup tick. Background / LPM use slower intervals
    /// (natural crossfade still fires; fewer main-runloop wakes = less battery).
    private var progressTickInterval: TimeInterval {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 1.15 }
        if UIApplication.shared.applicationState == .background { return 1.0 }
        return 0.75
    }
    private let progressPublishEpsilon: TimeInterval = 0.25

    private var fadingOutFile: AVAudioFile?
    private var consecutiveMissingSkips = 0
    /// Silence-skip results by file key — avoids re-scanning on every Next/Prev.
    private var silenceTrimCache: [String: SilenceTrim] = [:]
    private let silenceTrimCacheCap = 48
    /// Lightweight position write (not full queue JSON) — cuts flash wear / main-thread encode.
    private static let sessionPositionKey = "eqtargets.playbackPosition"
    private var lastPositionPersistUptime: TimeInterval = 0
    private var lastFullSessionSignature: Int = 0

    init() {
        activeDeck = deckA
        inactiveDeck = deckB
        loadEQ()
        loadCrossfade()
        loadPlaybackModes()
        configureSession(forBackground: false)
        buildStableGraph()
        applyEQ()
        setupRemoteCommands()
        setupLifecycleObservers()
    }

    deinit {
        progressTimer?.invalidate()
        automixTimer?.invalidate()
        crossfadeTimer?.invalidate()
        sleepLabelTimer?.invalidate()
        eqPersistTask?.cancel()
        crossfadePersistTask?.cancel()
        sessionPersistTask?.cancel()
        sleepTimerTask?.cancel()
    }

    private func setCurrentTime(_ t: TimeInterval, emitProgress: Bool = true) {
        currentTime = t
        if emitProgress { progressSubject.send(t) }
    }

    // MARK: - Library BPM sync (Banger)

    func syncLibraryMetadata(from libraryTracks: [Track]) {
        guard !libraryTracks.isEmpty else { return }
        func match(_ t: Track) -> Track? {
            if let m = libraryTracks.first(where: { $0.id == t.id }) { return m }
            if let key = t.fileKey,
               let m = libraryTracks.first(where: { $0.fileKey == key }) { return m }
            return libraryTracks.first {
                $0.title == t.title && $0.artist == t.artist && abs($0.duration - t.duration) < 0.5
            }
        }
        var changed = false
        if let cur = currentTrack, let live = match(cur) {
            if cur.bpm != live.bpm || cur.bpmChecked != live.bpmChecked {
                var u = cur
                u.bpm = live.bpm ?? cur.bpm
                u.bpmChecked = live.bpmChecked || cur.bpmChecked || live.hasBPM
                currentTrack = u
                changed = true
            }
        }
        if !queue.isEmpty {
            var q = queue
            for i in q.indices {
                guard let live = match(q[i]) else { continue }
                if q[i].bpm != live.bpm || q[i].bpmChecked != live.bpmChecked {
                    q[i].bpm = live.bpm ?? q[i].bpm
                    q[i].bpmChecked = live.bpmChecked || q[i].bpmChecked
                    changed = true
                }
            }
            if changed { queue = q }
        }
        if changed {
            libraryMetadataEpoch &+= 1
            // Do NOT rebuild Banger order when BPM tags arrive — that was regenerating
            // the same playlist path over and over. Queue metadata is updated in place above.
        }
    }

    // MARK: - Transport

    func play(tracks: [Track], startAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        smartUpNextAutoFillSuppressed = false
        originalQueue = tracks
        if shuffleMode != .off {
            rollShuffleSalt()
            applyShuffleMode(
                tracks: tracks,
                startTrack: tracks[min(max(index, 0), tracks.count - 1)]
            )
        } else {
            queue = tracks
            queueIndex = min(max(index, 0), tracks.count - 1)
        }
        loadAndPlay(queue[queueIndex])
    }

    func play(_ track: Track) {
        smartUpNextAutoFillSuppressed = false
        if let idx = queue.firstIndex(where: { $0.id == track.id }) {
            queueIndex = idx
        } else {
            queue = [track]
            queueIndex = 0
            originalQueue = [track]
        }
        loadAndPlay(track)
    }

    func resume() {
        guard currentTrack != nil else { return }
        do {
            try ensureEngineRunning()
            if !engine.isRunning { try engine.start() }
            activeDeck.player.play()
            if isTransitioning {
                inactiveDeck.player.play()
            }
            isPlaying = true
            startProgressTimer()
            armCrossfadeWatch()
            applySessionPowerMode(background: UIApplication.shared.applicationState == .background)
            updateNowPlaying(force: true)
        } catch {
            showToast("Failed to resume")
        }
    }

    func pause() {
        activeDeck.player.pause()
        inactiveDeck.player.pause()
        isPlaying = false
        stopProgressTimer()
        cancelAutomixTimer()
        if engine.isRunning { engine.pause() }
        flushPersistedSettings()
        persistPlaybackSessionNow()
        updateNowPlaying(force: true)
    }

    // MARK: - Session restore (last song + queue + position)

    /// After library catalog is ready: restore mini-player / Now Playing without autoplay.
    /// Tap Play resumes from the saved position. New plays from the library replace the session.
    func restorePlaybackSession(libraryTracks: [Track]) {
        guard !didAttemptSessionRestore else { return }
        didAttemptSessionRestore = true
        guard currentTrack == nil else { return }
        guard !libraryTracks.isEmpty else { return }
        guard let snap = Self.loadPlaybackSessionSnapshot() else { return }
        guard !snap.queue.isEmpty else { return }

        func resolve(_ ref: PlaybackSessionSnapshot.TrackRef) -> Track? {
            if let t = libraryTracks.first(where: { $0.id == ref.id }) { return t }
            if let key = ref.fileKey, !key.isEmpty,
               let t = libraryTracks.first(where: { $0.fileKey == key }) { return t }
            return libraryTracks.first {
                $0.title == ref.title
                    && $0.artist == ref.artist
                    && abs($0.duration - ref.duration) < 1.5
            }
        }

        let restoredQueue = snap.queue.compactMap(resolve)
        guard !restoredQueue.isEmpty else {
            Self.clearPlaybackSessionSnapshot()
            return
        }

        // Map saved index to restored list (drop missing files).
        var index = min(max(snap.queueIndex, 0), snap.queue.count - 1)
        // Prefer matching the intended current ref if possible.
        if snap.queue.indices.contains(index),
           let want = resolve(snap.queue[index]),
           let mapped = restoredQueue.firstIndex(where: { $0.id == want.id }) {
            index = mapped
        } else {
            index = min(index, restoredQueue.count - 1)
        }

        let original = snap.originalQueue.compactMap(resolve)
        originalQueue = original.isEmpty ? restoredQueue : original
        queue = restoredQueue
        queueIndex = index

        let track = restoredQueue[index]
        guard track.resolvedURL() != nil else {
            // Try later items.
            if let playableIdx = restoredQueue.indices.first(where: { restoredQueue[$0].resolvedURL() != nil }) {
                queueIndex = playableIdx
                loadAndPlay(restoredQueue[playableIdx], autoSkipMissing: true, autoPlay: false)
            } else {
                Self.clearPlaybackSessionSnapshot()
            }
            return
        }

        loadAndPlay(track, autoSkipMissing: false, autoPlay: false)
        // Prefer lightweight position sidecar if newer than snapshot body.
        let sidecar = UserDefaults.standard.double(forKey: Self.sessionPositionKey)
        let rawPos = sidecar > 0.5 ? sidecar : snap.positionSeconds
        let pos = min(max(rawPos, 0), max(duration - 0.25, 0))
        if pos > 0.5 {
            seek(to: pos)
            // seek may leave paused if wasPlaying was false
            if isPlaying { pause() }
        }
        playerLog.info(
            "sessionRestore: “\(track.title, privacy: .public)” pos=\(pos, format: .fixed(precision: 1))s queue=\(restoredQueue.count) idx=\(self.queueIndex)"
        )
    }

    func togglePlayPause() {
        if isPlaying { pause() }
        else if currentTrack != nil { resume() }
        else if !queue.isEmpty { loadAndPlay(queue[0]) }
    }

    func skipForward() {
        guard !queue.isEmpty else {
            playerLog.warning("skipForward: empty queue")
            return
        }

        playerLog.info("skipForward: idx=\(self.queueIndex) transitioning=\(self.isTransitioning) crossfade=\(self.crossfade.durationSeconds)s shuffle=\(self.shuffleMode.rawValue, privacy: .public)")

        // Abort any in-flight fade so Next always advances (stuck transition was a real failure mode).
        if isTransitioning {
            cancelTransition(hardStopOutgoing: true)
        }
        activeDeck.mixer.outputVolume = 1
        inactiveDeck.mixer.outputVolume = 0
        if inactiveDeck.player.isPlaying {
            inactiveDeck.player.stop()
            inactiveDeck.player.reset()
        }

        if queueIndex + 1 < queue.count {
            queueIndex += 1
        } else if shuffleMode != .off || repeatMode == .all {
            // End of queue: new shuffle order for the next lap, then play first after current.
            playerLog.info("skipForward: end of queue → reshuffle")
            reshuffleQueueForNewCycle()
            queueIndex = queue.count > 1 ? 1 : 0
        } else {
            playerLog.info("skipForward: at end, no wrap")
            return
        }

        let next = queue[queueIndex]
        playerLog.info("skipForward: → \(next.title, privacy: .public) [\(self.queueIndex)/\(self.queue.count)]")
        performTrackTransition(to: next)
    }

    func skipBackward() {
        guard !queue.isEmpty else { return }
        if !isTransitioning, currentTime > 3.0 {
            seek(to: 0)
            return
        }
        cancelTransition(hardStopOutgoing: true)
        if queueIndex - 1 >= 0 {
            queueIndex -= 1
            loadAndPlay(queue[queueIndex], autoSkipMissing: true)
        } else if repeatMode == .all {
            queueIndex = queue.count - 1
            loadAndPlay(queue[queueIndex], autoSkipMissing: true)
        } else {
            seek(to: 0)
        }
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: - Sleep timer

    /// Preset durations in minutes (0 = off). UI uses this list.
    static let sleepTimerMinuteChoices: [Int] = [0, 5, 10, 15, 30, 45, 60, 90]

    /// Arm a sleep timer that pauses playback after `minutes`. Pass 0 or nil to cancel.
    func setSleepTimer(minutes: Int?) {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepLabelTimer?.invalidate()
        sleepLabelTimer = nil

        guard let minutes, minutes > 0 else {
            sleepTimerEndsAt = nil
            sleepTimerMinutes = nil
            sleepTimerRemainingLabel = nil
            showToast("Sleep timer off")
            return
        }

        let ends = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEndsAt = ends
        sleepTimerMinutes = minutes
        refreshSleepTimerLabel()
        showToast(minutes >= 60
                  ? String(format: "Sleep in %dh %dm", minutes / 60, minutes % 60)
                  : "Sleep in \(minutes) min")

        // 5s is enough for a mm:ss label and avoids @Published spam every second.
        let labelTimer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refreshSleepTimerLabel() }
        }
        RunLoop.main.add(labelTimer, forMode: .common)
        sleepLabelTimer = labelTimer

        sleepTimerTask = Task { @MainActor [weak self] in
            let nanos = UInt64(minutes) * 60 * 1_000_000_000
            try? await Task.sleep(nanoseconds: nanos)
            guard let self, !Task.isCancelled else { return }
            guard let endsAt = self.sleepTimerEndsAt, endsAt <= Date().addingTimeInterval(1) else { return }
            self.fireSleepTimer()
        }
    }

    /// Pause now and clear the timer (called when deadline hits).
    private func fireSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepLabelTimer?.invalidate()
        sleepLabelTimer = nil
        sleepTimerEndsAt = nil
        sleepTimerMinutes = nil
        sleepTimerRemainingLabel = nil
        if isPlaying {
            pause()
        }
        showToast("Sleep timer — paused")
    }

    private func refreshSleepTimerLabel() {
        guard let ends = sleepTimerEndsAt else {
            sleepTimerRemainingLabel = nil
            return
        }
        let remaining = ends.timeIntervalSinceNow
        if remaining <= 0 {
            fireSleepTimer()
            return
        }
        let total = Int(remaining.rounded(.up))
        let m = total / 60
        let s = total % 60
        sleepTimerRemainingLabel = String(format: "%d:%02d", m, s)
    }

    // MARK: - Queue / Up Next (same `queue` + `queueIndex` source of truth)

    /// Tracks after the current index — actual playback order for crossfade/next.
    var upNext: [Track] {
        guard queueIndex + 1 < queue.count else { return [] }
        return Array(queue.suffix(from: queueIndex + 1))
    }

    /// IDs the user removed from Up Next this session — Smart Tempo must not re-queue them.
    private(set) var smartUpNextBannedIDs: Set<UUID> = []
    /// After user clears/removes Up Next, don't auto-refill until natural advance or they add again.
    private(set) var smartUpNextAutoFillSuppressed = false

    /// Insert immediately after the current track (becomes next for skip/crossfade).
    func playNext(_ track: Track) {
        guard !blockQueueMutationIfFading() else { return }
        smartUpNextAutoFillSuppressed = false
        smartUpNextBannedIDs.remove(track.id)
        if queue.isEmpty {
            play(track)
            showToast("Playing")
            return
        }
        let insertAt = min(queueIndex + 1, queue.count)
        // Avoid accidental double-insert of same id at front
        if insertAt < queue.count, queue[insertAt].id == track.id {
            showToast("Already next")
            return
        }
        queue.insert(track, at: insertAt)
        showToast("Play Next")
        invalidateStagedNextIfNeeded()
    }

    /// Append to end of queue without changing current or immediate next (unless empty).
    func addToQueue(_ track: Track) {
        guard !blockQueueMutationIfFading() else { return }
        smartUpNextAutoFillSuppressed = false
        smartUpNextBannedIDs.remove(track.id)
        if queue.isEmpty {
            play(track)
            showToast("Playing")
            return
        }
        queue.append(track)
        showToast("Added to Queue")
    }

    /// Cancel any fade and start this track now. Remaining queue after the new current is kept when possible.
    func playNow(_ track: Track) {
        if isTransitioning {
            cancelTransition(hardStopOutgoing: true)
            activeDeck.mixer.outputVolume = 1
        }
        var q = queue
        q.removeAll { $0.id == track.id }
        let insertAt = min(max(queueIndex, 0), q.count)
        q.insert(track, at: insertAt)
        queue = q
        queueIndex = insertAt
        if originalQueue.isEmpty { originalQueue = q }
        loadAndPlay(track, autoSkipMissing: true)
    }

    /// Jump to an item in Up Next (index into `upNext`, not full queue).
    func playUpNextItem(at upNextIndex: Int) {
        let absolute = queueIndex + 1 + upNextIndex
        guard absolute < queue.count else { return }
        if isTransitioning {
            cancelTransition(hardStopOutgoing: true)
            activeDeck.mixer.outputVolume = 1
        }
        queueIndex = absolute
        loadAndPlay(queue[absolute], autoSkipMissing: true)
    }

    /// Remove one upcoming item by **stable track id** (not list index — index is stale under SwiftUI swipe).
    func removeUpNext(trackID: UUID) {
        guard !blockQueueMutationIfFading() else { return }
        guard let absolute = queue.firstIndex(where: { $0.id == trackID }) else { return }
        // Never remove the currently playing slot.
        guard absolute > queueIndex else { return }

        let wasImmediateNext = absolute == queueIndex + 1
        queue.remove(at: absolute)

        // User explicitly rejected this track — don't let Smart Tempo put it back.
        smartUpNextBannedIDs.insert(trackID)
        smartUpNextAutoFillSuppressed = true

        if wasImmediateNext {
            // Kill any pre-staged / half-prepared next on the inactive deck.
            purgeStagedTrackIfMatching(trackID)
            if isPlaying, !isTransitioning {
                armCrossfadeWatch()
            }
        }
        showToast("Removed from queue")
    }

    /// Backward-compatible index API (resolves to current upNext snapshot, then removes by id).
    func removeUpNext(at upNextIndex: Int) {
        let items = upNext
        guard items.indices.contains(upNextIndex) else { return }
        removeUpNext(trackID: items[upNextIndex].id)
    }

    func moveUpNext(from source: IndexSet, to destination: Int) {
        guard !blockQueueMutationIfFading() else { return }
        var next = upNext
        guard !next.isEmpty else { return }
        next.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue.prefix(queueIndex + 1)) + next
        // Order changed — clear any deck that no longer matches immediate next.
        invalidateStagedNextIfNeeded()
        if isPlaying, !isTransitioning {
            armCrossfadeWatch()
        }
    }

    /// Drop everything after the current track. Does not stop playback.
    func clearUpNext() {
        if isTransitioning {
            cancelTransition(hardStopOutgoing: true)
            activeDeck.mixer.outputVolume = 1
        }
        guard queueIndex + 1 < queue.count else {
            showToast("Queue empty")
            return
        }
        // Ban everything that was upcoming so Smart Tempo won't instantly rebuild the same list.
        for t in upNext {
            smartUpNextBannedIDs.insert(t.id)
        }
        smartUpNextAutoFillSuppressed = true
        queue = Array(queue.prefix(queueIndex + 1))
        purgeStagedTrackIfMatching(nil) // clear any staged next
        inactiveDeck.silenceAndStop()
        inactiveDeck.mixer.outputVolume = 0
        if isPlaying, !isTransitioning {
            armCrossfadeWatch()
        }
        showToast("Cleared Up Next")
    }

    /// If inactive deck holds a track that is no longer the true next, silence it.
    private func invalidateStagedNextIfNeeded() {
        guard let staged = inactiveDeck.track else { return }
        let nextID = upNext.first?.id
        if nextID != staged.id {
            purgeStagedTrackIfMatching(staged.id)
        }
    }

    /// Stop inactive-deck audio that was prepared for a removed/replaced next track.
    private func purgeStagedTrackIfMatching(_ trackID: UUID?) {
        let stagedID = inactiveDeck.track?.id
        let shouldPurge = trackID == nil || stagedID == trackID
        guard shouldPurge else { return }

        if isTransitioning {
            // Crossfading into a track the user just removed — abort fade, keep current audible.
            cancelTransition(hardStopOutgoing: true)
            activeDeck.mixer.outputVolume = 1
        }
        inactiveDeck.silenceAndStop()
        inactiveDeck.mixer.outputVolume = 0
    }

    @discardableResult
    private func blockQueueMutationIfFading() -> Bool {
        guard isTransitioning else { return false }
        showToast("Wait for crossfade")
        return true
    }

    func cycleShuffleMode() {
        switch shuffleMode {
        case .off:
            shuffleMode = .standard
            rollShuffleSalt()
            rebuildShuffleQueue(announce: true)
        case .standard:
            shuffleMode = .banger
            rollShuffleSalt()
            rebuildShuffleQueue(announce: true)
        case .banger:
            shuffleMode = .off
            if let currentTrack {
                let source = originalQueue.isEmpty ? queue : originalQueue
                queue = source
                queueIndex = queue.firstIndex(where: { $0.id == currentTrack.id }) ?? 0
            }
            showToast("Shuffle Off")
        }
    }

    private func rollShuffleSalt() {
        // Mix time + random so consecutive rebuilds never share a seed.
        let t = UInt64(bitPattern: Int64(Date().timeIntervalSinceReferenceDate * 1_000_000))
        shuffleSalt = shuffleSalt &+ t &+ UInt64.random(in: 1 ... .max)
        if shuffleSalt == 0 { shuffleSalt = 0xC0FFEE }
    }

    private func rebuildShuffleQueue(announce: Bool) {
        let source = originalQueue.isEmpty ? queue : originalQueue
        guard !source.isEmpty else { return }
        let start = currentTrack ?? source[min(queueIndex, max(source.count - 1, 0))]
        if originalQueue.isEmpty { originalQueue = source }
        applyShuffleMode(tracks: source, startTrack: start, announce: announce)
    }

    /// New order after a full pass (repeat all / wrap). Keeps current track at index 0.
    private func reshuffleQueueForNewCycle() {
        let source = originalQueue.isEmpty ? queue : originalQueue
        guard !source.isEmpty else { return }
        let start = currentTrack
            ?? (queue.indices.contains(queueIndex) ? queue[queueIndex] : source[0])
        rollShuffleSalt()
        if originalQueue.isEmpty { originalQueue = source }
        applyShuffleMode(tracks: source, startTrack: start, announce: false)
    }

    private func applyShuffleMode(tracks: [Track], startTrack: Track, announce: Bool = false) {
        switch shuffleMode {
        case .off:
            break
        case .standard:
            var rng = SplitMix64(seed: shuffleSalt ^ 0xA5A5_5A5A_F00D)
            var shuffled = tracks
            shuffled.shuffle(using: &rng)
            pinStartTrack(startTrack, in: &shuffled)
            queue = shuffled
            queueIndex = 0
            if announce { showToast("Shuffle On") }
        case .banger:
            // Prior openers + shared selection history (IDs only) for diversity.
            if !queue.isEmpty {
                bangerRecentIDs = Set(queue.prefix(min(12, queue.count)).map(\.id))
            }
            let historyRecent = Set(ShuffleHistoryStore.recentTrackIDs(limit: 24))
            let avoid = bangerRecentIDs.union(historyRecent)
            var result = BangerShuffle.orderedQueue(
                from: tracks,
                anchor: startTrack,
                salt: shuffleSalt,
                recentIDs: avoid
            )
            pinStartTrack(startTrack, in: &result)
            queue = result
            queueIndex = 0
            // Record only near-term picks (not the whole library) so cooldown stays meaningful.
            let nearTerm = Array(result.prefix(min(21, result.count)))
            ShuffleHistoryStore.recordBangerOrder(nearTerm, skipFirst: true)
            let withBPM = result.filter(\.hasBPM).count
            let preview = result.dropFirst().prefix(3).map(\.title).joined(separator: " | ")
            playerLog.info("banger: n=\(result.count) bpmKnown=\(withBPM) salt=\(self.shuffleSalt) avoid=\(avoid.count) anchor=\(startTrack.title, privacy: .public) next3=\(preview, privacy: .public)")
            if announce {
                if let bpm = startTrack.bpm, startTrack.hasBPM {
                    showToast(String(format: "Banger · ~%.0f BPM · variety on", bpm))
                } else {
                    showToast("Banger · avoiding recent tracks")
                }
            }
        }
    }

    private func pinStartTrack(_ start: Track, in list: inout [Track]) {
        if let idx = list.firstIndex(where: { $0.id == start.id }) {
            list.remove(at: idx)
        } else if let key = start.fileKey,
                  let idx = list.firstIndex(where: { $0.fileKey == key }) {
            list.remove(at: idx)
        }
        list.insert(start, at: 0)
    }
}

// MARK: - Queue advance / crossfade / load (AudioPlayerEngine cont.)

extension AudioPlayerEngine {
    // MARK: - Queue advance / crossfade

    private func advanceToNextTrack() {
        cancelAutomixTimer()
        guard !isTransitioning, !isAdvancing else { return }
        isAdvancing = true
        defer { isAdvancing = false }

        guard !queue.isEmpty else {
            isPlaying = false
            stopProgressTimer()
            return
        }

        if repeatMode == .one, let currentTrack {
            loadAndPlay(currentTrack)
            return
        }

        let nextIndex = queueIndex + 1
        if nextIndex < queue.count {
            queueIndex = nextIndex
            performTrackTransition(to: queue[queueIndex])
        } else if repeatMode == .all || shuffleMode != .off {
            // New lap with a fresh shuffle order when wrapping.
            reshuffleQueueForNewCycle()
            queueIndex = queue.count > 1 ? 1 : 0
            performTrackTransition(to: queue[queueIndex])
        } else {
            isPlaying = false
            stopProgressTimer()
        }
    }

    private func performTrackTransition(to nextTrack: Track) {
        let canCrossfade = crossfade.isEnabled
            && crossfade.duration > 0
            && isPlaying
            && currentTrack != nil
            && engine.isRunning
            && activeDeck.file != nil
            && graphConnected

        playerLog.info("transition: canCrossfade=\(canCrossfade) playing=\(self.isPlaying) engine=\(self.engine.isRunning) graph=\(self.graphConnected) activeFile=\(self.activeDeck.file != nil) → \(nextTrack.title, privacy: .public)")

        if canCrossfade {
            beginCrossfadeV2(to: nextTrack)
        } else {
            loadAndPlay(nextTrack, autoSkipMissing: true)
        }
    }

    /// Dual-deck volume crossfade (v2). EQ chains stay independent; only mixers move.
    private func beginCrossfadeV2(to nextTrack: Track) {
        guard let url = nextTrack.resolvedURL() else {
            loadAndPlay(nextTrack, autoSkipMissing: true)
            return
        }
        retainSecurityAccess(for: url)
        guard let file = try? AVAudioFile(forReading: url) else {
            releaseSecurityAccess(for: url)
            loadAndPlay(nextTrack, autoSkipMissing: true)
            return
        }
        guard let gf = graphFormat, graphConnected else {
            loadAndPlay(nextTrack, autoSkipMissing: true)
            return
        }

        // Graph is fixed at 48 kHz; 44.1 files convert on the incoming deck — no hard reload.
        cancelAutomixTimer()
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil

        transitionToken &+= 1
        let token = transitionToken
        // Bump loadGeneration so outgoing EOF completion cannot advance mid-fade.
        // Per-deck streamFeedGeneration keeps outgoing audio alive through the blend.
        loadGeneration &+= 1
        let gen = loadGeneration
        isTransitioning = true

        let outgoing = activeDeck
        let incoming = inactiveDeck
        fadingOutFile = outgoing.file

        incoming.silenceAndStop()
        incoming.mixer.outputVolume = 0
        outgoing.mixer.outputVolume = 1
        applyEQ(to: incoming)

        let fileFmt = file.processingFormat
        let nextTrim = silenceTrimQuick(for: file, track: nextTrack, url: url)
        let nextStart = nextTrim.introSkip
        let nextEnd = nextTrim.effectiveEnd
        let playableNext = max(0.5, nextEnd - nextStart)
        let nextStartFrame = AVAudioFramePosition((nextStart * fileFmt.sampleRate).rounded(.down))
        let nextEndFrame = AVAudioFramePosition((nextEnd * fileFmt.sampleRate).rounded(.down))
        refineSilenceTrimInBackground(track: nextTrack, url: url, generation: gen)

        let outgoingPlayable = max(outgoing.duration, duration)
        let outgoingPlayed = playerSeconds(on: outgoing) ?? currentTime
        let outgoingRemaining = max(0, outgoingPlayable - outgoingPlayed)

        let outBPM = outgoing.track?.bpm ?? currentTrack?.bpm
        let plan = CrossfadeMath.planFromSettings(
            crossfade,
            outgoingPlayable: outgoingPlayable,
            incomingPlayable: playableNext,
            outgoingRemaining: outgoingRemaining,
            outgoingBPM: outBPM,
            incomingBPM: nextTrack.bpm
        )

        guard plan.isEnabled else {
            playerLog.warning(
                "crossfade: abort plan=\(plan.summary, privacy: .public) notes=\(plan.notes.joined(separator: ","), privacy: .public) → hard load"
            )
            isTransitioning = false
            fadingOutFile = nil
            loadAndPlay(nextTrack, autoSkipMissing: true)
            return
        }

        let fadeDur = plan.effective
        let fadeCurve = plan.curve
        playerLog.info(
            "crossfade: \(plan.summary, privacy: .public) rem=\(outgoingRemaining, format: .fixed(precision: 2))s intro=\(nextStart, format: .fixed(precision: 2))s notes=\(plan.notes.joined(separator: ","), privacy: .public) → \(nextTrack.title, privacy: .public)"
        )

        let onEnded: () -> Void = { [weak self] in
            guard let self, self.loadGeneration == gen, self.transitionToken == token else { return }
            guard !self.isTransitioning else { return }
            self.advanceToNextTrack()
        }

        let scheduled = scheduleOnDeck(
            incoming,
            file: file,
            startFrame: max(0, nextStartFrame),
            endFrame: max(nextStartFrame + 1, nextEndFrame),
            graphFormat: gf,
            generation: gen,
            onComplete: onEnded
        )
        guard scheduled else {
            isTransitioning = false
            fadingOutFile = nil
            loadAndPlay(nextTrack, autoSkipMissing: true)
            return
        }

        incoming.file = file
        incoming.track = nextTrack
        incoming.duration = playableNext
        incoming.playStartSeconds = nextStart
        incoming.playEndSeconds = nextEnd
        incoming.playbackAnchorSeconds = 0
        incoming.fileSampleTimeBase = nextStartFrame

        // UI shows the incoming track immediately; audio still crossfades.
        currentTrack = nextTrack
        duration = playableNext
        setCurrentTime(0)
        updateNowPlaying(force: true)

        do {
            try ensureEngineRunning()
            if !outgoing.player.isPlaying { outgoing.player.play() }
            incoming.player.play()
            isPlaying = true
            startProgressTimer()
        } catch {
            isTransitioning = false
            fadingOutFile = nil
            loadAndPlay(nextTrack, autoSkipMissing: true)
            return
        }

        // Volume-only fade on deck mixers — Target/Fine-Tune EQ untouched.
        let start = CACurrentMediaTime()
        let outMixer = outgoing.mixer
        let inMixer = incoming.mixer
        let outPlayer = outgoing.player
        // ~20 Hz is plenty for volume ramps; avoids 45 Hz main-thread wakeups.
        let tick: TimeInterval = 1.0 / 20.0

        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            // Timer is on the main RunLoop — no nested Task hop.
            MainActor.assumeIsolated {
                guard self.transitionToken == token, self.loadGeneration == gen else {
                    t.invalidate()
                    self.crossfadeTimer = nil
                    return
                }
                let progress = min(max((CACurrentMediaTime() - start) / max(fadeDur, 0.05), 0), 1)
                let g = CrossfadeMath.gains(progress: progress, curve: fadeCurve)
                outMixer.outputVolume = g.out
                inMixer.outputVolume = g.inn

                if progress >= 1 {
                    t.invalidate()
                    self.crossfadeTimer = nil
                    outgoing.streamFeedGeneration &+= 1
                    outPlayer.stop()
                    outPlayer.reset()
                    outMixer.outputVolume = 0
                    inMixer.outputVolume = 1
                    outgoing.file = nil
                    outgoing.track = nil
                    self.fadingOutFile = nil

                    self.activeDeck = incoming
                    self.inactiveDeck = outgoing
                    self.isTransitioning = false

                    let elapsed = min(fadeDur, playableNext)
                    self.currentTrack = nextTrack
                    self.duration = playableNext
                    self.setCurrentTime(elapsed)
                    self.seekSettleUntilUptime = ProcessInfo.processInfo.systemUptime + 0.08
                    self.updateNowPlaying(force: true)
                    self.armCrossfadeWatch()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        crossfadeTimer = timer
    }

    /// Cancel in-flight crossfade. Optionally hard-clear outgoing for skip.
    private func cancelTransition(hardStopOutgoing: Bool) {
        transitionToken &+= 1
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        isTransitioning = false
        isAdvancing = false
        fadingOutFile = nil
        cancelAutomixTimer()

        if hardStopOutgoing {
            inactiveDeck.silenceAndStop()
            inactiveDeck.mixer.outputVolume = 0
        } else {
            if inactiveDeck.mixer.outputVolume < 0.5 {
                inactiveDeck.silenceAndStop()
            }
            activeDeck.mixer.outputVolume = 1
        }
    }

    // MARK: - Seek

    func seek(to time: TimeInterval) {
        guard let file = activeDeck.file, let gf = graphFormat else { return }
        let fileSR = file.processingFormat.sampleRate
        guard fileSR > 0, file.length > 0 else { return }

        cancelTransition(hardStopOutgoing: false)
        // If inactive was audible mid-fade, cancelTransition already handled.

        // Seek within the playable window (0…duration). Map to absolute file time via playStart.
        let maxTime = max(0, duration - 0.05)
        let clamped = max(0, min(time.isFinite ? time : 0, maxTime))
        let absSeconds = activeDeck.playStartSeconds + clamped
        let endAbs = activeDeck.playEndSeconds > activeDeck.playStartSeconds
            ? activeDeck.playEndSeconds
            : Double(file.length) / fileSR
        let maxFrame = max(file.length - 1, 0)
        let frame = min(max(AVAudioFramePosition((absSeconds * fileSR).rounded(.down)), 0), maxFrame)
        let endFrame = min(max(AVAudioFramePosition((endAbs * fileSR).rounded(.down)), frame + 1), file.length)
        let wasPlaying = isPlaying

        loadGeneration &+= 1
        let gen = loadGeneration
        activeDeck.streamFeedGeneration &+= 1
        inactiveDeck.streamFeedGeneration &+= 1
        inactiveDeck.silenceAndStop()
        activeDeck.mixer.outputVolume = 1

        activeDeck.player.stop()
        activeDeck.player.reset()

        activeDeck.fileSampleTimeBase = frame
        activeDeck.playbackAnchorSeconds = clamped
        setCurrentTime(clamped)
        seekSettleUntilUptime = ProcessInfo.processInfo.systemUptime + 0.12

        let ok = scheduleOnDeck(
            activeDeck,
            file: file,
            startFrame: frame,
            endFrame: endFrame,
            graphFormat: gf,
            generation: gen,
            onComplete: { [weak self] in
                guard let self, self.loadGeneration == gen else { return }
                guard ProcessInfo.processInfo.systemUptime >= self.seekSettleUntilUptime else { return }
                guard !self.isTransitioning else { return }
                self.advanceToNextTrack()
            }
        )
        guard ok else {
            showToast("Seek failed")
            return
        }

        if wasPlaying {
            do {
                try ensureEngineRunning()
                activeDeck.player.play()
                isPlaying = true
                startProgressTimer()
                armCrossfadeWatch()
            } catch {
                isPlaying = false
            }
        }
        updateNowPlaying(force: true)
    }

    // MARK: - Load / play

    private func loadAndPlay(_ track: Track, autoSkipMissing: Bool = false, autoPlay: Bool = true) {
        guard let url = track.resolvedURL() else {
            showToast("File missing — re-import “\(track.title)”")
            if autoSkipMissing { skipMissingAndContinue() }
            return
        }

        cancelTransition(hardStopOutgoing: true)
        loadGeneration &+= 1
        let gen = loadGeneration
        cancelAutomixTimer()
        stopProgressTimer()

        retainSecurityAccess(for: url)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            releaseSecurityAccess(for: url)
            showToast("Can't open “\(track.title)”")
            if autoSkipMissing { skipMissingAndContinue() }
            return
        }
        guard gen == loadGeneration else { return }

        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0 else {
            showToast("Unsupported audio format")
            return
        }
        // Graph is always 48 kHz stereo float — never hop 44.1↔48 mid-session
        // (rate thrash + session realign is a common source of thin / “radio” artifacts).
        guard let gf = graphFormat ?? Self.makeGraphFormat() else {
            showToast("Unsupported audio format")
            return
        }

        if !graphConnected || graphFormat == nil {
            hardStopEnginePreserveSession()
            graphFormat = gf
            sampleRate = gf.sampleRate
            connectGraph(format: gf)
            alignSessionSampleRate(to: Self.playbackSampleRate)
        } else {
            // Soft stop decks only — keep graph rate locked.
            activeDeck.player.stop()
            activeDeck.player.reset()
            inactiveDeck.silenceAndStop()
            activeDeck.mixer.outputVolume = 1
            inactiveDeck.mixer.outputVolume = 0
            if engine.isRunning { /* keep running */ }
            else { try? engine.start() }
        }

        sampleRate = gf.sampleRate
        applyEQ()

        // Fast / cached silence trim only — never block play on a full-file scan.
        let trim = silenceTrimQuick(for: file, track: track, url: url)
        let startSec = trim.introSkip
        let endSec = trim.effectiveEnd
        let startFrame = AVAudioFramePosition((startSec * format.sampleRate).rounded(.down))
        let endFrame = AVAudioFramePosition((endSec * format.sampleRate).rounded(.down))

        let playable = max(0.5, endSec - startSec)
        duration = playable
        activeDeck.file = file
        activeDeck.track = track
        activeDeck.duration = playable
        activeDeck.playStartSeconds = startSec
        activeDeck.playEndSeconds = endSec
        activeDeck.playbackAnchorSeconds = 0
        activeDeck.fileSampleTimeBase = startFrame
        setCurrentTime(0)
        seekSettleUntilUptime = 0
        currentTrack = track

        let onEnded: () -> Void = { [weak self] in
            guard let self, self.loadGeneration == gen else { return }
            guard !self.isTransitioning else { return }
            playerLog.warning("trackEnded: EOF without active crossfade — advancing (crossfadeOn=\(self.crossfade.isEnabled))")
            self.advanceToNextTrack()
        }

        let ok = scheduleOnDeck(
            activeDeck,
            file: file,
            startFrame: max(0, startFrame),
            endFrame: max(startFrame + 1, endFrame),
            graphFormat: gf,
            generation: gen,
            onComplete: onEnded
        )
        guard ok else {
            showToast("Can't schedule “\(track.title)”")
            return
        }

        do {
            try ensureEngineRunning()
            consecutiveMissingSkips = 0
            if autoPlay {
                activeDeck.player.play()
                isPlaying = true
                startProgressTimer()
                armCrossfadeWatch()
            } else {
                // Prepared for resume: show mini-player / Now Playing, wait for user Play.
                activeDeck.player.pause()
                isPlaying = false
                stopProgressTimer()
                cancelAutomixTimer()
                if engine.isRunning { engine.pause() }
            }
            // Now Playing metadata after graph is ready (artwork decode shouldn't delay sound).
            updateNowPlaying(force: true)
            schedulePersistPlaybackSession()
            // Refine outro (and intro) off-main; update end marker for natural crossfade.
            refineSilenceTrimInBackground(track: track, url: url, generation: gen)
        } catch {
            isPlaying = false
            showToast("Engine failed to start")
        }
    }

    private func skipMissingAndContinue() {
        consecutiveMissingSkips += 1
        guard !queue.isEmpty, consecutiveMissingSkips <= min(queue.count, 50) else {
            consecutiveMissingSkips = 0
            isPlaying = false
            stopProgressTimer()
            showToast("No playable files left in queue")
            return
        }
        if queueIndex + 1 < queue.count {
            queueIndex += 1
            loadAndPlay(queue[queueIndex], autoSkipMissing: true)
        } else if repeatMode == .all, queue.count > 1 {
            queueIndex = 0
            loadAndPlay(queue[0], autoSkipMissing: true)
        } else {
            consecutiveMissingSkips = 0
            isPlaying = false
            stopProgressTimer()
        }
    }

    // MARK: - Scheduling

    /// Playback clock for session + graph. 48 kHz matches modern iPhone / AirPods
    /// hardware and avoids hopping between rates when the library is mixed 44.1/48.
    /// Battery delta vs 44.1 is small; stability and converter quality matter more for clarity.
    private static let playbackSampleRate: Double = 48_000

    private static func makeGraphFormat() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: playbackSampleRate,
            channels: 2,
            interleaved: false
        )
    }

    /// Keep AVAudioSession preferred rate locked to the graph (48 kHz).
    private func alignSessionSampleRate(to rate: Double = playbackSampleRate) {
        let session = AVAudioSession.sharedInstance()
        let target = Self.playbackSampleRate
        _ = rate // API keeps a parameter for call-site clarity
        do {
            try session.setPreferredSampleRate(target)
            // Re-assert without clobbering buffer preference.
            try session.setActive(true, options: [])
        } catch {
            playerLog.debug("session sampleRate align failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func formatsCompatible(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        abs(a.sampleRate - b.sampleRate) < 1
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
    }

    @discardableResult
    private func scheduleOnDeck(
        _ deck: PlaybackDeck,
        file: AVAudioFile,
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition? = nil,
        graphFormat gf: AVAudioFormat,
        generation: UInt64,
        onComplete: @escaping () -> Void
    ) -> Bool {
        let stopAt = min(endFrame ?? file.length, file.length)
        let remaining = stopAt - startFrame
        guard remaining > 0 else { return false }
        let src = file.processingFormat
        if Self.formatsCompatible(src, gf) {
            deck.player.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: AVAudioFrameCount(remaining),
                at: nil
            ) { [weak self] in
                Task { @MainActor in
                    guard let self, self.loadGeneration == generation else { return }
                    onComplete()
                }
            }
            return true
        }
        return startStreamingConvert(
            deck: deck,
            file: file,
            startFrame: startFrame,
            endFrame: stopAt,
            graphFormat: gf,
            generation: generation,
            onComplete: onComplete
        )
    }

    private func startStreamingConvert(
        deck: PlaybackDeck,
        file: AVAudioFile,
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition,
        graphFormat gf: AVAudioFormat,
        generation: UInt64,
        onComplete: @escaping () -> Void
    ) -> Bool {
        let srcFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: srcFormat, to: gf) else { return false }
        // High-quality SRC for 44.1→48 (and other rates). Cheap vs dual-EQ; avoids thin/muddy convert.
        converter.sampleRateConverterQuality = Int(AVAudioQuality.max.rawValue)
        deck.streamFeedGeneration &+= 1
        let feedGen = deck.streamFeedGeneration
        // ~0.25s source chunks — enough for good SRC without huge buffers.
        let chunkSrc = AVAudioFrameCount(max(srcFormat.sampleRate * 0.25, 1024))
        let cursor = StreamingCursor(startFrame)
        pushStreamingChunk(
            deck: deck,
            file: file,
            converter: converter,
            srcFormat: srcFormat,
            gf: gf,
            chunkSrc: chunkSrc,
            endPos: endFrame,
            cursor: cursor,
            generation: generation,
            feedGen: feedGen,
            primeLeft: 5,
            onComplete: onComplete
        )
        return true
    }

    private func silenceCacheKey(for track: Track, url: URL) -> String {
        if let key = track.fileKey, !key.isEmpty { return key }
        return url.path
    }

    /// Main-thread path: cache hit or fast intro-only analysis (never full-file scan).
    private func silenceTrimQuick(for file: AVAudioFile, track: Track, url: URL) -> SilenceTrim {
        let full = Double(file.length) / max(file.processingFormat.sampleRate, 1)
        guard crossfade.skipSilence else { return .full(duration: full) }
        let key = silenceCacheKey(for: track, url: url)
        if let hit = silenceTrimCache[key] {
            return hit
        }
        let trim = SilenceAnalyzer.analyzeFast(file)
        storeSilenceTrim(key, trim)
        playerLog.info(
            "silenceTrim(fast v2): intro=\(trim.introSkip, format: .fixed(precision: 2))s end=\(trim.effectiveEnd, format: .fixed(precision: 2))s playable=\(trim.playableDuration, format: .fixed(precision: 1))s"
        )
        return trim
    }

    /// Background full head/tail refine; updates cache + live playable end for crossfade arming.
    private func refineSilenceTrimInBackground(track: Track, url: URL, generation: UInt64) {
        guard crossfade.skipSilence else { return }
        // Skip heavy refine when the device is warm or in Low Power — fast intro trim is enough.
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return
        case .fair: break // still allow, but lower priority below
        default: break
        }
        let key = silenceCacheKey(for: track, url: url)
        if let hit = silenceTrimCache[key], hit.isFullyRefined { return }

        let priority: TaskPriority = ProcessInfo.processInfo.thermalState == .fair ? .background : .utility
        Task.detached(priority: priority) { [weak self] in
            guard let trim = SilenceAnalyzer.analyzeURL(url) else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.storeSilenceTrim(key, trim)
                playerLog.info(
                    "silenceTrim(full v2): intro=\(trim.introSkip, format: .fixed(precision: 2))s end=\(trim.effectiveEnd, format: .fixed(precision: 2))s playable=\(trim.playableDuration, format: .fixed(precision: 1))s"
                )
                guard self.crossfade.skipSilence else { return }
                guard self.loadGeneration == generation else { return }

                // Active deck: update outro so natural crossfade fires before dead air.
                // Do not move playStart mid-flight (would desync the scheduled segment).
                if self.activeDeck.track?.id == track.id || self.activeDeck.track?.fileKey == track.fileKey,
                   !self.isTransitioning {
                    let start = self.activeDeck.playStartSeconds
                    let newEnd = max(start + 1, trim.effectiveEnd)
                    if abs(newEnd - self.activeDeck.playEndSeconds) > 0.35 {
                        self.activeDeck.playEndSeconds = newEnd
                        let playable = max(0.5, newEnd - start)
                        self.activeDeck.duration = playable
                        self.duration = playable
                        if self.currentTime > playable {
                            self.setCurrentTime(max(0, playable - 0.05))
                        }
                        self.armCrossfadeWatch()
                    }
                }

                // Incoming deck mid-prep / just crossfaded: keep its end marker honest too.
                if self.inactiveDeck.track?.id == track.id || self.inactiveDeck.track?.fileKey == track.fileKey {
                    let start = self.inactiveDeck.playStartSeconds
                    let newEnd = max(start + 1, trim.effectiveEnd)
                    if abs(newEnd - self.inactiveDeck.playEndSeconds) > 0.35 {
                        self.inactiveDeck.playEndSeconds = newEnd
                        self.inactiveDeck.duration = max(0.5, newEnd - start)
                    }
                }
            }
        }
    }

    private func pushStreamingChunk(
        deck: PlaybackDeck,
        file: AVAudioFile,
        converter: AVAudioConverter,
        srcFormat: AVAudioFormat,
        gf: AVAudioFormat,
        chunkSrc: AVAudioFrameCount,
        endPos: AVAudioFramePosition,
        cursor: StreamingCursor,
        generation: UInt64,
        feedGen: UInt64,
        primeLeft: Int,
        onComplete: @escaping () -> Void
    ) {
        // Only per-deck feed gen gates streaming. Global loadGeneration is for completions
        // (crossfade must bump loadGeneration without silencing the outgoing deck mid-fade).
        guard deck.streamFeedGeneration == feedGen else { return }
        guard cursor.pos < endPos else { return }

        let framesThis = min(AVAudioFrameCount(endPos - cursor.pos), chunkSrc)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: framesThis) else { return }
        do {
            file.framePosition = cursor.pos
            try file.read(into: srcBuffer, frameCount: framesThis)
        } catch { return }
        guard srcBuffer.frameLength > 0 else { return }
        cursor.pos += AVAudioFramePosition(srcBuffer.frameLength)

        let ratio = gf.sampleRate / max(srcFormat.sampleRate, 1)
        let outCap = AVAudioFrameCount(Double(srcBuffer.frameLength) * ratio + 64)
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: gf, frameCapacity: max(outCap, 1)) else { return }

        var error: NSError?
        var fed = false
        let status = converter.convert(to: dstBuffer, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return srcBuffer
        }
        if status == .error || dstBuffer.frameLength == 0 {
            if primeLeft > 0 {
                pushStreamingChunk(
                    deck: deck, file: file, converter: converter, srcFormat: srcFormat, gf: gf,
                    chunkSrc: chunkSrc, endPos: endPos, cursor: cursor, generation: generation,
                    feedGen: feedGen, primeLeft: primeLeft - 1, onComplete: onComplete
                )
            }
            return
        }

        let reachedEnd = cursor.pos >= endPos
        deck.player.scheduleBuffer(dstBuffer, at: nil, options: [], completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard deck.streamFeedGeneration == feedGen else { return }
                if reachedEnd {
                    // Completions still honor loadGeneration so a superseded load cannot advance.
                    guard self.loadGeneration == generation else { return }
                    onComplete()
                } else {
                    self.pushStreamingChunk(
                        deck: deck, file: file, converter: converter, srcFormat: srcFormat, gf: gf,
                        chunkSrc: chunkSrc, endPos: endPos, cursor: cursor, generation: generation,
                        feedGen: feedGen, primeLeft: 0, onComplete: onComplete
                    )
                }
            }
        })

        if primeLeft > 0, !reachedEnd {
            pushStreamingChunk(
                deck: deck, file: file, converter: converter, srcFormat: srcFormat, gf: gf,
                chunkSrc: chunkSrc, endPos: endPos, cursor: cursor, generation: generation,
                feedGen: feedGen, primeLeft: primeLeft - 1, onComplete: onComplete
            )
        }
    }

    // MARK: - EQ

    /// Push DualEQState → both decks (Target then Fine-Tune on each deck).
    /// Called whenever `dual` changes (UI / import / presets / restore).
    func applyEQ() {
        applyEQ(to: deckA)
        applyEQ(to: deckB)
    }

    private func applyEQ(to deck: PlaybackDeck) {
        // Chain: player → targetEQ → fineEQ → mixer (see PlaybackDeck.connect)
        var target = dual.target
        var fine = dual.fineTune
        target.sanitizeForDSP()
        fine.sanitizeForDSP()
        apply(layer: target, unit: deck.targetEQ, globalBypass: dual.isBypassed, label: "Target")
        apply(layer: fine, unit: deck.fineEQ, globalBypass: dual.isBypassed, label: "FineTune")
    }

    /// Map one EQLayerState onto one AVAudioUnitEQ (10 peaking bands + preamp).
    ///
    /// Hardware mapping:
    /// - `frequency` → Hz (clamped below Nyquist)
    /// - `gain` → dB peaking gain
    /// - `q` → `bandwidth` in **octaves** via RBJ conversion (Apple has no Q property)
    /// - layer `preamp` → `globalGain` dB
    private func apply(
        layer: EQLayerState,
        unit: AVAudioUnitEQ,
        globalBypass: Bool,
        label: String
    ) {
        let layerIdle = layer.isFlat
        let unitBypass = globalBypass || layer.isBypassed || layerIdle

        // Always write band parameters even when bypassed so enabling EQ is seamless
        // and we never leave stale F/G/Q from a previous preset on the unit.
        unit.globalGain = unitBypass ? 0 : Float(layer.preamp)

        let nyq = max(sampleRate / 2 - 200, 1_000)
        let count = min(unit.bands.count, layer.bands.count, EQLayerState.bandCount)
        for i in 0 ..< count {
            let b = layer.bands[i]
            let band = unit.bands[i]
            band.filterType = .parametric
            let freq = min(max(b.frequency, EQBand.frequencyRange.lowerBound), min(EQBand.frequencyRange.upperBound, nyq))
            let gain = min(max(b.gain, EQBand.gainRange.lowerBound), EQBand.gainRange.upperBound)
            let q = min(max(b.q, EQBand.qRange.lowerBound), EQBand.qRange.upperBound)
            band.frequency = Float(freq)
            band.gain = Float(gain)
            // AVAudioUnitEQ peaking uses bandwidth (octaves), not Q.
            let bw = EQBand.bandwidthOctaves(fromQ: q)
            band.bandwidth = max(0.05, min(bw, 5.0))
            // Per-band off: disabled in UI, or effectively flat gain (save CPU).
            band.bypass = unitBypass || !b.isEnabled || abs(gain) < 0.001
        }
        // Extra hardware bands (shouldn't exist) stay bypassed.
        if unit.bands.count > count {
            for i in count ..< unit.bands.count {
                unit.bands[i].bypass = true
            }
        }

        unit.bypass = unitBypass

        #if DEBUG
        if !unitBypass {
            playerLog.debug(
                "EQ \(label, privacy: .public): preamp=\(layer.preamp, format: .fixed(precision: 1))dB bands=\(count) sr=\(self.sampleRate, format: .fixed(precision: 0))"
            )
        }
        #endif
    }

    // MARK: - Graph (built once)

    private func buildStableGraph() {
        deckA.attach(to: engine)
        deckB.attach(to: engine)
        _ = engine.outputNode
        // Fixed 48 kHz stereo graph from launch — stable EQ Nyquist + hardware clock.
        if let gf = Self.makeGraphFormat() {
            graphFormat = gf
            sampleRate = gf.sampleRate
            connectGraph(format: gf)
        }
        deckA.mixer.outputVolume = 1
        deckB.mixer.outputVolume = 0
    }

    private func connectGraph(format: AVAudioFormat) {
        if graphConnected {
            deckA.disconnect(engine: engine)
            deckB.disconnect(engine: engine)
        }
        deckA.connect(engine: engine, format: format)
        deckB.connect(engine: engine, format: format)
        graphConnected = true
        engine.prepare()
    }

    private func hardStopEnginePreserveSession() {
        progressTimer?.invalidate()
        progressTimer = nil
        automixTimer?.invalidate()
        automixTimer = nil
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        isPlaying = false
        isTransitioning = false
        deckA.silenceAndStop()
        deckB.silenceAndStop()
        if engine.isRunning { engine.stop() }
        deckA.mixer.outputVolume = 1
        deckB.mixer.outputVolume = 0
        activeDeck = deckA
        inactiveDeck = deckB
    }

    private func ensureEngineRunning() throws {
        if !engine.isRunning { try engine.start() }
    }

    private func configureSession(forBackground: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            // Quality-first when cool (~50ms); thermal/LPM/background use larger buffers.
            let buf = forBackground
                ? PerformanceMemory.preferredBackgroundIOBufferDuration
                : PerformanceMemory.preferredIOBufferDuration
            try session.setPreferredIOBufferDuration(buf)
            // Always prefer 48 kHz (graph + modern device path). Battery cost is minor.
            try session.setPreferredSampleRate(Self.playbackSampleRate)
            try session.setActive(true)
        } catch {
            print("AVAudioSession error: \(error)")
        }
    }

    private func applySessionPowerMode(background: Bool) {
        let session = AVAudioSession.sharedInstance()
        let buf = background
            ? PerformanceMemory.preferredBackgroundIOBufferDuration
            : PerformanceMemory.preferredIOBufferDuration
        try? session.setPreferredIOBufferDuration(buf)
        // Rate stays 48 kHz; only buffer duration moves under heat / LPM / background.
        try? session.setPreferredSampleRate(Self.playbackSampleRate)
    }

    // MARK: - Progress + crossfade arming

    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                // Keep progress + crossfade watchdog running in background so natural
                // end-of-track crossfades still fire with the screen locked.
                self.applySessionPowerMode(background: true)
                self.flushPersistedSettings()
                if self.isPlaying {
                    self.startProgressTimer()
                    self.armCrossfadeWatch()
                    self.updateNowPlaying(force: true)
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.flushPersistedSettings()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.applySessionPowerMode(background: false)
                if self.isPlaying {
                    self.startProgressTimer()
                    self.armCrossfadeWatch()
                    self.updateNowPlaying(force: true)
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleInterruption(note)
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                // Keep session alive; do not rebuild graph.
                try? AVAudioSession.sharedInstance().setActive(true)
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMemoryPressure()
            }
        }
        // LPM / thermal: re-apply preferred IO buffer without rebuilding dual-deck graph.
        NotificationCenter.default.addObserver(
            forName: PerformanceMemory.powerModeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let bg = UIApplication.shared.applicationState == .background
                self.applySessionPowerMode(background: bg)
            }
        }
    }

    /// Drop non-essential RAM under pressure — never stops audio.
    private func handleMemoryPressure() {
        fadingOutFile = nil
        cachedNowPlayingArtwork = nil
        cachedArtworkTrackID = nil
        nowPlayingArtLoadToken &+= 1
        // Keep a few silence trims; drop the rest (cheap to recompute).
        if silenceTrimCache.count > 12 {
            let keep = silenceTrimCache.suffix(12)
            silenceTrimCache = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        PerformanceMemory.purgeCaches(reason: "engine.memoryWarning")
        playerLog.info("memory pressure: purged caches (audio continues)")
    }

    private func storeSilenceTrim(_ key: String, _ trim: SilenceTrim) {
        silenceTrimCache[key] = trim
        if silenceTrimCache.count > silenceTrimCacheCap {
            // Drop oldest-ish keys (Dictionary order is insertion-based in practice).
            let overflow = silenceTrimCache.count - silenceTrimCacheCap
            for k in silenceTrimCache.keys.prefix(overflow) {
                silenceTrimCache.removeValue(forKey: k)
            }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
        switch type {
        case .began:
            pause()
        case .ended:
            let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            if opts.contains(.shouldResume) {
                resume()
            }
        @unknown default:
            break
        }
    }

    private func startProgressTimer() {
        stopProgressTimer()
        // Always tick while playing (including background) — natural crossfade depends on it.
        let timer = Timer(timeInterval: progressTickInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.tickTime() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    /// Live playback position on a deck (seconds), if the audio node is reporting.
    private func playerSeconds(on deck: PlaybackDeck) -> TimeInterval? {
        guard let nodeTime = deck.player.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = deck.player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return nil }
        let played = Double(playerTime.sampleTime) / playerTime.sampleRate
        guard played.isFinite else { return nil }
        let t = deck.playbackAnchorSeconds + max(0, played)
        guard t.isFinite else { return nil }
        return t
    }

    /// Remaining *playable* audio on the active deck (silence-trimmed window).
    private func activeRemainingSeconds() -> TimeInterval {
        let dur = max(duration, activeDeck.duration)
        guard dur > 0 else { return 0 }
        // playerSeconds is relative to playbackAnchor (0 at playable start after intro skip).
        let t = playerSeconds(on: activeDeck) ?? currentTime
        return max(0, dur - t)
    }

    /// Repeating watchdog: start natural crossfade when remaining ≤ planned fade.
    private func armCrossfadeWatch() {
        cancelAutomixTimer()
        guard crossfade.isEnabled, crossfade.duration > 0, isPlaying, duration > 0 else { return }
        if repeatMode == .one { return }

        let token = transitionToken
        let gen = loadGeneration
        let plan = peekCrossfadePlan(remaining: nil)
        let rem = activeRemainingSeconds()
        // Near the end, poll a bit faster so long fades start on time (still battery-aware).
        let nearEnd = plan.effective > 0 && rem <= plan.effective * 2.5 + 2
        let interval: TimeInterval = nearEnd ? 0.20 : 0.40

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.transitionToken == token, self.loadGeneration == gen else { return }
                self.fireCrossfadeIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        automixTimer = timer

        playerLog.debug(
            "crossfadeWatch: armed \(plan.summary, privacy: .public) remaining=\(rem, format: .fixed(precision: 2))s poll=\(interval, format: .fixed(precision: 2))s"
        )
    }

    /// Estimate fade plan for the upcoming natural transition (queue peek).
    private func peekCrossfadePlan(remaining: TimeInterval?) -> CrossfadePlan {
        let next = peekNextTrack()
        return CrossfadeMath.planFromSettings(
            crossfade,
            outgoingPlayable: max(duration, activeDeck.duration),
            incomingPlayable: next?.duration ?? max(duration, 1),
            outgoingRemaining: remaining,
            outgoingBPM: currentTrack?.bpm ?? activeDeck.track?.bpm,
            incomingBPM: next?.bpm
        )
    }

    private func peekPlannedFadeDuration() -> TimeInterval {
        peekCrossfadePlan(remaining: nil).effective
    }

    private func peekNextTrack() -> Track? {
        guard !queue.isEmpty else { return nil }
        if queueIndex + 1 < queue.count { return queue[queueIndex + 1] }
        if repeatMode == .all || shuffleMode != .off {
            let source = originalQueue.isEmpty ? queue : originalQueue
            return source.first { $0.id != (currentTrack?.id ?? queue[queueIndex].id) } ?? source.first
        }
        return nil
    }

    private func cancelAutomixTimer() {
        automixTimer?.invalidate()
        automixTimer = nil
    }

    private func fireCrossfadeIfNeeded() {
        guard crossfade.isEnabled, crossfade.duration > 0 else { return }
        guard isPlaying, !isTransitioning, duration > 0 else { return }
        guard ProcessInfo.processInfo.systemUptime >= seekSettleUntilUptime else { return }
        if repeatMode == .one { return }
        guard !queue.isEmpty else { return }
        let hasNext = queueIndex + 1 < queue.count || repeatMode == .all || shuffleMode != .off
        guard hasNext else { return }

        // Prefer live node time so we don't miss the window when UI time lags.
        if let live = playerSeconds(on: activeDeck) {
            let clamped = min(max(live, 0), max(duration, activeDeck.duration))
            if abs(currentTime - clamped) >= progressPublishEpsilon {
                setCurrentTime(clamped)
            }
        }

        let remaining = activeRemainingSeconds()
        let plan = peekCrossfadePlan(remaining: remaining)
        guard plan.isEnabled else { return }

        // Start when remaining fits the planned fade (+ small schedule lead).
        // Slightly larger lead for long fades so prep doesn't eat the wash.
        let lead: TimeInterval = plan.effective >= 12 ? 0.22 : 0.12
        guard remaining <= plan.effective + lead else { return }

        playerLog.info(
            "crossfadeWatch: FIRE rem=\(remaining, format: .fixed(precision: 2))s plan=\(plan.summary, privacy: .public) → natural advance"
        )
        cancelAutomixTimer()
        advanceToNextTrack()
    }

    private func tickTime() {
        guard isPlaying else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now < seekSettleUntilUptime { return }

        // During crossfade after Next, UI already shows the incoming track — report its time.
        // Otherwise keep the still-active outgoing deck until swap.
        let progressDeck: PlaybackDeck = {
            if isTransitioning,
               let cur = currentTrack,
               inactiveDeck.track?.id == cur.id {
                return inactiveDeck
            }
            return activeDeck
        }()
        if let t = playerSeconds(on: progressDeck) {
            let clamped = min(max(t, 0), max(duration, progressDeck.duration))
            if abs(currentTime - clamped) >= progressPublishEpsilon {
                setCurrentTime(clamped)
                // Position-only (tiny write). Full queue snapshot is on track/queue/pause/background.
                schedulePersistPlaybackPosition()
            }
        }
        if now - lastNowPlayingPush >= 5 {
            updateNowPlaying(force: false)
        }
        // Backup natural crossfade check on every progress tick
        if crossfade.isEnabled, !isTransitioning, duration > 0 {
            fireCrossfadeIfNeeded()
        }
    }

    // MARK: - Remote / Now Playing

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                try? AVAudioSession.sharedInstance().setActive(true)
                self?.resume()
            }
            return .success
        }
        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        cc.togglePlayPauseCommand.isEnabled = true
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                try? AVAudioSession.sharedInstance().setActive(true)
                self?.togglePlayPause()
            }
            return .success
        }
        cc.nextTrackCommand.isEnabled = true
        cc.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipForward() }
            return .success
        }
        cc.previousTrackCommand.isEnabled = true
        cc.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipBackward() }
            return .success
        }
        cc.changePlaybackPositionCommand.isEnabled = true
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = event.positionTime
            guard t.isFinite, t >= 0 else { return .commandFailed }
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
    }

    private func updateNowPlaying(force: Bool = false) {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            cachedNowPlayingArtwork = nil
            cachedArtworkTrackID = nil
            nowPlayingArtLoadToken &+= 1
            return
        }
        if !force, var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            lastNowPlayingPush = ProcessInfo.processInfo.systemUptime
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        // Catalog `artworkData` is a ~96px list thumb — fine for rows, soft on Lock Screen.
        // Push that immediately so chrome isn’t blank, then upgrade from the file’s full cover.
        if cachedArtworkTrackID != track.id || cachedNowPlayingArtwork == nil {
            let needFullLoad = cachedArtworkTrackID != track.id
            cachedArtworkTrackID = track.id
            if let data = track.artworkData, let image = UIImage(data: data) {
                cachedNowPlayingArtwork = Self.makeNowPlayingArtwork(from: image)
            } else if needFullLoad {
                cachedNowPlayingArtwork = nil
            }
            if needFullLoad {
                scheduleHighResNowPlayingArtwork(for: track)
            }
        }
        if let art = cachedNowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = art
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastNowPlayingPush = ProcessInfo.processInfo.systemUptime
    }

    /// Load embedded cover (same path as immersive hero) for crisp Lock Screen / Control Center art.
    private func scheduleHighResNowPlayingArtwork(for track: Track) {
        nowPlayingArtLoadToken &+= 1
        let token = nowPlayingArtLoadToken
        let trackID = track.id
        let thumbData = track.artworkData
        let fileURL = track.resolvedURL()
        Task { @MainActor [weak self] in
            // ~512pt × screen scale ≈ 1000–1500px — sharp on lock screen without multi‑MB full RAW.
            let image = await ArtworkImageCache.heroImage(
                trackID: trackID,
                thumbData: thumbData,
                fileURL: fileURL,
                maxPointSide: 512
            )
            guard let self else { return }
            guard token == self.nowPlayingArtLoadToken else { return }
            guard self.currentTrack?.id == trackID else { return }
            guard let image else { return }
            self.cachedArtworkTrackID = trackID
            self.cachedNowPlayingArtwork = Self.makeNowPlayingArtwork(from: image)
            // Re-publish metadata with high-res art (force rebuild, art already cached).
            self.updateNowPlaying(force: true)
        }
    }

    /// System requests various sizes; hand back the best image we have (caller already sized).
    private static func makeNowPlayingArtwork(from image: UIImage) -> MPMediaItemArtwork {
        let side = max(image.size.width, image.size.height, 1)
        let bounds = CGSize(width: side, height: side)
        return MPMediaItemArtwork(boundsSize: bounds) { size in
            // Prefer returning a well-sized image when the system asks for a specific box.
            let target = max(size.width, size.height)
            guard target > 1, max(image.size.width, image.size.height) > target * 1.25 else {
                return image
            }
            let scale = target / max(image.size.width, image.size.height)
            let newSize = CGSize(
                width: max(1, (image.size.width * scale).rounded(.down)),
                height: max(1, (image.size.height * scale).rounded(.down))
            )
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = false
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            return renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
    }

    private func showToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == msg { toast = nil }
        }
    }

    // MARK: - Persistence

    private func schedulePersistEQ() {
        eqPersistTask?.cancel()
        eqPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistEQNow()
        }
    }

    private func schedulePersistCrossfade() {
        crossfadePersistTask?.cancel()
        crossfadePersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistCrossfadeNow()
        }
    }

    private func flushPersistedSettings() {
        eqPersistTask?.cancel()
        crossfadePersistTask?.cancel()
        sessionPersistTask?.cancel()
        persistEQNow()
        persistCrossfadeNow()
        persistPlaybackSessionNow()
    }

    private func schedulePersistPlaybackSession() {
        sessionPersistTask?.cancel()
        sessionPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.persistPlaybackSessionNow()
        }
    }

    /// Cheap position write during playback — avoids re-encoding the whole queue every few ticks.
    /// Foreground ~2.5s; background/LPM ~5s to cut flash wear and idle wakeups.
    private func schedulePersistPlaybackPosition() {
        let now = ProcessInfo.processInfo.systemUptime
        let minInterval: TimeInterval = {
            if ProcessInfo.processInfo.isLowPowerModeEnabled { return 6.0 }
            if UIApplication.shared.applicationState == .background { return 5.0 }
            return 2.5
        }()
        guard now - lastPositionPersistUptime >= minInterval else { return }
        lastPositionPersistUptime = now
        UserDefaults.standard.set(currentTime, forKey: Self.sessionPositionKey)
    }

    private func persistPlaybackSessionNow() {
        guard let current = currentTrack, !queue.isEmpty else {
            // Nothing to resume.
            if currentTrack == nil {
                Self.clearPlaybackSessionSnapshot()
            }
            return
        }
        let idx = min(max(queueIndex, 0), queue.count - 1)
        // Skip identical full snapshots (same queue + index) — only refresh position key.
        var sig = queue.count &* 1_000_003 &+ idx
        sig = sig &+ current.id.hashValue
        if sig == lastFullSessionSignature {
            UserDefaults.standard.set(currentTime, forKey: Self.sessionPositionKey)
            return
        }
        lastFullSessionSignature = sig
        let snap = PlaybackSessionSnapshot(
            queue: queue.map { .init(track: $0) },
            queueIndex: idx,
            positionSeconds: currentTime,
            originalQueue: originalQueue.map { .init(track: $0) },
            version: 1
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.sessionDefaultsKey)
            UserDefaults.standard.set(currentTime, forKey: Self.sessionPositionKey)
        }
    }

    private static func loadPlaybackSessionSnapshot() -> PlaybackSessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: sessionDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(PlaybackSessionSnapshot.self, from: data)
    }

    private static func clearPlaybackSessionSnapshot() {
        UserDefaults.standard.removeObject(forKey: sessionDefaultsKey)
        UserDefaults.standard.removeObject(forKey: sessionPositionKey)
    }

    private func persistEQNow() {
        if let data = try? JSONEncoder().encode(dual) {
            UserDefaults.standard.set(data, forKey: eqDefaultsKey)
        }
    }

    private func loadEQ() {
        guard let data = UserDefaults.standard.data(forKey: eqDefaultsKey),
              let decoded = try? JSONDecoder().decode(DualEQState.self, from: data) else { return }
        dual = decoded
    }

    private func persistCrossfadeNow() {
        if let data = try? JSONEncoder().encode(crossfade) {
            UserDefaults.standard.set(data, forKey: crossfadeDefaultsKey)
        }
    }

    private func loadCrossfade() {
        guard let data = UserDefaults.standard.data(forKey: crossfadeDefaultsKey),
              let decoded = try? JSONDecoder().decode(CrossfadeSettings.self, from: data) else {
            crossfade = CrossfadeSettings(durationSeconds: 3)
            return
        }
        crossfade = decoded
    }

    private func loadPlaybackModes() {
        if let raw = UserDefaults.standard.string(forKey: Self.repeatDefaultsKey),
           let mode = RepeatMode(rawValue: raw) {
            repeatMode = mode
        }
        if let raw = UserDefaults.standard.string(forKey: Self.shuffleDefaultsKey),
           let mode = ShuffleMode(rawValue: raw) {
            shuffleMode = mode
        }
    }

    // MARK: - Security scope

    private func retainSecurityAccess(for url: URL) {
        if url.startAccessingSecurityScopedResource() {
            securityScopedURLs.insert(url)
        }
    }

    private func releaseSecurityAccess(for url: URL) {
        if securityScopedURLs.contains(url) {
            url.stopAccessingSecurityScopedResource()
            securityScopedURLs.remove(url)
        }
    }

    private func clearAllSecurityAccess() {
        for url in securityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        securityScopedURLs.removeAll()
    }
}

// MARK: - Lightweight session snapshot (no artwork blobs)

private struct PlaybackSessionSnapshot: Codable {
    struct TrackRef: Codable {
        var id: UUID
        var fileKey: String?
        var title: String
        var artist: String
        var album: String
        var duration: TimeInterval

        init(track: Track) {
            id = track.id
            fileKey = track.fileKey
            title = track.title
            artist = track.artist
            album = track.album
            duration = track.duration
        }
    }

    var queue: [TrackRef]
    var queueIndex: Int
    /// Position on the playable timeline (0…duration after silence trim).
    var positionSeconds: TimeInterval
    var originalQueue: [TrackRef]
    var version: Int
}
