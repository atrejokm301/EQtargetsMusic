//
//  ImmersivePlayerView.swift
//  EQtargetsMusic
//
//  Full-screen listening surface driven by root `transitionProgress` (0…1).
//  Staged opacities for deliberate open/close; pull-down from anywhere to collapse.
//  Queue sheet above this view. Playback remains AudioPlayerEngine only.
//

import SwiftUI

struct ImmersivePlayerView: View {
    @EnvironmentObject private var player: AudioPlayerEngine
    @Environment(\.grokTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// 0 = collapsed visual, 1 = fully expanded.
    @Binding var progress: CGFloat
    /// True while root/mini is driving an interactive expand drag.
    var isExternalDragging: Bool
    /// Mini artwork frame in global coordinates (for hero interpolation).
    var miniArtGlobalFrame: CGRect
    /// Pre-warmed sync visuals (tint/thumb) — available before first painted frame.
    var artworkVisuals: PlayerArtworkVisuals
    var onOpenEQWorkspace: (() -> Void)?
    /// Host sets presentation after progress settles (optional side effects).
    var onProgressSettled: ((_ expanded: Bool) -> Void)?

    @State private var showQueue = false

    /// Finger-driven collapse delta applied on top of committed progress baseline.
    @State private var collapseDragY: CGFloat = 0
    @State private var collapseDragActive = false
    @State private var progressAtCollapseStart: CGFloat = 1

    @State private var heroImage: UIImage?
    @State private var heroTrackID: UUID?
    @State private var heroLoadTask: Task<Void, Never>?
    @State private var backdropImage: UIImage?

    /// 8pt grid — glass action pills (Queue / EQ).
    private let controlCorner: CGFloat = 16

    /// Warm paper-white for type on black art rooms (brand dark primary, not cool #FFF).
    private var immersiveInk: Color {
        Color.appPrimaryText(isDark: true)
    }

    private var isInteractivelyDragging: Bool {
        isExternalDragging || collapseDragActive
    }

    private func effectiveProgress(containerHeight: CGFloat) -> CGFloat {
        // Prefer binding `progress` (updated live during collapse) so finger and paint stay in lockstep.
        _ = containerHeight
        return PlayerTransitionMetrics.clamp(progress)
    }

    /// Shorter than open distance so dismiss still responds early, but not so short it feels edgy.
    private func collapseDistance(containerHeight: CGFloat) -> CGFloat {
        max(containerHeight * 0.48, 260)
    }

    var body: some View {
        GeometryReader { geo in
            let topSafe = max(geo.safeAreaInsets.top, 54)
            let bottomSafe = max(geo.safeAreaInsets.bottom, 12)
            let h = geo.size.height
            let w = geo.size.width
            let usableH = h - topSafe - bottomSafe
            // 8pt grid chrome budget under art: meta · scrubber · transport · actions · gaps.
            // Pro Max gains larger art; short phones keep a floor so chrome never collides.
            let chromeBelowArt: CGFloat = 72 + 48 + 80 + 56 + 40
            let artFromBudget = max(240, usableH - chromeBelowArt - 24)
            let artSide = min(w - 48, artFromBudget, usableH * 0.52, 400)

            let p = effectiveProgress(containerHeight: h)
            let overlayGlobal = geo.frame(in: .global)

            let fullArtRect = CGRect(
                x: (w - artSide) / 2,
                y: min(topSafe + max(8, usableH * 0.04) + 96, h * 0.20),
                width: artSide,
                height: artSide
            )

            let miniLocal: CGRect = {
                // Fallback matches MiniPlayerBar art (36) if preference hasn't reported yet.
                guard miniArtGlobalFrame.width > 1 else {
                    return CGRect(x: 28, y: h - 128, width: 36, height: 36)
                }
                return CGRect(
                    x: miniArtGlobalFrame.minX - overlayGlobal.minX,
                    y: miniArtGlobalFrame.minY - overlayGlobal.minY,
                    width: miniArtGlobalFrame.width,
                    height: miniArtGlobalFrame.height
                )
            }()

            // Staged values from single progress.
            // During interactive collapse, use more linear mapping near p=1 so the first
            // finger movement is immediately visible (smoothstep plateaus feel like delay).
            let M = PlayerTransitionMetrics.self
            let interactiveCollapse = collapseDragActive
            let washT = interactiveCollapse
                ? M.clamp(p)
                : M.smoothstep(M.washStart, M.washEnd, p)
            let scrimT = interactiveCollapse
                ? M.clamp(p)
                : M.smoothstep(M.scrimStart, M.scrimEnd, p)
            // Art leads the transition: finger-linear while dragging (expand or collapse),
            // smoothstep only on free settle so it still feels cinematic after a tap/fling.
            let artGrowth: CGFloat = {
                if reduceMotion { return M.clamp(p) }
                if isInteractivelyDragging { return M.clamp(p) }
                return M.smoothstep(0, M.heroGrowthEnd, p)
            }()
            let metaT = reduceMotion ? M.smoothstep(0.15, 0.55, p) : M.smoothstep(M.metaStart, M.metaEnd, p)
            let scrubT = reduceMotion ? M.smoothstep(0.30, 0.70, p) : M.smoothstep(M.scrubberStart, M.scrubberEnd, p)
            let transportT = reduceMotion ? M.smoothstep(0.40, 0.80, p) : M.smoothstep(M.transportStart, M.transportEnd, p)
            let bottomT = reduceMotion ? M.smoothstep(0.50, 0.95, p) : M.smoothstep(M.bottomActionsStart, M.bottomActionsEnd, p)

            let currentArt = lerpRect(miniLocal, fullArtRect, artGrowth)
            // Match mini-player art corner (8) → full soft square (20).
            let artCorner = 8 + (20 - 8) * artGrowth

            // Linear lift with progress so dismiss responds on the first pixels
            // (smoothstep plateaus near p=1 felt like a dead zone / delay).
            let sheetLift: CGFloat = {
                if reduceMotion { return (1 - p) * 28 }
                // Match collapseDistance so finger dy maps ~1:1 while dragging down.
                let travel = collapseDistance(containerHeight: h)
                return (1 - p) * travel
            }()
            // Slight scale bloom so open/close reads as a soft expand, not a hard cut.
            let sheetScale: CGFloat = reduceMotion ? 1 : (0.972 + 0.028 * M.smoothstep(0.12, 1, p))
            let playScale: CGFloat = 0.94 + 0.06 * transportT

            ZStack {
                // Dynamic artwork blur stack: palette gradient → Material → scrim.
                // No per-frame palette work; no live large-image Gaussian path.
                playerDynamicBackground
                    .frame(width: w, height: h)
                    .opacity(Double(max(washT, scrimT * 0.85)))
                    .allowsHitTesting(false)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.48), value: artworkVisuals.trackID)

                // Hero artwork — continuous morph from mini art frame → full art.
                // Always fully opaque while the surface is up so open never “blinks” the cover.
                heroArtwork(side: max(currentArt.width, 1))
                    .frame(width: currentArt.width, height: currentArt.height)
                    .clipShape(RoundedRectangle(cornerRadius: artCorner, style: .continuous))
                    .shadow(
                        color: artworkVisuals.tintDeep.opacity(0.18 + 0.32 * Double(artGrowth)),
                        radius: 4 + 26 * artGrowth,
                        y: 2 + 14 * artGrowth
                    )
                    .position(x: currentArt.midX, y: currentArt.midY)
                    .opacity(p > 0.001 ? 1 : 0)
                    .allowsHitTesting(false)

                // Expanded chrome (staged).
                VStack(spacing: 0) {
                    dismissGrabChrome
                        .padding(.top, topSafe)
                        .opacity(Double(max(metaT, M.smoothstep(0.15, 0.45, p))))

                    Spacer(minLength: max(8, usableH * 0.04))

                    Color.clear
                        .frame(width: artSide, height: artSide)
                        .frame(maxWidth: .infinity)

                    // Title / artist / album — Google Sans Flex hierarchy, warm ink.
                    VStack(spacing: 4) {
                        Text(player.currentTrack?.title ?? "Nothing Playing")
                            .font(.app(size: 22, weight: .bold))
                            .foregroundStyle(immersiveInk)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)

                        Text(player.currentTrack?.artist ?? "")
                            .font(.app(size: 15, weight: .medium))
                            .foregroundStyle(immersiveInk.opacity(0.78))
                            .lineLimit(1)

                        if let album = player.currentTrack?.album, !album.isEmpty {
                            Text(album)
                                .font(.app(size: 12, weight: .regular))
                                .foregroundStyle(immersiveInk.opacity(0.42))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
                    .opacity(Double(metaT))
                    // Longer travel + spring = glide-in rather than a snap.
                    .offset(y: (1 - metaT) * (reduceMotion ? 8 : 16))

                    Spacer(minLength: 16)

                    PlayerProgressScrubber(
                        isInteractive: p >= M.interactiveControlsThreshold && !isInteractivelyDragging,
                        isCollapseDragging: collapseDragActive
                    )
                    .padding(.horizontal, 32)
                    .opacity(Double(scrubT))
                    .offset(y: (1 - scrubT) * (reduceMotion ? 6 : 12))
                    .allowsHitTesting(scrubT > 0.9 && !isInteractivelyDragging)

                    transportRow(playScale: playScale)
                        .foregroundStyle(immersiveInk)
                        .padding(.horizontal, 8)
                        .padding(.top, 12)
                        .opacity(Double(transportT))
                        .offset(y: (1 - transportT) * (reduceMotion ? 6 : 14))
                        .allowsHitTesting(transportT > 0.9 && !isInteractivelyDragging)

                    HStack(spacing: 12) {
                        liquidGlassButton(title: "Queue", systemImage: "list.bullet", emphasized: false) {
                            showQueue = true
                        }
                        .accessibilityLabel("Queue, Playing Next")
                        .disabled(p < M.interactiveControlsThreshold)

                        liquidGlassButton(
                            title: player.dual.isBypassed ? "EQ Off" : "EQ",
                            systemImage: "slider.vertical.3",
                            emphasized: !player.dual.isBypassed
                        ) {
                            collapseThen {
                                onOpenEQWorkspace?()
                            }
                        }
                        .accessibilityLabel("Open equalizer workspace")
                        .disabled(p < M.interactiveControlsThreshold)
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
                    .padding(.bottom, bottomSafe + 12)
                    .opacity(Double(bottomT))
                    .offset(y: (1 - bottomT) * (reduceMotion ? 6 : 12))
                    .allowsHitTesting(bottomT > 0.9 && p >= M.interactiveControlsThreshold && !isInteractivelyDragging)
                }
                .frame(width: w, height: h, alignment: .top)
                .scaleEffect(sheetScale, anchor: .bottom)
                .offset(y: sheetLift)
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            // simultaneous keeps buttons tappable; low min-distance makes dismiss snappy.
            .simultaneousGesture(collapseDragGesture(containerHeight: h))
            .allowsHitTesting(p > 0.5 && !isExternalDragging)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onAppear {
            seedBackdropFromVisuals()
            loadHeroArt(maxSide: 380)
        }
        .onChange(of: artworkVisuals.trackID) { _ in
            seedBackdropFromVisuals()
        }
        .onChange(of: player.currentTrack?.id) { id in
            seedBackdropFromVisuals()
            loadHeroArt(maxSide: 380)
            if id == nil {
                showQueue = false
                collapseDragActive = false
                collapseDragY = 0
            }
        }
        .sheet(isPresented: $showQueue) {
            QueueSheet(artworkVisuals: artworkVisuals)
                .environmentObject(player)
                .environment(\.grokTheme, theme)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                // Clear system card so material can blur the immersive player underneath.
                .presentationBackground(.clear)
                .presentationCornerRadius(30)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }

    // MARK: - Math

    private func lerpRect(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        let u = PlayerTransitionMetrics.clamp(t)
        return CGRect(
            x: a.minX + (b.minX - a.minX) * u,
            y: a.minY + (b.minY - a.minY) * u,
            width: a.width + (b.width - a.width) * u,
            height: a.height + (b.height - a.height) * u
        )
    }

    // MARK: - Transport

    private func transportRow(playScale: CGFloat) -> some View {
        let offInk = immersiveInk.opacity(0.52)
        return HStack(spacing: 0) {
            Button { player.cycleShuffleMode() } label: {
                Image(systemName: player.shuffleMode.iconName)
                    .font(.app(size: 17, weight: .semibold))
                    .foregroundStyle(player.shuffleMode == .off ? offInk : theme.accent)
                    .symbolVariant(player.shuffleMode == .banger ? .fill : .none)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Shuffle \(player.shuffleMode.rawValue)")

            Button { player.skipBackward() } label: {
                Image(systemName: "backward.fill")
                    .font(.app(size: 26, weight: .semibold))
                    .foregroundStyle(immersiveInk.opacity(0.92))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Previous track")

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.app(size: 68))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.accent)
                    .frame(width: 80, height: 80)
                    .contentShape(Rectangle())
                    .scaleEffect(playScale)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button { player.skipForward() } label: {
                Image(systemName: "forward.fill")
                    .font(.app(size: 26, weight: .semibold))
                    .foregroundStyle(immersiveInk.opacity(0.92))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next track")

            Button { player.cycleRepeatMode() } label: {
                Image(systemName: player.repeatMode.iconName)
                    .font(.app(size: 17, weight: .semibold))
                    .foregroundStyle(player.repeatMode == .off ? offInk : theme.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Repeat \(player.repeatMode.rawValue)")
        }
    }

    // MARK: - Hero art

    @ViewBuilder
    private func heroArtwork(side: CGFloat) -> some View {
        Group {
            if let heroImage {
                Image(uiImage: heroImage)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFill()
            } else if let track = player.currentTrack,
                      let thumb = ArtworkImageCache.image(trackID: track.id, data: track.artworkData) {
                Image(uiImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.app(size: 44, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
    }

    /// Full-player room: queue-style glass + tuned album blooms (no muddy plusLighter soup).
    private var playerDynamicBackground: some View {
        let atmos = artworkVisuals.atmosphericColors(maxStops: 4)
        let hasArt = artworkVisuals.hasArtwork && !atmos.isEmpty
        let c0 = atmos.indices.contains(0) ? atmos[0] : Color.clear
        let c1 = atmos.indices.contains(1) ? atmos[1] : c0
        let c2 = atmos.indices.contains(2) ? atmos[2] : c1
        let c3 = atmos.indices.contains(3) ? atmos[3] : c2

        return GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            ZStack {
                // A) Deep black foundation (same language as queue glass)
                Color.black
                    .ignoresSafeArea()

                if hasArt {
                    // B1) Soft vertical wash — primary → secondary → black
                    LinearGradient(
                        colors: [
                            c0.opacity(0.72),
                            c1.opacity(0.42),
                            c2.opacity(0.22),
                            Color.black.opacity(0.92)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()

                    // B2) Cover-centered bloom (behind hero art)
                    RadialGradient(
                        colors: [
                            c0.opacity(0.88),
                            c1.opacity(0.40),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.5, y: 0.30),
                        startRadius: 20,
                        endRadius: max(h * 0.58, 340)
                    )
                    .ignoresSafeArea()
                    .scaleEffect(x: 1.15, y: 1.0, anchor: .center)

                    // B3) Corner accents — second / third hues, soft (no harsh plusLighter)
                    RadialGradient(
                        colors: [c2.opacity(0.55), Color.clear],
                        center: UnitPoint(x: 0.05, y: 0.62),
                        startRadius: 8,
                        endRadius: max(w * 0.75, 260)
                    )
                    .ignoresSafeArea()

                    RadialGradient(
                        colors: [c3.opacity(0.48), Color.clear],
                        center: UnitPoint(x: 0.95, y: 0.16),
                        startRadius: 6,
                        endRadius: max(w * 0.65, 240)
                    )
                    .ignoresSafeArea()

                    // C) Light frost — keep album color vivid; type still reads via bottom scrim
                    if reduceTransparency {
                        Color.black.opacity(0.34)
                            .ignoresSafeArea()
                    } else {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .opacity(0.30)
                            .ignoresSafeArea()
                        Color.black.opacity(0.14)
                            .ignoresSafeArea()
                    }

                    // D) Top sheen (warm, not cool white)
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [
                                immersiveInk.opacity(0.06),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 56)
                        Spacer(minLength: 0)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                    // E) Bottom readability gradient (transport / actions)
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.black.opacity(0.22),
                                Color.black.opacity(0.58),
                                Color.black.opacity(0.84)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: h * 0.40)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                } else {
                    // No art: subtle accent breath so pure black isn't flat empty
                    RadialGradient(
                        colors: [
                            theme.accent.opacity(0.16),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.5, y: 0.28),
                        startRadius: 10,
                        endRadius: max(h * 0.5, 300)
                    )
                    .ignoresSafeArea()
                }
            }
        }
    }

    private func seedBackdropFromVisuals() {
        if let thumb = artworkVisuals.thumb {
            if backdropImage == nil || heroTrackID != artworkVisuals.trackID {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    backdropImage = thumb
                    if heroImage == nil { heroImage = thumb }
                    heroTrackID = artworkVisuals.trackID
                }
            }
        } else if artworkVisuals.trackID == nil {
            backdropImage = nil
            heroImage = nil
            heroTrackID = nil
        }
    }

    private func loadHeroArt(maxSide: CGFloat) {
        guard let track = player.currentTrack else { return }
        if heroTrackID != track.id {
            let thumb = artworkVisuals.thumb
                ?? ArtworkImageCache.image(trackID: track.id, data: track.artworkData)
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                heroImage = thumb
                if let thumb { backdropImage = thumb }
                heroTrackID = track.id
            }
        }

        heroLoadTask?.cancel()
        let trackID = track.id
        let thumb = track.artworkData
        let url = track.resolvedURL()
        heroLoadTask = Task {
            let img = await ArtworkImageCache.heroImage(
                trackID: trackID,
                thumbData: thumb,
                fileURL: url,
                maxPointSide: maxSide
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard player.currentTrack?.id == trackID else { return }
                if let img {
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        heroImage = img
                        backdropImage = img
                    }
                }
            }
        }
    }

    // MARK: - Dismiss

    private var dismissGrabChrome: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(immersiveInk.opacity(0.50))
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            HStack {
                Button {
                    collapseThen(nil)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.app(size: 16, weight: .bold))
                        .foregroundStyle(immersiveInk.opacity(0.92))
                        .frame(width: 44, height: 44)
                        .background {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .environment(\.colorScheme, .dark)
                                .overlay(Circle().strokeBorder(immersiveInk.opacity(0.22), lineWidth: 0.8))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close player")
                .disabled(showQueue)

                Spacer()

                if player.crossfade.isEnabled {
                    Text("Blend \(player.crossfade.durationSeconds)s")
                        .font(.app(size: 11, weight: .semibold))
                        .foregroundStyle(immersiveInk.opacity(0.58))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .environment(\.colorScheme, .dark)
                                .overlay(Capsule().strokeBorder(immersiveInk.opacity(0.18), lineWidth: 0.7))
                        }
                        .accessibilityLabel("Blend \(player.crossfade.durationSeconds) seconds")
                }
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .contentShape(Rectangle())
        .accessibilityHint("Swipe down anywhere to close the full player")
    }

    private func collapseDragGesture(containerHeight: CGFloat) -> some Gesture {
        // Low minimumDistance so the surface moves on the first intentional downward pixels.
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                guard !showQueue, !isExternalDragging else { return }
                let dy = value.translation.height
                let dx = abs(value.translation.width)
                // Vertical-ish down; looser so activation isn't delayed.
                guard dy > 2, dy >= dx * 0.55 else { return }

                if !collapseDragActive {
                    collapseDragActive = true
                    progressAtCollapseStart = max(progress, 0.99)
                }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    collapseDragY = dy
                    let dist = collapseDistance(containerHeight: containerHeight)
                    // Linear: dy/dist → progress. First pixels move the sheet immediately.
                    progress = PlayerTransitionMetrics.clamp(progressAtCollapseStart - dy / max(dist, 1))
                }
            }
            .onEnded { value in
                guard collapseDragActive else { return }
                let dy = max(0, value.translation.height)
                let predicted = value.predictedEndTranslation.height
                let dist = collapseDistance(containerHeight: containerHeight)
                let endProgress = PlayerTransitionMetrics.clamp(progressAtCollapseStart - dy / max(dist, 1))
                let velocityDown = predicted > dy + 90 || (predicted - dy) > 480

                let shouldCollapse = endProgress < PlayerTransitionMetrics.collapseCommitThreshold || velocityDown

                collapseDragActive = false
                collapseDragY = 0
                // progress already at endProgress from last onChanged; settle animates from there.
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    progress = endProgress
                }
                settle(to: shouldCollapse ? 0 : 1)
            }
    }

    private func collapseThen(_ extra: (() -> Void)?) {
        guard !showQueue else {
            showQueue = false
            return
        }
        if reduceMotion {
            withAnimation(PlayerTransitionMetrics.reduceMotionCollapse) {
                progress = 0
            }
            onProgressSettled?(false)
            extra?()
            return
        }
        withAnimation(PlayerTransitionMetrics.closeSpring) {
            progress = 0
        }
        onProgressSettled?(false)
        extra?()
    }

    private func settle(to target: CGFloat) {
        if reduceMotion {
            withAnimation(target >= 0.99
                          ? PlayerTransitionMetrics.reduceMotionExpand
                          : PlayerTransitionMetrics.reduceMotionCollapse) {
                progress = target
            }
            onProgressSettled?(target >= 0.99)
            return
        }
        let anim: Animation = target >= 0.99
            ? PlayerTransitionMetrics.cancelSpring
            : PlayerTransitionMetrics.closeSpring
        withAnimation(anim) {
            progress = target
        }
        onProgressSettled?(target >= 0.99)
    }

    // MARK: - Chrome

    private func liquidGlassButton(
        title: String,
        systemImage: String,
        emphasized: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.app(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(immersiveInk)
                .background {
                    RoundedRectangle(cornerRadius: controlCorner, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                        .overlay {
                            RoundedRectangle(cornerRadius: controlCorner, style: .continuous)
                                .fill(
                                    emphasized
                                        ? theme.accent.opacity(0.52)
                                        : immersiveInk.opacity(0.08)
                                )
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: controlCorner, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: emphasized
                                            ? [theme.accent.opacity(0.65), theme.accent.opacity(0.20)]
                                            : [immersiveInk.opacity(0.32), immersiveInk.opacity(0.08)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.8
                                )
                        }
                }
        }
        .buttonStyle(.plain)
    }
}
