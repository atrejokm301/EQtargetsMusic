//
//  RootTabView.swift
//  EQtargetsMusic
//
//  Layering (same root ZStack):
//    0  TabView content + system dock (always mounted)
//   10  Stable MiniPlayer chrome (mounted while a track exists; never reparented for expand)
//  100  Immersive transition surface (mounted when transitionProgress > 0)
//  Queue sheet is presented on Immersive (above full player)
//
//  Interactive expand/collapse is driven by transitionProgress (0…1).
//  Mini/dock layout is never animated for this transition.
//

import SwiftUI

private enum RootTab: Hashable {
    case nowPlaying
    case music
    case artists
    case albums
    case search
}

struct RootTabView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var library = LibraryStore()
    @StateObject private var player = AudioPlayerEngine()
    @StateObject private var presetStore = EQPresetStore()

    @AppStorage("app_accent_theme") private var accentThemeRaw: String = AppAccentTheme.blue.rawValue
    /// Smart BPM Shuffle: library/queue selection only (never touches audio graph).
    @AppStorage(SmartShuffleSelector.enabledDefaultsKey) private var smartBPMShuffleEnabled = false
    @State private var showHamburgerSheet = false
    @State private var showCrossfadeFromMenu = false
    @State private var selectedTab: RootTab = .music

    /// UI-only presentation phase (not playback).
    @State private var presentation: PlayerPresentation = .collapsed
    /// Continuous expand progress 0…1.
    @State private var transitionProgress: CGFloat = 0
    /// Mini artwork global frame for hero interpolation.
    @State private var miniArtGlobalFrame: CGRect = .zero
    /// Window-bottom → top edge of UITabBar (mini parking).
    @State private var dockTopFromBottom: CGFloat = 83
    /// Container height for expansion distance.
    @State private var containerHeight: CGFloat = 800
    /// Pre-warmed art tint/thumb for continuous full-player background (sync, no black placeholder).
    @State private var playerArtworkVisuals: PlayerArtworkVisuals = .brandedFallback(accent: .blue)

    private let miniDockGap: CGFloat = 4

    private var hasCurrentPlayableTrack: Bool {
        player.currentTrack != nil
    }

    private var hideBottomChrome: Bool {
        // Only hide Mini once wash is covering — no layout animation.
        transitionProgress > PlayerTransitionMetrics.chromeHideThreshold
    }

    /// Fade mini art/title early to avoid duplicate labels with hero (pill frame stays put).
    private var miniContentFade: CGFloat {
        1 - PlayerTransitionMetrics.smoothstep(
            PlayerTransitionMetrics.miniContentFadeStart,
            PlayerTransitionMetrics.miniContentFadeEnd,
            transitionProgress
        )
    }

    private var showPlayerOverlay: Bool {
        // Keep overlay mounted for any non-zero progress so close never drops to a black plate then pop.
        hasCurrentPlayableTrack && transitionProgress > 0.001
    }

    private var isExternalDragging: Bool {
        presentation == .dragging
    }

    private var currentAccentTheme: AppAccentTheme {
        AppAccentTheme(rawValue: accentThemeRaw) ?? .blue
    }

    private var theme: GrokTheme {
        GrokTheme(isDark: scheme == .dark, accentTheme: currentAccentTheme)
    }

    private var expansionDistance: CGFloat {
        PlayerTransitionMetrics.expansionDistance(containerHeight: containerHeight)
    }

    init() {
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        navAppearance.shadowColor = .clear
        navAppearance.shadowImage = UIImage()
        navAppearance.backgroundColor = .clear
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithTransparentBackground()
        tabAppearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterial)
        tabAppearance.backgroundColor = UIColor.clear
        tabAppearance.shadowColor = UIColor.separator.withAlphaComponent(0.28)
        tabAppearance.shadowImage = UIImage()
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        UITabBar.appearance().isTranslucent = true
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // zIndex 0 — app content + system dock (always mounted).
                TabView(selection: $selectedTab) {
                    NavigationStack {
                        NowPlayingView()
                            .toolbar { hamburgerToolbarItem }
                    }
                    .tabItem { Label("Now Playing", systemImage: "play.circle.fill") }
                    .tag(RootTab.nowPlaying)

                    NavigationStack {
                        MusicListView()
                            .toolbar { hamburgerToolbarItem }
                    }
                    .tabItem { Label("Music", systemImage: "music.note.list") }
                    .tag(RootTab.music)

                    NavigationStack {
                        ArtistsListView()
                            .toolbar { hamburgerToolbarItem }
                    }
                    .tabItem { Label("Artists", systemImage: "person.2.fill") }
                    .tag(RootTab.artists)

                    NavigationStack {
                        AlbumsListView()
                            .toolbar { hamburgerToolbarItem }
                    }
                    .tabItem { Label("Albums", systemImage: "square.stack.fill") }
                    .tag(RootTab.albums)

                    NavigationStack {
                        SearchView()
                            .toolbar { hamburgerToolbarItem }
                    }
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(RootTab.search)
                }
                .tint(theme.accent)
                .toolbarBackground(.visible, for: .tabBar)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if hasCurrentPlayableTrack {
                        Color.clear
                            .frame(height: MiniPlayerBar.barHeight + miniDockGap + 4)
                            .accessibilityHidden(true)
                            .transaction { $0.animation = nil }
                    }
                }
                .background {
                    TabBarHeightReader { fromBottom in
                        if abs(fromBottom - dockTopFromBottom) > 0.5 {
                            var t = Transaction()
                            t.disablesAnimations = true
                            withTransaction(t) {
                                dockTopFromBottom = fromBottom
                            }
                        }
                    }
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                }
                .zIndex(0)

                // zIndex 10 — STABLE MiniPlayer chrome (never removed for full-player presentation).
                if hasCurrentPlayableTrack {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        MiniPlayerBar(
                            onTapExpand: { animateExpand() },
                            onExpandDragChanged: { translationY in
                                handleMiniDragChanged(translationY: translationY)
                            },
                            onExpandDragEnded: { translationY, predictedY in
                                handleMiniDragEnded(translationY: translationY, predictedY: predictedY)
                            },
                            contentFade: miniContentFade
                        )
                        .padding(.horizontal, MiniPlayerBar.horizontalInset)
                        .padding(.bottom, dockTopFromBottom + miniDockGap)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: .bottom)
                    .opacity(hideBottomChrome ? 0 : 1)
                    .allowsHitTesting(!hideBottomChrome)
                    .accessibilityHidden(hideBottomChrome)
                    .transaction { $0.animation = nil }
                    .zIndex(10)
                }

                // zIndex 100 — transition / full player surface.
                if showPlayerOverlay {
                    ImmersivePlayerView(
                        progress: $transitionProgress,
                        isExternalDragging: isExternalDragging,
                        miniArtGlobalFrame: miniArtGlobalFrame,
                        artworkVisuals: playerArtworkVisuals,
                        onOpenEQWorkspace: {
                            settleToCollapsed(then: {
                                selectedTab = .nowPlaying
                            })
                        },
                        onProgressSettled: { expanded in
                            finalizePresentation(expanded: expanded)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .transition(.identity)
                    .zIndex(100)
                }
            }
            .onPreferenceChange(MiniPlayerArtFrameKey.self) { frame in
                if frame.width > 1 {
                    miniArtGlobalFrame = frame
                }
            }
            .onAppear {
                containerHeight = geo.size.height
            }
            .onChange(of: geo.size.height) { h in
                if abs(h - containerHeight) > 0.5 {
                    containerHeight = h
                }
            }
        }
        .environment(\.grokTheme, theme)
        .environmentObject(library)
        .environmentObject(player)
        .environmentObject(presetStore)
        .preferredColorScheme(nil)
        .onChange(of: player.currentTrack?.id) { _ in
            refreshPlayerArtworkVisuals()
            reconcileWithTrack()
            ensureSmartBPMUpNext()
        }
        .onAppear {
            refreshPlayerArtworkVisuals()
            reconcileWithTrack()
            ensureSmartBPMUpNext()
        }
        .onChange(of: library.isAnalyzingBPM) { analyzing in
            if !analyzing {
                player.syncLibraryMetadata(from: library.tracks)
                ensureSmartBPMUpNext()
            }
        }
        // When Up Next is emptied (clear / end of list) or a fade finishes, optionally refill.
        .onChange(of: player.queue.count) { _ in
            ensureSmartBPMUpNext()
        }
        .onChange(of: player.queueIndex) { _ in
            ensureSmartBPMUpNext()
        }
        .onChange(of: player.isTransitioning) { fading in
            if !fading {
                ensureSmartBPMUpNext()
            }
        }
        .onChange(of: smartBPMShuffleEnabled) { on in
            if on {
                SmartShuffleHost.resetSessionState()
                ensureSmartBPMUpNext()
            } else {
                SmartShuffleHost.resetSessionState()
            }
        }
        .onChange(of: transitionProgress) { p in
            // Snap presentation when progress fully settles without an active drag.
            if presentation == .dragging { return }
            if p <= 0.001, presentation != .collapsed {
                presentation = .collapsed
            } else if p >= 0.99, presentation != .expanded {
                presentation = .expanded
            }
        }
        .task {
            await library.ensureLibraryReady()
        }
        .sheet(isPresented: $showHamburgerSheet) {
            HamburgerMenuSheet(
                accentThemeRaw: $accentThemeRaw,
                onOpenCrossfade: {
                    showHamburgerSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showCrossfadeFromMenu = true
                    }
                }
            )
            .environmentObject(player)
            .environmentObject(library)
            .environmentObject(presetStore)
            .environment(\.grokTheme, theme)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCrossfadeFromMenu) {
            AutoMixSettingsSheet()
                .environmentObject(player)
                .environment(\.grokTheme, theme)
        }
        // Global toast — library / queue actions are not only on Now Playing.
        .overlay(alignment: .top) {
            if let toast = player.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .padding(.top, 8)
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .zIndex(500)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: player.toast)
    }

    // MARK: - Smart BPM Shuffle (queue selection only)

    /// Inserts at most one automatic Up Next item via `playNext` when allowed.
    /// Never schedules decks or touches crossfade/silence-skip.
    private func ensureSmartBPMUpNext() {
        SmartShuffleHost.ensureAutomaticUpNextIfNeeded(
            enabled: smartBPMShuffleEnabled,
            queue: player,
            library: library.tracks
        )
    }

    // MARK: - Track reconcile + visual prewarm

    private func reconcileWithTrack() {
        if player.currentTrack == nil {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                transitionProgress = 0
                presentation = .collapsed
            }
        }
    }

    /// Sync tint/thumb before any open so the first transition frame is never pure black.
    private func refreshPlayerArtworkVisuals() {
        let next = PlayerArtworkVisualCache.visuals(for: player.currentTrack, accent: theme.accent)
        if let track = player.currentTrack {
            PlayerArtworkVisualCache.prewarm(track: track, accent: theme.accent)
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            playerArtworkVisuals = next
        }
    }

    // MARK: - Expand / collapse

    private func animateExpand() {
        guard hasCurrentPlayableTrack else { return }
        if reduceMotion {
            withAnimation(PlayerTransitionMetrics.reduceMotionExpand) {
                transitionProgress = 1
            }
            presentation = .expanded
            return
        }
        withAnimation(PlayerTransitionMetrics.openSpring) {
            transitionProgress = 1
        }
        presentation = .expanded
    }

    private func handleMiniDragChanged(translationY: CGFloat) {
        guard hasCurrentPlayableTrack else { return }
        // Finger-direct: linear progress (staging lives on visual layers only).
        let up = max(0, -translationY)
        let p = PlayerTransitionMetrics.clamp(up / expansionDistance)
        presentation = .dragging
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            transitionProgress = p
        }
    }

    private func handleMiniDragEnded(translationY: CGFloat, predictedY: CGFloat) {
        guard hasCurrentPlayableTrack else { return }
        let up = max(0, -translationY)
        let predictedUp = max(0, -predictedY)
        let p = PlayerTransitionMetrics.clamp(up / expansionDistance)
        let strongFling = predictedUp > expansionDistance * 0.40 || predictedY < -700

        let shouldExpand = p >= PlayerTransitionMetrics.expandCommitThreshold || strongFling
        settle(to: shouldExpand ? 1 : 0)
    }

    private func settle(to target: CGFloat) {
        if reduceMotion {
            withAnimation(target >= 0.99
                          ? PlayerTransitionMetrics.reduceMotionExpand
                          : PlayerTransitionMetrics.reduceMotionCollapse) {
                transitionProgress = target
            }
            presentation = target >= 0.99 ? .expanded : .collapsed
            return
        }
        // Soft settle: cancel mid-drag uses cancel spring; commit uses open/close.
        let anim: Animation
        if target >= 0.99 {
            anim = presentation == .dragging
                ? PlayerTransitionMetrics.cancelSpring
                : PlayerTransitionMetrics.openSpring
        } else {
            anim = PlayerTransitionMetrics.closeSpring
        }
        presentation = .dragging
        withAnimation(anim) {
            transitionProgress = target
        }
        presentation = target >= 0.99 ? .expanded : .collapsed
    }

    private func settleToCollapsed(then extra: (() -> Void)? = nil) {
        if reduceMotion {
            withAnimation(PlayerTransitionMetrics.reduceMotionCollapse) {
                transitionProgress = 0
            }
            presentation = .collapsed
            extra?()
            return
        }
        presentation = .dragging
        withAnimation(PlayerTransitionMetrics.closeSpring) {
            transitionProgress = 0
        }
        presentation = .collapsed
        extra?()
    }

    private func finalizePresentation(expanded: Bool) {
        // Called from Immersive after interactive collapse/expand settle.
        if expanded {
            if transitionProgress > 0.95 {
                presentation = .expanded
            }
        } else {
            if transitionProgress < 0.05 {
                presentation = .collapsed
            }
        }
    }

    private var hamburgerToolbarItem: ToolbarItem<(), some View> {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showHamburgerSheet = true
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(theme.accent)
            }
        }
    }
}

struct HamburgerMenuSheet: View {
    @Binding var accentThemeRaw: String
    var onOpenCrossfade: () -> Void = {}

    @EnvironmentObject private var player: AudioPlayerEngine
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.grokTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SmartShuffleSelector.enabledDefaultsKey) private var smartBPMShuffleEnabled = false

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private let sleepChoices = AudioPlayerEngine.sleepTimerMinuteChoices

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    libraryStatsCard
                    sleepTimerCard
                    playbackModesCard
                    djControlsCard
                    accentThemeCard
                }
                .padding(16)
                .padding(.bottom, 12)
            }
            .background { LiquidGlassBackground() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
            }
        }
    }

    // MARK: - Cards

    private var libraryStatsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(icon: "music.note.house.fill", title: "Library")
            HStack(spacing: 12) {
                statPill(value: "\(library.tracks.count)", label: "Tracks")
                statPill(value: "\(library.artistGroups.count)", label: "Artists")
                statPill(value: "\(library.albumGroups.count)", label: "Albums")
            }
            HStack(spacing: 8) {
                Image(systemName: "metronome.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                Text("\(library.knownBPMCount) with BPM · \(library.missingBPMCount) missing · \(library.uncheckedBPMCount) pending")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                if library.uncheckedBPMCount > 0 || library.missingBPMCount > 0 {
                    Button {
                        Task { await library.analyzeMissingBPMs() }
                    } label: {
                        Text(library.isAnalyzingBPM ? "Working…" : "Analyze")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(theme.accent)
                    .disabled(library.isAnalyzingBPM)

                    if library.missingBPMCount > 0 {
                        Button {
                            Task { await library.forceRedetectMissingBPMValues() }
                        } label: {
                            Text("Re-scan all missing")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(theme.accent)
                        .disabled(library.isAnalyzingBPM)
                    }
                }
            }
            if library.isAnalyzingBPM {
                ProgressView(library.statusMessage.isEmpty ? "Analyzing BPM…" : library.statusMessage)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
        }
        .padding(14)
        .glassCard(corner: 16)
    }

    private var sleepTimerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader(icon: "moon.zzz.fill", title: "Sleep Timer")
                Spacer()
                if let label = player.sleepTimerRemainingLabel {
                    Text(label)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.accent.opacity(0.15)))
                }
            }
            Text("Pauses playback when the timer ends. Great for falling asleep.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.secondaryText)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 52), spacing: 8)],
                spacing: 8
            ) {
                ForEach(sleepChoices, id: \.self) { minutes in
                    let selected = minutes == 0
                        ? player.sleepTimerMinutes == nil
                        : player.sleepTimerMinutes == minutes
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        player.setSleepTimer(minutes: minutes == 0 ? nil : minutes)
                    } label: {
                        Text(minutes == 0 ? "Off" : (minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(selected ? Color.white : theme.primaryText)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selected ? theme.accent : theme.elevated)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(minutes == 0 ? "Sleep timer off" : "Sleep timer \(minutes) minutes")
                }
            }
        }
        .padding(14)
        .glassCard(corner: 16)
    }

    private var playbackModesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "shuffle", title: "Playback")

            HStack(spacing: 10) {
                modeButton(
                    title: shuffleTitle,
                    icon: player.shuffleMode.iconName,
                    active: player.shuffleMode != .off
                ) {
                    player.cycleShuffleMode()
                }
                modeButton(
                    title: repeatTitle,
                    icon: player.repeatMode.iconName,
                    active: player.repeatMode != .off
                ) {
                    player.cycleRepeatMode()
                }
            }

            Toggle(isOn: $smartBPMShuffleEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart Tempo Up Next")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("Keeps Adoración vs Júbilo separate. When Up Next is empty, auto-picks same tempo lane (slow / mid / upbeat). Manual queue always wins.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .tint(theme.accent)

            if smartBPMShuffleEnabled {
                TempoLaneThresholdsEditor()
            }
        }
        .padding(14)
        .glassCard(corner: 16)
    }

    private var djControlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(icon: "waveform.path", title: "Crossfade & DJ")

            Button {
                onOpenCrossfade()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "shuffle.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(player.crossfade.isEnabled ? theme.accent : theme.secondaryText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Crossfade settings")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text(crossfadeSubtitle)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.tertiaryText)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.elevated)
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens crossfade, silence skip, and Smart BPM settings")
        }
        .padding(14)
        .glassCard(corner: 16)
    }

    private var accentThemeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(icon: "paintpalette.fill", title: "Accent Theme")

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(AppAccentTheme.allCases) { item in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        accentThemeRaw = item.rawValue
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(item.color(for: theme.isDark))
                                .frame(width: 10, height: 10)
                            Text(item.title)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(accentThemeRaw == item.rawValue ? theme.accent.opacity(0.18) : theme.elevated)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(accentThemeRaw == item.rawValue ? theme.accent : Color.clear, lineWidth: 1.2)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Accent \(item.title)")
                    .accessibilityAddTraits(accentThemeRaw == item.rawValue ? .isSelected : [])
                }
            }
        }
        .padding(14)
        .glassCard(corner: 16)
    }

    // MARK: - Helpers

    private var shuffleTitle: String {
        switch player.shuffleMode {
        case .off: return "Shuffle Off"
        case .standard: return "Shuffle"
        case .banger: return "Banger"
        }
    }

    private var repeatTitle: String {
        switch player.repeatMode {
        case .off: return "Repeat Off"
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        }
    }

    private var crossfadeSubtitle: String {
        if !player.crossfade.isEnabled { return "Off · hard cuts between tracks" }
        var parts = ["\(player.crossfade.durationSeconds)s", player.crossfade.curve.title]
        if player.crossfade.skipSilence { parts.append("skip silence") }
        if player.crossfade.adaptiveBPM { parts.append("smart tempo") }
        return parts.joined(separator: " · ")
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(theme.accent)
            Text(title)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
        }
    }

    private func statPill(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.elevated)
        )
    }

    private func modeButton(title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(active ? Color.white : theme.primaryText)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? theme.accent : theme.elevated)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tempo lane cutoffs (shared: Settings + Crossfade sheet)

/// Tune where Adoración ends and Júbilo begins. Mid is everything between.
struct TempoLaneThresholdsEditor: View {
    @Environment(\.grokTheme) private var theme

    @State private var adoracionMax: Double = TempoFeel.thresholds.adoracionMax
    @State private var jubiloMin: Double = TempoFeel.thresholds.jubiloMin

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(theme.accent)
                Text("Tempo lane cutoffs")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 0)
                Button("Reset") {
                    TempoFeel.resetThresholdsToDefaults()
                    reload()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.accent)
            }

            Text("If a mid song feels like slow worship or like júbilo, drag these lines. Smart Tempo + crossfade use the same cutoffs.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            // Live band map
            Text(TempoFeel.thresholdsSummary)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.accent)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.elevated)
                )

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Adoración ends below")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text("\(Int(adoracionMax.rounded())) BPM")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.accent)
                }
                Slider(
                    value: $adoracionMax,
                    in: TempoFeel.adoracionMaxRange,
                    step: 1
                ) { editing in
                    if !editing { commit() }
                }
                .tint(theme.accent)
                .onChange(of: adoracionMax) { _ in commit() }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Júbilo starts at")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text("\(Int(jubiloMin.rounded())) BPM")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.accent)
                }
                Slider(
                    value: $jubiloMin,
                    in: TempoFeel.jubiloMinRange,
                    step: 1
                ) { editing in
                    if !editing { commit() }
                }
                .tint(theme.accent)
                .onChange(of: jubiloMin) { _ in commit() }
            }

            Text("Example: a 100 BPM song is Mid if cutoffs are 92 / 118. Raise “Adoración ends below” to 100 if you want that song treated as slow worship.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
        .onAppear(perform: reload)
    }

    private func reload() {
        let t = TempoFeel.thresholds
        adoracionMax = t.adoracionMax
        jubiloMin = t.jubiloMin
    }

    private func commit() {
        TempoFeel.writeThresholds(adoracionMax: adoracionMax, jubiloMin: jubiloMin)
        // Reflect any clamp (mid-band width).
        let t = TempoFeel.thresholds
        if abs(t.adoracionMax - adoracionMax) > 0.01 { adoracionMax = t.adoracionMax }
        if abs(t.jubiloMin - jubiloMin) > 0.01 { jubiloMin = t.jubiloMin }
    }
}
