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

    private let controlCorner: CGFloat = 18

    private var isInteractivelyDragging: Bool {
        isExternalDragging || collapseDragActive
    }

    private func effectiveProgress(containerHeight: CGFloat) -> CGFloat {
        // Prefer binding `progress` (updated live during collapse) so finger and paint stay in lockstep.
        _ = containerHeight
        return PlayerTransitionMetrics.clamp(progress)
    }

    /// Shorter than open distance so the first pixels of a dismiss swipe produce visible motion.
    private func collapseDistance(containerHeight: CGFloat) -> CGFloat {
        max(containerHeight * 0.42, 240)
    }

    var body: some View {
        GeometryReader { geo in
            let topSafe = max(geo.safeAreaInsets.top, 54)
            let bottomSafe = max(geo.safeAreaInsets.bottom, 12)
            let h = geo.size.height
            let w = geo.size.width
            let usableH = h - topSafe - bottomSafe
            let chromeBelowArt: CGFloat = 96 + 58 + 74 + 64
            let artFromBudget = max(220, usableH - chromeBelowArt - 48)
            let artSide = min(w - 40, artFromBudget, usableH * 0.48, 380)

            let p = effectiveProgress(containerHeight: h)
            let overlayGlobal = geo.frame(in: .global)

            let fullArtRect = CGRect(
                x: (w - artSide) / 2,
                y: min(topSafe + max(12, usableH * 0.05) + 100, h * 0.22),
                width: artSide,
                height: artSide
            )

            let miniLocal: CGRect = {
                guard miniArtGlobalFrame.width > 1 else {
                    return CGRect(x: 22, y: h - 120, width: 42, height: 42)
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
            let artGrowth: CGFloat = {
                if reduceMotion { return M.clamp(p) }
                if interactiveCollapse { return M.clamp(p) } // linear with finger
                return M.smoothstep(0, M.heroGrowthEnd, p)
            }()
            let metaT = reduceMotion ? M.smoothstep(0.15, 0.55, p) : M.smoothstep(M.metaStart, M.metaEnd, p)
            let scrubT = reduceMotion ? M.smoothstep(0.30, 0.70, p) : M.smoothstep(M.scrubberStart, M.scrubberEnd, p)
            let transportT = reduceMotion ? M.smoothstep(0.40, 0.80, p) : M.smoothstep(M.transportStart, M.transportEnd, p)
            let bottomT = reduceMotion ? M.smoothstep(0.50, 0.95, p) : M.smoothstep(M.bottomActionsStart, M.bottomActionsEnd, p)

            let currentArt = lerpRect(miniLocal, fullArtRect, artGrowth)
            let artCorner = 12 + (22 - 12) * artGrowth

            // Linear lift with progress so dismiss responds on the first pixels
            // (smoothstep plateaus near p=1 felt like a dead zone / delay).
            let sheetLift: CGFloat = {
                if reduceMotion { return (1 - p) * 28 }
                // Match collapseDistance so finger dy maps ~1:1 while dragging down.
                let travel = collapseDistance(containerHeight: h)
                return (1 - p) * travel
            }()
            let sheetScale: CGFloat = reduceMotion ? 1 : (0.985 + 0.015 * M.smoothstep(0.2, 1, p))
            let playScale: CGFloat = 0.96 + 0.04 * transportT

            ZStack {
                // Dynamic artwork blur stack: palette gradient → Material → scrim.
                // No per-frame palette work; no live large-image Gaussian path.
                playerDynamicBackground
                    .frame(width: w, height: h)
                    .opacity(Double(max(washT, scrimT * 0.85)))
                    .allowsHitTesting(false)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: artworkVisuals.trackID)

                // Hero artwork (primary anchor).
                heroArtwork(side: max(currentArt.width, 1))
                    .frame(width: currentArt.width, height: currentArt.height)
                    .clipShape(RoundedRectangle(cornerRadius: artCorner, style: .continuous))
                    .shadow(
                        color: artworkVisuals.tintDeep.opacity(0.45 * Double(artGrowth)),
                        radius: 10 + 14 * artGrowth,
                        y: 5 + 7 * artGrowth
                    )
                    .position(x: currentArt.midX, y: currentArt.midY)
                    .opacity(Double(max(washT, artGrowth)))
                    .allowsHitTesting(false)

                // Expanded chrome (staged).
                VStack(spacing: 0) {
                    dismissGrabChrome
                        .padding(.top, topSafe)
                        .opacity(Double(max(metaT, M.smoothstep(0.15, 0.45, p))))

                    Spacer(minLength: max(12, usableH * 0.05))

                    Color.clear
                        .frame(width: artSide, height: artSide)
                        .frame(maxWidth: .infinity)

                    VStack(spacing: 5) {
                        Text(player.currentTrack?.title ?? "Nothing Playing")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)

                        Text(player.currentTrack?.artist ?? "")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)

                        if let album = player.currentTrack?.album, !album.isEmpty {
                            Text(album)
                                .font(.system(size: 13, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(0.48))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                    .opacity(Double(metaT))
                    .offset(y: (1 - metaT) * (reduceMotion ? 6 : 12))

                    Spacer(minLength: 10)

                    PlayerProgressScrubber(
                        isInteractive: p >= M.interactiveControlsThreshold && !isInteractivelyDragging,
                        isCollapseDragging: collapseDragActive
                    )
                    .padding(.horizontal, 28)
                    .opacity(Double(scrubT))
                    .offset(y: (1 - scrubT) * (reduceMotion ? 4 : 10))
                    .allowsHitTesting(scrubT > 0.9 && !isInteractivelyDragging)

                    transportRow(playScale: playScale)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .opacity(Double(transportT))
                        .offset(y: (1 - transportT) * (reduceMotion ? 4 : 12))
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
                    .padding(.horizontal, 28)
                    .padding(.top, 14)
                    .padding(.bottom, bottomSafe + 16)
                    .opacity(Double(bottomT))
                    .offset(y: (1 - bottomT) * (reduceMotion ? 4 : 10))
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
        HStack(spacing: 0) {
            Button { player.cycleShuffleMode() } label: {
                Image(systemName: player.shuffleMode.iconName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(player.shuffleMode == .off ? .white.opacity(0.38) : theme.accent)
                    .symbolVariant(player.shuffleMode == .banger ? .fill : .none)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .accessibilityLabel("Shuffle \(player.shuffleMode.rawValue)")

            Button { player.skipBackward() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .accessibilityLabel("Previous track")

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.accent)
                    .frame(width: 76, height: 76)
                    .scaleEffect(playScale)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button { player.skipForward() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .accessibilityLabel("Next track")

            Button { player.cycleRepeatMode() } label: {
                Image(systemName: player.repeatMode.iconName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.38) : theme.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
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
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
    }

    /// Album colors softly filling the room — not a charcoal slab.
    /// A base → multi-color glows → optional light frost → bottom-only readability.
    private var playerDynamicBackground: some View {
        let hasArt = artworkVisuals.hasArtwork && !artworkVisuals.dominantColors.isEmpty
        let c = artworkVisuals.gradientStops(maxStops: 5)
        let c0 = c.indices.contains(0) ? c[0] : Color.clear
        let c1 = c.indices.contains(1) ? c[1] : c0
        let c2 = c.indices.contains(2) ? c[2] : c1
        let c3 = c.indices.contains(3) ? c[3] : c2
        let isDarkScheme = scheme == .dark
        // Bias: protect lower third for white text; leave upper/mid color-rich.
        let scrimPeak: Double = {
            if !hasArt { return 0 }
            if reduceTransparency { return isDarkScheme ? 0.48 : 0.32 }
            return artworkVisuals.isDarkArtwork
                ? (isDarkScheme ? 0.20 : 0.16)
                : (isDarkScheme ? 0.28 : 0.22)
        }()
        let materialOpacity: Double = {
            if reduceTransparency { return 0 }
            // Very light frost — depth without killing album chroma.
            return isDarkScheme ? 0.18 : 0.22
        }()

        return GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                // A) True near-black matte base (not gray charcoal)
                Color.black
                    .ignoresSafeArea()

                if hasArt {
                    // B1) Primary atmospheric radial — largest glow behind cover / upper field
                    RadialGradient(
                        colors: [
                            c0.opacity(0.95),
                            c0.opacity(0.58),
                            c1.opacity(0.32),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.5, y: 0.26),
                        startRadius: 24,
                        endRadius: max(h * 0.72, 420)
                    )
                    .ignoresSafeArea()
                    .scaleEffect(x: 1.2, y: 1.08, anchor: .center)

                    // B2) Secondary soft bloom (second dominant hue)
                    RadialGradient(
                        colors: [
                            c1.opacity(0.78),
                            c2.opacity(0.30),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.08, y: 0.52),
                        startRadius: 12,
                        endRadius: max(h * 0.55, 320)
                    )
                    .ignoresSafeArea()
                    .blendMode(.plusLighter)

                    // B3) Tertiary bloom (third/fourth hue — multi-color covers stay alive)
                    RadialGradient(
                        colors: [
                            c2.opacity(0.62),
                            c3.opacity(0.22),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.94, y: 0.18),
                        startRadius: 10,
                        endRadius: max(h * 0.48, 280)
                    )
                    .ignoresSafeArea()
                    .blendMode(.plusLighter)

                    // B4) Soft multi-stop wash — distinct real hues as stops
                    LinearGradient(
                        colors: gradientColorList(c).map { $0.opacity(0.78) },
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                    .blendMode(.plusLighter)
                    .opacity(0.55)

                    // C) Very light frost only — do NOT charcoal the room
                    if reduceTransparency {
                        Color.black.opacity(isDarkScheme ? 0.26 : 0.12)
                            .ignoresSafeArea()
                    } else if materialOpacity > 0 {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .opacity(materialOpacity)
                            .ignoresSafeArea()
                    }

                    // D) Lower-third readability only — upper/mid stays color-rich
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.black.opacity(scrimPeak * 0.28),
                                Color.black.opacity(scrimPeak * 0.70),
                                Color.black.opacity(scrimPeak)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: h * 0.36)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
            }
        }
    }

    /// Expand 1–N real colors into smooth gradient stops (preserve each hue).
    private func gradientColorList(_ stops: [Color]) -> [Color] {
        switch stops.count {
        case 0:
            return [.black]
        case 1:
            return [stops[0], stops[0].opacity(0.9), stops[0].opacity(0.7)]
        case 2:
            return [stops[0], stops[1], stops[1].opacity(0.85)]
        case 3:
            return [stops[0], stops[1], stops[2], stops[2].opacity(0.9)]
        default:
            return Array(stops.prefix(5))
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
                .fill(.white.opacity(0.55))
                .frame(width: 48, height: 5)
                .padding(.top, 8)

            HStack {
                Button {
                    collapseThen(nil)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 44, height: 44)
                        .background {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .environment(\.colorScheme, .dark)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close player")
                .disabled(showQueue)

                Spacer()

                if player.crossfade.isEnabled {
                    Text("Crossfade \(player.crossfade.durationSeconds)s")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .environment(\.colorScheme, .dark)
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7))
                        }
                }
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 100)
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
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundStyle(.white)
                .background {
                    RoundedRectangle(cornerRadius: controlCorner, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                        .overlay {
                            RoundedRectangle(cornerRadius: controlCorner, style: .continuous)
                                .fill(emphasized ? theme.accent.opacity(0.42) : Color.white.opacity(0.08))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: controlCorner, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.38),
                                            Color.white.opacity(0.08)
                                        ],
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
