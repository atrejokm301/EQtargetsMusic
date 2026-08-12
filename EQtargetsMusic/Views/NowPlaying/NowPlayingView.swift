//
//  NowPlayingView.swift
//  EQtargetsMusic
//

import SwiftUI
import UniformTypeIdentifiers

struct NowPlayingView: View {
    @EnvironmentObject private var player: AudioPlayerEngine
    @EnvironmentObject private var presetStore: EQPresetStore
    @Environment(\.grokTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    @State private var showImporter = false
    @State private var showSystemWideInfo = false
    @State private var showAutoMixSheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                systemWideBanner

                // Hero — track metadata only (does not tick with progress).
                NowPlayingHeroCard()

                // Transport owns progress ticks so EQ Menus don’t rebuild while playing.
                NowPlayingTransportCard()

                // EQ — isolated; must not sit under progressSubject updates.
                EQControlsView(
                    dual: $player.dual,
                    bass: $player.bass,
                    limiter: $player.limiter,
                    onImportAutoEQ: { showImporter = true },
                    onToast: { player.showToast($0) }
                )
                .padding(16)
                .glassCard(corner: 20)

                // Empty runway: scroll Limiter / Bass fully above the mini into open space.
                Color.clear
                    .frame(height: player.currentTrack != nil ? 180 : 72)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.visible)
        .miniPlayerScrollRunway(hasTrack: player.currentTrack != nil)
        .grokScrollEdgeBlur()
        .background { LiquidGlassBackground() }
        .grokStyleNavigationChrome(title: "Now Playing") {
            Button {
                showAutoMixSheet = true
            } label: {
                Image(systemName: "shuffle.circle")
                    .font(.app(size: 16, weight: .bold))
                    .foregroundStyle(player.crossfade.isEnabled ? theme.accent : theme.secondaryText)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Crossfade settings")
        }
        .sheet(isPresented: $showAutoMixSheet) {
            AutoMixSettingsSheet()
                .environmentObject(player)
                .environment(\.grokTheme, theme)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.plainText, .utf8PlainText, .text],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert("System-wide EQ on iOS", isPresented: $showSystemWideInfo) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("Apple does not allow third-party apps to equalize YouTube, Music, Netflix, or other apps. EQtargets Music applies Target + Fine-Tune + Bass Style + Limiter only to audio played inside this app.")
        }
        // Toast is rendered globally from RootTabView so library actions are visible too.
    }

    private var systemWideBanner: some View {
        Button {
            showSystemWideInfo = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(theme.accent)
                Text("EQ applies to in-app playback only (not system-wide)")
                    .font(.app(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.app(size: 11, weight: .semibold))
                    .foregroundStyle(theme.tertiaryText)
            }
            .padding(12)
            .glassCard(corner: 14)
        }
        .buttonStyle(.plain)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            player.showToast(err.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            // Document picker URLs are security-scoped; sandbox-internal paths are not.
            let access = SecurityScopedAccess.startIfNeeded(url)
            defer { SecurityScopedAccess.stopIfNeeded(url, didStart: access) }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let layer = try AutoEQParser.parse(text: text)
                player.dual.loadTarget(layer, keepFineTune: true)
                // Save into the shared store so the Target menu updates immediately.
                let baseName = url.deletingPathExtension().lastPathComponent
                let name = baseName.isEmpty ? "Imported Target" : baseName
                presetStore.saveTargetPreset(name: name, layer: layer)
                player.showToast("Target “\(name)” loaded")
            } catch {
                player.showToast(error.localizedDescription)
            }
        }
    }
}

// MARK: - Hero (track only — no progress ticks)

private struct NowPlayingHeroCard: View {
    @EnvironmentObject private var player: AudioPlayerEngine
    @Environment(\.grokTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            artwork
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 6) {
                Text(player.currentTrack?.title ?? "Nothing Playing")
                    .font(.app(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                Text(player.currentTrack?.artist ?? "Select a track from Music")
                    .font(.app(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                Text(player.currentTrack?.album ?? "")
                    .font(.app(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassCard(corner: 20)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.width < -50 {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        player.skipForward()
                    } else if value.translation.width > 50 {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        player.skipBackward()
                    }
                }
        )
    }

    @ViewBuilder
    private var artwork: some View {
        if let data = player.currentTrack?.artworkData, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [theme.accent.opacity(0.4), theme.accentSecondary.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note")
                    .font(.app(size: 36, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

// MARK: - Transport (owns progress ticks so EQ Menus stay stable while playing)

private struct NowPlayingTransportCard: View {
    @EnvironmentObject private var player: AudioPlayerEngine
    @Environment(\.grokTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            // Shared waveform scrubber (same as full player) — times stay under the bars.
            PlayerProgressScrubber(
                isInteractive: true,
                isCollapseDragging: false,
                chrome: .nowPlaying
            )

            HStack(spacing: 24) {
                Button { player.cycleShuffleMode() } label: {
                    Image(systemName: player.shuffleMode.iconName)
                        .font(.app(size: 20, weight: .semibold))
                        .foregroundStyle(player.shuffleMode == .off ? theme.tertiaryText : theme.accent)
                        .symbolVariant(player.shuffleMode == .banger ? .fill : .none)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Shuffle \(player.shuffleMode.rawValue)")

                Button { player.skipBackward() } label: {
                    Image(systemName: "backward.fill").font(.app(size: 24))
                }
                .frame(minWidth: 44, minHeight: 44)

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.app(size: 60))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(theme.accent)
                }
                .frame(minWidth: 60, minHeight: 60)

                Button { player.skipForward() } label: {
                    Image(systemName: "forward.fill").font(.app(size: 24))
                }
                .frame(minWidth: 44, minHeight: 44)

                Button { player.cycleRepeatMode() } label: {
                    Image(systemName: player.repeatMode.iconName)
                        .font(.app(size: 20, weight: .semibold))
                        .foregroundStyle(player.repeatMode == .off ? theme.tertiaryText : theme.accent)
                        .opacity(player.repeatMode == .off ? 0.55 : 1)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Repeat \(player.repeatMode.rawValue)")
            }
            .foregroundStyle(theme.primaryText)
        }
        .padding(16)
        .glassCard(corner: 20)
    }
}

/// Minimal Crossfade settings — not beat-matched AutoMix.
struct AutoMixSettingsSheet: View {
    @EnvironmentObject private var player: AudioPlayerEngine
    @Environment(\.grokTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    private var durationLabel: String {
        let s = player.crossfade.durationSeconds
        return s == 0 ? "Off" : "\(s)s"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Crossfade")
                            .font(.app(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                            .accessibilityAddTraits(.isHeader)
                        Text("Plays the end of the current song and the start of the next song at the same time, blending volumes. Works on Next and when a song ends on its own. Not beat-matched DJ AutoMix (no tempo warp).")
                            .font(.app(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(corner: 16)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Blend length")
                                .font(.app(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                            Spacer()
                            Text(durationLabel)
                                .font(.app(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.accent)
                                .monospacedDigit()
                                .accessibilityLabel(durationLabel)
                        }
                        Text("How long both songs overlap. Drag for any length 0–60s (1s steps). Off = hard cut.")
                            .font(.app(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        // Continuous slider — more granular than the old preset grid.
                        Slider(
                            value: Binding(
                                get: { Double(player.crossfade.durationSeconds) },
                                set: { player.crossfade = player.crossfade.withDurationSeconds(Int($0.rounded())) }
                            ),
                            in: 0 ... Double(CrossfadeSettings.maxSeconds),
                            step: 1
                        )
                        .tint(theme.accent)
                        .accessibilityLabel("Blend length")
                        .accessibilityValue(durationLabel)

                        HStack {
                            Text("Off")
                            Spacer()
                            Text("30s")
                            Spacer()
                            Text("60s")
                        }
                        .font(.app(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.tertiaryText)

                        // Quick jumps (optional); slider is the main control.
                        HStack(spacing: 8) {
                            ForEach([0, 10, 20, 30, 45, 60], id: \.self) { seconds in
                                let selected = player.crossfade.durationSeconds == seconds
                                Button {
                                    player.crossfade = player.crossfade.withDurationSeconds(seconds)
                                } label: {
                                    Text(seconds == 0 ? "Off" : "\(seconds)")
                                        .font(.app(size: 13, weight: .semibold, design: .rounded))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .foregroundStyle(selected ? Color.white : theme.primaryText)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(selected ? theme.accent : theme.elevated)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(seconds == 0 ? "Crossfade off" : "Crossfade \(seconds) seconds")
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                    }
                    .padding(14)
                    .glassCard(corner: 16)

                    // Curve + adaptive (volume crossfade only — not beat-match)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Blend curve")
                            .font(.app(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text("Shape of the volume swap while both tracks play.")
                            .font(.app(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.secondaryText)

                        HStack(spacing: 8) {
                            ForEach(CrossfadeCurve.allCases) { curve in
                                let selected = player.crossfade.curve == curve
                                Button {
                                    var s = player.crossfade
                                    s.curve = curve
                                    player.crossfade = s
                                } label: {
                                    Text(curve.title)
                                        .font(.app(size: 13, weight: .bold, design: .rounded))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .foregroundStyle(selected ? Color.white : theme.primaryText)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(selected ? theme.accent : theme.elevated)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Fade curve \(curve.title)")
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }

                        // What the next transition will actually do. Shown only when it
                        // differs from the request — caps, adaptive tempo, or the
                        // long-fade curve substitution.
                        if player.crossfade.isEnabled {
                            let plan = player.upcomingCrossfadePlan
                            if let adjusted = plan.adjustmentSummary {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "info.circle.fill")
                                        .font(.app(size: 12, weight: .semibold))
                                        .foregroundStyle(theme.accentSecondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Next blend: \(adjusted)")
                                            .font(.app(size: 12, weight: .semibold, design: .rounded))
                                            .foregroundStyle(theme.primaryText)
                                        if let reason = plan.adjustmentReason {
                                            Text(reason)
                                                .font(.app(size: 11, weight: .medium, design: .rounded))
                                                .foregroundStyle(theme.secondaryText)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(theme.elevated)
                                )
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(
                                    "Next blend \(adjusted)"
                                        + (plan.adjustmentReason.map { ", \($0)" } ?? "")
                                )
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            curveHelpRow(title: "Equal Power", body: "Default. Constant loudness through the middle of the blend (cos/sin). Best everyday choice.")
                            curveHelpRow(title: "Smooth", body: "Softer start and end of the fade. Nice on long overlaps (15–60s). Auto-used for long Equal Power fades.")
                            curveHelpRow(title: "Linear", body: "Straight volume swap. Can sound slightly quieter in the middle. Useful to compare curves.")
                        }

                        Toggle(isOn: Binding(
                            get: { player.crossfade.adaptiveBPM },
                            set: { on in
                                var s = player.crossfade
                                s.adaptiveBPM = on
                                player.crossfade = s
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Smart tempo blend")
                                    .font(.app(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(theme.primaryText)
                                Text("Shortens the blend when energy clashes (e.g. Adoración → Júbilo) or felt BPMs are far apart. Uses tempo lanes, not half/double tricks. Off = always use the Duration you set (still track-length capped).")
                                    .font(.app(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .tint(theme.accent)

                        Toggle(isOn: Binding(
                            get: { player.crossfade.skipSilence },
                            set: { on in
                                var s = player.crossfade
                                s.skipSilence = on
                                player.crossfade = s
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Skip silence (alabanzas / live)")
                                    .font(.app(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundStyle(theme.primaryText)
                                Text("v2: adaptive noise floor finds where music really starts/ends. Skips long intros (talking, room tone) and trims trailing applause only when there’s real quiet at the end — ideal for live worship. Crossfade arms on the trimmed end.")
                                    .font(.app(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .tint(theme.accent)
                    }
                    .padding(14)
                    .glassCard(corner: 16)

                    // Smart BPM Shuffle — queue selection only (does not change crossfade audio).
                    SmartBPMShuffleSettingsCard()

                    Text("Two independent EQ decks keep Target + Fine-Tune correct while songs overlap. No time-stretch — both tracks play at real speed. Caps: ~75% of current playable length, ~70% of next, and never longer than time left if you skip late.")
                        .font(.app(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                .padding(16)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.visible)
            .background(Color.clear)
            .navigationTitle("Crossfade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.app(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accent)
                        .accessibilityLabel("Done")
                }
            }
        }
        .frostedBleedSheet(accent: theme.accent)
    }

    private func curveHelpRow(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.app(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text(body)
                .font(.app(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Toggle + copy for Smart BPM Shuffle (selection only; no audio-graph control).
private struct SmartBPMShuffleSettingsCard: View {
    @Environment(\.grokTheme) private var theme
    @AppStorage(SmartShuffleSelector.enabledDefaultsKey) private var smartBPMShuffleEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Smart Tempo Up Next")
                .font(.app(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)

            Toggle(isOn: $smartBPMShuffleEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep the same worship energy")
                        .font(.app(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("When Up Next is empty, picks one library track in the same tempo lane: Adoración (slow), Mid, or Júbilo (upbeat praise). Uses felt BPM — not half/double matching — so slow worship doesn’t jump into fast alabanza. Manual queue always wins.")
                        .font(.app(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(theme.accent)
            .accessibilityLabel("Smart Tempo Up Next")
            .accessibilityHint("When enabled, automatically adds a same-energy next track if Up Next is empty")

            if smartBPMShuffleEnabled {
                TempoLaneThresholdsEditor()
            }
        }
        .padding(14)
        .glassCard(corner: 16)
    }
}
