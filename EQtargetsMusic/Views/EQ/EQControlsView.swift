//
//  EQControlsView.swift
//  EQtargetsMusic
//
//  Now Playing: EQGraphView stays here + entry to the frosted EQ editor sheet.
//  Detailed controls (profiles, segment, preamp, 10 vertical bands) live in EQEditorSheet.
//  Dual EQ chain: Target → Fine-Tune. Bass Processor is a separate post stage (Wavelet-style).
//

import SwiftUI
import AVFoundation

// MARK: - Now Playing surface (graph stays put)

struct EQControlsView: View {
    @Binding var dual: DualEQState
    @Binding var bass: BassProcessorState
    var onImportAutoEQ: () -> Void
    /// Optional toast when assigning devices (wired from Now Playing / player).
    var onToast: ((String) -> Void)? = nil

    @Environment(\.grokTheme) private var theme
    @EnvironmentObject private var presetStore: EQPresetStore

    @State private var showEQEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Compact profile readout + open editor
            HStack(spacing: 8) {
                legendDot(theme.targetTint, presetStore.selectedTargetName)
                legendDot(theme.accent, presetStore.selectedFineTuneName)
                Spacer(minLength: 4)
                if dual.isBypassed {
                    Text("Bypassed")
                        .font(.app(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.danger)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.danger.opacity(0.14)))
                }
            }

            // Graph stays exactly on Now Playing — not moved into the sheet.
            // Graph shows Target + Fine-Tune only (Bass is post-PEQ, not drawn here).
            EQGraphView(dual: dual)

            Button {
                showEQEditor = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.vertical.3")
                        .font(.app(size: 16, weight: .semibold))
                        .foregroundStyle(theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("EQ Controls")
                            .font(.app(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text("Profiles, preamp & 10 bands")
                            .font(.app(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up")
                        .font(.app(size: 12, weight: .bold))
                        .foregroundStyle(theme.tertiaryText)
                }
                .padding(14)
                .glassCard(corner: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open EQ controls")
            .accessibilityHint("Opens Target and Fine-Tune band editor")

            // Independent Bass stage — never writes into Target / Fine-Tune.
            BassStyleControlsView(bass: $bass)
        }
        .sheet(isPresented: $showEQEditor) {
            EQEditorSheet(
                dual: $dual,
                onImportAutoEQ: {
                    showEQEditor = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        onImportAutoEQ()
                    }
                },
                onToast: onToast
            )
            .environmentObject(presetStore)
            .environment(\.grokTheme, theme)
        }
    }

    private func legendDot(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 12, height: 3)
            Text(title)
                .font(.app(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
    }
}

// MARK: - Bass Style (post-PEQ effect — separate from Fine-Tune)

/// Controls for the independent Bass Processor.
/// Binds only `BassProcessorState` — never touches DualEQState / Target / Fine-Tune.
struct BassStyleControlsView: View {
    @Binding var bass: BassProcessorState
    @Environment(\.grokTheme) private var theme

    /// Distinct accent so Bass reads as an *effect*, not another EQ layer.
    private var bassTint: Color { theme.accentSecondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header — clear hierarchy: effect name + “after PEQ” badge
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(bassTint.opacity(theme.isDark ? 0.18 : 0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: "speaker.wave.2.bubble.left.fill")
                        .font(.app(size: 16, weight: .semibold))
                        .foregroundStyle(bassTint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Bass Style")
                            .font(.app(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text("EFFECT")
                            .font(.app(size: 9, weight: .heavy, design: .rounded))
                            .foregroundStyle(bassTint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(bassTint.opacity(0.16)))
                    }
                    Text("Runs after Target + Fine-Tune · never edits AutoEQ")
                        .font(.app(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            // Style chips — one row; None = icon only; snaps recommended Hz
            HStack(spacing: 6) {
                ForEach(BassStyle.allCases) { style in
                    let selected = bass.style == style
                    Button {
                        var next = bass
                        next.selectStyle(style, applyRecommendedCutoff: true)
                        bass = next
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: style.systemImage)
                                .font(.app(size: 11, weight: .semibold))
                            if !style.compactTitle.isEmpty {
                                Text(style.compactTitle)
                                    .font(.app(size: 11, weight: .semibold, design: .rounded))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(selected ? theme.background : theme.primaryText)
                        .padding(.horizontal, style == .none ? 8 : 6)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(selected ? bassTint : theme.elevated)
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    selected ? Color.clear : theme.primaryText.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            if bass.style != .none {
                // Active style readout
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.app(size: 12, weight: .semibold))
                        .foregroundStyle(bassTint)
                    Text(bass.style.title)
                        .font(.app(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("·")
                        .foregroundStyle(theme.tertiaryText)
                    Text(bass.style.subtitle)
                        .font(.app(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }

                VStack(spacing: 12) {
                    bassSlider(
                        title: "Strength",
                        value: Binding(
                            get: { bass.strength },
                            set: { v in
                                var n = bass
                                n.strength = v
                                n.sanitize()
                                bass = n
                            }
                        ),
                        range: BassProcessorState.strengthRange,
                        format: { String(format: "%.0f%%", $0 * 100) },
                        tint: bassTint
                    )

                    bassSlider(
                        title: bass.cutoffMatchesStyleRecommendation
                            ? "Cutoff · recommended"
                            : "Cutoff",
                        value: Binding(
                            get: { bass.cutoff },
                            set: { v in
                                var n = bass
                                n.cutoff = v
                                n.sanitize()
                                bass = n
                            }
                        ),
                        range: BassProcessorState.cutoffRange,
                        format: { String(format: "%.0f Hz", $0) },
                        tint: bassTint
                    )

                    bassSlider(
                        title: "Post gain",
                        value: Binding(
                            get: { bass.postGain },
                            set: { v in
                                var n = bass
                                n.postGain = v
                                n.sanitize()
                                bass = n
                            }
                        ),
                        range: BassProcessorState.postGainRange,
                        format: { String(format: "%+.1f dB", $0) },
                        tint: bassTint
                    )
                }
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(theme.isDark ? Color.black.opacity(0.22) : Color.white.opacity(0.28))
                }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.isDark ? Color.white.opacity(0.05) : Color.white.opacity(0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    bassTint.opacity(theme.isDark ? 0.45 : 0.35),
                                    Color.white.opacity(theme.isDark ? 0.08 : 0.25)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bass Style effect")
        .accessibilityHint("Independent processor after Target and Fine-Tune")
    }

    private func bassSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.app(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.app(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
                .tint(tint)
        }
    }
}

// MARK: - Frosted EQ editor sheet

struct EQEditorSheet: View {
    @Binding var dual: DualEQState
    var onImportAutoEQ: () -> Void
    var onToast: ((String) -> Void)? = nil

    @Environment(\.grokTheme) private var theme
    @EnvironmentObject private var presetStore: EQPresetStore
    @Environment(\.dismiss) private var dismiss

    @State private var showSaveTargetAlert = false
    @State private var newTargetName = ""
    @State private var showSaveFineTuneAlert = false
    @State private var newFineTuneName = ""
    @State private var showDeviceLinksSheet = false
    @State private var showFineTunePickerSheet = false
    @State private var showTargetPickerSheet = false

    /// Controls (sliders / toggles) always follow the user’s accent theme.
    /// Target vs Fine-Tune distinction stays on the segment + profile chips only — not pumpkin orange.
    private var controlTint: Color {
        theme.accent
    }

    /// Soft identity for the active layer chip / preamp label (Target = cool, Fine-Tune = accent).
    private var layerIdentityTint: Color {
        dual.editingLayer == .target ? theme.targetTint : theme.accent
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    profileHeaderCard
                    liquidGlassSegmentedSwitch
                    preampCard
                    bandsSection
                    utilityRow
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.visible)
            .background(Color.clear)
            .navigationTitle("EQ Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.app(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accent)
                }
            }
        }
        // Slightly shorter default than full medium — content is denser now.
        .frostedBleedSheet(accent: theme.accent)
        .presentationDetents([.fraction(0.55), .large])
        .presentationContentInteraction(.scrolls)
        .alert("Save Target Curve", isPresented: $showSaveTargetAlert) {
            TextField("Target Curve Name", text: $newTargetName)
            Button("Cancel", role: .cancel) {}
            Button("Save Target") {
                presetStore.saveTargetPreset(name: newTargetName, layer: dual.target)
            }
        } message: {
            Text("Enter a name for this target curve profile.")
        }
        .alert("Save Fine-Tune Preset", isPresented: $showSaveFineTuneAlert) {
            TextField("Fine-Tune Name", text: $newFineTuneName)
            Button("Cancel", role: .cancel) {}
            Button("Save Fine-Tune") {
                presetStore.saveFineTunePreset(name: newFineTuneName, layer: dual.fineTune)
            }
        } message: {
            Text("Enter a name for your custom fine-tune adjustment curve.")
        }
        .sheet(isPresented: $showDeviceLinksSheet) {
            TargetDeviceLinksSheet(
                dual: $dual,
                onToast: onToast
            )
            .environmentObject(presetStore)
            .environment(\.grokTheme, theme)
        }
        .sheet(isPresented: $showTargetPickerSheet) {
            ProfilePickerSheet(
                title: "Target curves",
                accent: theme.targetTint,
                presets: presetStore.targetPresets,
                selectedName: presetStore.selectedTargetName,
                onSelect: { preset in
                    dual.target = preset.layer
                    presetStore.selectedTargetName = preset.name
                },
                onDelete: { preset in
                    presetStore.deleteTargetPreset(preset)
                },
                onImport: {
                    showTargetPickerSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        onImportAutoEQ()
                    }
                },
                onLinkDevices: {
                    showTargetPickerSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showDeviceLinksSheet = true
                    }
                }
            )
            .environment(\.grokTheme, theme)
        }
        .sheet(isPresented: $showFineTunePickerSheet) {
            ProfilePickerSheet(
                title: "Fine-Tune profiles",
                accent: theme.fineTint,
                presets: presetStore.fineTunePresets,
                selectedName: presetStore.selectedFineTuneName,
                onSelect: { preset in
                    dual.fineTune = preset.layer
                    presetStore.selectedFineTuneName = preset.name
                },
                onDelete: { preset in
                    presetStore.deleteFineTunePreset(preset)
                },
                onImport: nil,
                onLinkDevices: nil
            )
            .environment(\.grokTheme, theme)
        }
    }

    // MARK: - Profile header

    private var profileHeaderCard: some View {
        VStack(spacing: 6) {
            // Target
            HStack(spacing: 6) {
                legendDot(theme.targetTint, "Target")

                Button {
                    showTargetPickerSheet = true
                } label: {
                    HStack(spacing: 3) {
                        Text(presetStore.selectedTargetName)
                            .font(.app(size: 11, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.app(size: 9, weight: .bold))
                    }
                    .foregroundStyle(theme.targetTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.targetTint.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Target profile")

                Spacer(minLength: 4)

                Button {
                    showDeviceLinksSheet = true
                } label: {
                    Image(systemName: "link")
                        .font(.app(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(theme.targetTint)
                .accessibilityLabel("Link Target to devices")

                Button(action: onImportAutoEQ) {
                    Image(systemName: "doc.badge.plus")
                        .font(.app(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(theme.targetTint)
                .accessibilityLabel("Import AutoEQ")

                Button {
                    newTargetName = presetStore.selectedTargetName
                    showSaveTargetAlert = true
                } label: {
                    Text("Save")
                        .font(.app(size: 10, weight: .bold, design: .rounded))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(theme.targetTint)
            }

            // Fine-Tune
            HStack(spacing: 6) {
                legendDot(theme.accent, "Fine-Tune")

                Button {
                    showFineTunePickerSheet = true
                } label: {
                    HStack(spacing: 3) {
                        Text(presetStore.selectedFineTuneName)
                            .font(.app(size: 11, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.app(size: 9, weight: .bold))
                    }
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.accent.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Fine-Tune profile")

                Spacer(minLength: 4)

                Button {
                    newFineTuneName = presetStore.selectedFineTuneName
                    showSaveFineTuneAlert = true
                } label: {
                    Text("Save")
                        .font(.app(size: 10, weight: .bold, design: .rounded))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(theme.accent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassCard(corner: 14)
    }

    // MARK: - Segmented switch

    private var liquidGlassSegmentedSwitch: some View {
        HStack(spacing: 3) {
            switchPillSegment(.target, title: "Target Curve", subtitle: "Compensation", tint: theme.targetTint)
            // Fine-Tune uses app accent — not the old hard-coded orange.
            switchPillSegment(.fineTune, title: "Fine-Tune Adjust", subtitle: "Personal EQ", tint: theme.accent)
        }
        .padding(3)
        .background {
            Capsule()
                .fill(theme.isDark ? Color.white.opacity(0.04) : Color.clear)
                .background {
                    if !theme.isDark {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
                .overlay {
                    Capsule().fill(theme.cardFill)
                }
                .overlay {
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(theme.isDark ? 0.12 : 0.60), .white.opacity(0.04)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.6
                        )
                }
        }
        .shadow(color: .black.opacity(theme.isDark ? 0.16 : 0.06), radius: theme.isDark ? 4 : 6, y: 2)
    }

    private func switchPillSegment(_ layer: EQLayer, title: String, subtitle: String, tint: Color) -> some View {
        let isSelected = dual.editingLayer == layer
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                dual.editingLayer = layer
            }
        } label: {
            VStack(spacing: 1) {
                Text(title)
                    .font(.app(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? tint : theme.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(subtitle)
                    .font(.app(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? tint.opacity(0.85) : theme.tertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    Capsule()
                        .fill(tint.opacity(0.20))
                        .overlay {
                            Capsule().strokeBorder(tint.opacity(0.40), lineWidth: 0.9)
                        }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preamp

    private var preampCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(dual.editingLayer.title) Preamp")
                    .font(.app(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 4)
                Text(String(format: "%+.1f dB", dual.activeLayer.preamp))
                    .font(.app(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(controlTint)
            }
            Slider(
                value: Binding(
                    get: { dual.activeLayer.preamp },
                    set: { v in
                        var layer = dual.activeLayer
                        layer.preamp = v
                        dual.activeLayer = layer
                    }
                ),
                in: EQLayerState.preampRange
            )
            .controlSize(.small)
            .tint(controlTint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background { modernEQSurface(corner: 16) }
    }

    // MARK: - Vertical bands

    private var bandsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("10 bands")
                    .font(.app(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Text("·")
                    .foregroundStyle(theme.tertiaryText)
                Text("Peak · Low Shelf · High Shelf")
                    .font(.app(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.tertiaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)

            ForEach(Array(dual.activeLayer.bands.indices), id: \.self) { i in
                EQBandVerticalRow(
                    index: i,
                    band: dual.activeLayer.bands[i],
                    tint: controlTint,
                    onUpdate: { mutate in
                        var layer = dual.activeLayer
                        mutate(&layer.bands[i])
                        layer.bands[i].sanitize()
                        dual.activeLayer = layer
                    }
                )
            }
        }
    }

    private var utilityRow: some View {
        HStack(spacing: 6) {
            Button {
                dual.isBypassed.toggle()
            } label: {
                Label(
                    dual.isBypassed ? "Bypassed" : "EQ Active",
                    systemImage: dual.isBypassed ? "speaker.slash" : "waveform"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(dual.isBypassed ? theme.danger : theme.accent)

            Button {
                dual.resetFineTune()
            } label: {
                Label("Reset FT", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(theme.accent)

            Spacer(minLength: 0)
        }
        .font(.app(size: 11, weight: .semibold, design: .rounded))
    }

    private func legendDot(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 3) {
            Capsule().fill(color).frame(width: 10, height: 2.5)
            Text(title)
                .font(.app(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
    }

    /// Soft surface for preamp chrome — solid fill, not live Material (cheaper under scroll).
    @ViewBuilder
    private func modernEQSurface(corner: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(theme.isDark ? Color.white.opacity(0.05) : Color.white.opacity(0.70))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(theme.isDark ? 0.06 : 0.40),
                                Color.white.opacity(theme.isDark ? 0.01 : 0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(theme.isDark ? 0.18 : 0.60),
                                theme.accent.opacity(theme.isDark ? 0.10 : 0.14),
                                Color.white.opacity(theme.isDark ? 0.04 : 0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            }
            .shadow(color: .black.opacity(theme.isDark ? 0.20 : 0.05), radius: 6, y: 2)
    }
}

// MARK: - Vertical band row (modern liquid-glass)

/// Compact band row: type chips (Peak / L-Shelf / H-Shelf) + gain + F/Q.
private struct EQBandVerticalRow: View {
    let index: Int
    let band: EQBand
    let tint: Color
    var onUpdate: ((inout EQBand) -> Void) -> Void

    @Environment(\.grokTheme) private var theme

    private var corner: CGFloat { 18 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: index · type · gain · enable
            HStack(spacing: 8) {
                Text("B\(index + 1)")
                    .font(.app(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background {
                        Capsule(style: .continuous)
                            .fill(tint.opacity(theme.isDark ? 0.18 : 0.12))
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(tint.opacity(0.28), lineWidth: 0.7)
                            }
                    }

                // Current type badge
                HStack(spacing: 3) {
                    Image(systemName: band.filterType.systemImage)
                        .font(.app(size: 9, weight: .bold))
                    Text(band.filterType.shortTitle)
                        .font(.app(size: 10, weight: .bold, design: .rounded))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(tint.opacity(theme.isDark ? 0.14 : 0.10))
                )
                .accessibilityLabel("Filter type \(band.filterType.title)")

                Text(String(format: "%+.1f dB", band.gain))
                    .font(.app(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(
                        abs(band.gain) < 0.05
                            ? theme.secondaryText
                            : (band.gain > 0 ? theme.positive : theme.danger)
                    )

                Spacer(minLength: 4)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { band.isEnabled },
                        set: { v in onUpdate { $0.isEnabled = v } }
                    )
                )
                .labelsHidden()
                .controlSize(.mini)
                .tint(tint)
                .accessibilityLabel("Band \(index + 1) enabled")
            }

            // Filter type switcher — Peak / Low Shelf / High Shelf
            HStack(spacing: 4) {
                ForEach(EQFilterType.allCases) { type in
                    let selected = band.filterType == type
                    Button {
                        onUpdate { $0.filterType = type }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(type.shortTitle)
                            .font(.app(size: 10, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .foregroundStyle(selected ? theme.background : theme.secondaryText)
                            .background(
                                Capsule()
                                    .fill(selected ? tint : theme.elevated)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(type.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            // Gain — primary control
            Slider(
                value: Binding(
                    get: { band.gain },
                    set: { v in onUpdate { $0.gain = v } }
                ),
                in: EQBand.gainRange
            )
            .controlSize(.small)
            .tint(tint)

            // Nested F / Q well — Q label adapts for shelves (slope)
            HStack(spacing: 0) {
                miniParam(
                    label: "F",
                    valueText: freqLabel(band.frequency),
                    slider: Slider(
                        value: Binding(
                            get: { log10(band.frequency) },
                            set: { v in onUpdate { $0.frequency = pow(10, v) } }
                        ),
                        in: log10(EQBand.frequencyRange.lowerBound) ... log10(EQBand.frequencyRange.upperBound)
                    )
                    .controlSize(.mini)
                    .tint(tint.opacity(0.85))
                )

                Rectangle()
                    .fill(Color.white.opacity(theme.isDark ? 0.08 : 0.18))
                    .frame(width: 1, height: 28)
                    .padding(.horizontal, 8)

                miniParam(
                    label: band.filterType == .peak ? "Q" : "Slope",
                    valueText: String(format: "%.2f", band.q),
                    slider: Slider(
                        value: Binding(
                            get: { band.q },
                            set: { v in onUpdate { $0.q = v } }
                        ),
                        in: EQBand.qRange
                    )
                    .controlSize(.mini)
                    .tint(tint.opacity(0.85))
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.isDark ? Color.black.opacity(0.28) : Color.white.opacity(0.35))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(theme.isDark ? 0.08 : 0.35), lineWidth: 0.6)
                    }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background { bandGlassPlate }
        .opacity(band.isEnabled ? 1 : 0.42)
        .animation(.easeOut(duration: 0.18), value: band.isEnabled)
        .animation(.easeOut(duration: 0.15), value: band.filterType)
    }

    private func miniParam<S: View>(label: String, valueText: String, slider: S) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.app(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.tertiaryText)
                Spacer(minLength: 2)
                Text(valueText)
                    .font(.app(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
            }
            slider
        }
        .frame(maxWidth: .infinity)
    }

    private var bandGlassPlate: some View {
        // Solid + light gradient (not live Material × 10 bands — Materials are a thermal tax).
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(theme.isDark ? Color.white.opacity(0.055) : Color.white.opacity(0.72))
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(theme.isDark ? 0.07 : 0.40),
                                tint.opacity(theme.isDark ? 0.05 : 0.04),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.85), tint.opacity(0.25)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                    .padding(.vertical, 14)
                    .padding(.leading, 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(theme.isDark ? 0.20 : 0.65),
                                tint.opacity(theme.isDark ? 0.14 : 0.18),
                                Color.white.opacity(theme.isDark ? 0.04 : 0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            }
            .shadow(color: .black.opacity(theme.isDark ? 0.22 : 0.05), radius: 6, y: 2)
    }

    private func freqLabel(_ f: Double) -> String {
        f >= 1000 ? String(format: "%.1fk", f / 1000) : String(format: "%.0f", f)
    }
}

// MARK: - Glass pills (profile / device rows)

/// Capsule / continuous glass pill for profile names & actions.
private struct GlassProfilePill: View {
    let title: String
    let subtitle: String?
    let accent: Color
    let isSelected: Bool
    var systemImage: String? = nil

    @Environment(\.grokTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.app(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? accent : theme.secondaryText)
                    .frame(width: 28)
            } else {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(isSelected ? 0.95 : 0.45), accent.opacity(isSelected ? 0.55 : 0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 10, height: 10)
                    .shadow(color: accent.opacity(isSelected ? 0.55 : 0), radius: 6)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.app(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.app(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.app(size: 20, weight: .semibold))
                    .foregroundStyle(accent)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .opacity(theme.isDark ? 0.50 : 0.68)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            isSelected
                                ? accent.opacity(theme.isDark ? 0.18 : 0.12)
                                : Color.white.opacity(theme.isDark ? 0.04 : 0.20)
                        )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(theme.isDark ? 0.18 : 0.55),
                                    accent.opacity(isSelected ? 0.55 : 0.12),
                                    Color.white.opacity(theme.isDark ? 0.04 : 0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isSelected ? 1.2 : 0.6
                        )
                }
                .shadow(color: accent.opacity(isSelected ? 0.28 : 0.06), radius: isSelected ? 14 : 6, y: 4)
        }
    }
}

// MARK: - Profile picker sheet (frosted pills — stable while playing)

private struct ProfilePickerSheet: View {
    let title: String
    let accent: Color
    let presets: [EQPreset]
    let selectedName: String
    var onSelect: (EQPreset) -> Void
    var onDelete: (EQPreset) -> Void
    var onImport: (() -> Void)?
    var onLinkDevices: (() -> Void)?

    @Environment(\.grokTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Profiles")
                        .font(.app(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .padding(.horizontal, 4)

                    ForEach(presets) { preset in
                        let selected = selectedName == preset.name
                        Button {
                            onSelect(preset)
                            dismiss()
                        } label: {
                            GlassProfilePill(
                                title: preset.name,
                                subtitle: preset.isSystemDefault ? "Built-in" : "Custom curve",
                                accent: accent,
                                isSelected: selected
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !preset.isSystemDefault {
                                Button(role: .destructive) {
                                    onDelete(preset)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }

                    if onImport != nil || onLinkDevices != nil {
                        Text("Actions")
                            .font(.app(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .padding(.horizontal, 4)
                            .padding(.top, 8)

                        if let onImport {
                            Button(action: onImport) {
                                GlassProfilePill(
                                    title: "Import AutoEQ",
                                    subtitle: ".txt / .xml from Squiglink & friends",
                                    accent: accent,
                                    isSelected: false,
                                    systemImage: "doc.badge.plus"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        if let onLinkDevices {
                            Button(action: onLinkDevices) {
                                GlassProfilePill(
                                    title: "Link devices",
                                    subtitle: "Bluetooth Target auto-switch",
                                    accent: accent,
                                    isSelected: false,
                                    systemImage: "wave.3.right"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.visible)
            .background(Color.clear)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.app(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                }
            }
        }
        .frostedBleedSheet(accent: accent)
    }
}

// MARK: - Device ↔ Target links (frosted glass sheet)

private struct TargetDeviceLinksSheet: View {
    @Binding var dual: DualEQState
    var onToast: ((String) -> Void)?

    @EnvironmentObject private var presetStore: EQPresetStore
    @Environment(\.grokTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    private var devices: [AudioRouteDevice] {
        presetStore.devicesForAssignmentMenu()
    }

    private var connected: [AudioRouteDevice] {
        presetStore.connectedDevices
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel("Connected now")
                    if connected.isEmpty {
                        GlassProfilePill(
                            title: "No external device on route",
                            subtitle: "Connect headphones and play so iOS lists them",
                            accent: theme.targetTint,
                            isSelected: false,
                            systemImage: "antenna.radiowaves.left.and.right.slash"
                        )
                    } else {
                        ForEach(connected) { device in
                            let bound = presetStore.assignment(forDeviceKey: device.key)
                            GlassProfilePill(
                                title: device.name,
                                subtitle: bound.map { "Linked · \($0.targetPresetName)" } ?? "\(device.kindLabel) · not linked",
                                accent: theme.targetTint,
                                isSelected: bound != nil,
                                systemImage: device.isBluetooth ? "airpodsmax" : "hifispeaker.fill"
                            )
                        }
                    }

                    sectionLabel("Assign Target")
                    ForEach(devices) { device in
                        deviceAssignPill(device)
                    }

                    Text("Switching headphones later auto-loads that Target. Fine-Tune stays yours.")
                        .font(.app(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.tertiaryText)
                        .padding(.horizontal, 4)

                    if !presetStore.deviceTargetAssignments.isEmpty {
                        sectionLabel("Linked devices")
                        ForEach(presetStore.deviceTargetAssignments) { a in
                            Button {
                                presetStore.unassignDevice(a)
                                onToast?("Unassigned “\(a.deviceName)”")
                            } label: {
                                GlassProfilePill(
                                    title: a.deviceName,
                                    subtitle: "Tap to unassign · \(a.targetPresetName)",
                                    accent: theme.danger,
                                    isSelected: false,
                                    systemImage: "link.badge.minus"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.visible)
            .background(Color.clear)
            .navigationTitle("Device links")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.app(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.targetTint)
                }
            }
            .onAppear { presetStore.refreshConnectedDevices() }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
                presetStore.refreshConnectedDevices()
            }
        }
        .frostedBleedSheet(accent: theme.targetTint)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.app(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(theme.secondaryText)
            .textCase(.uppercase)
            .tracking(0.6)
            .padding(.horizontal, 4)
            .padding(.top, 4)
    }

    @ViewBuilder
    private func deviceAssignPill(_ device: AudioRouteDevice) -> some View {
        let current = presetStore.assignment(forDeviceKey: device.key)?.targetPresetName
        Menu {
            ForEach(presetStore.targetPresets) { preset in
                Button {
                    presetStore.assignTarget(preset.name, to: device)
                    dual.target = preset.layer
                    presetStore.selectedTargetName = preset.name
                    let tag = device.isConnected ? "" : " (last seen)"
                    onToast?("“\(preset.name)” → \(device.name)\(tag)")
                } label: {
                    if current == preset.name {
                        Label(preset.name, systemImage: "checkmark")
                    } else {
                        Text(preset.name)
                    }
                }
            }
            if current != nil {
                Divider()
                Button(role: .destructive) {
                    presetStore.unassignDevice(key: device.key)
                    onToast?("Unassigned “\(device.name)”")
                } label: {
                    Label("Unassign", systemImage: "link.badge.minus")
                }
            }
        } label: {
            GlassProfilePill(
                title: device.name,
                subtitle: device.isConnected
                    ? "\(device.kindLabel) · \(current ?? "choose Target")"
                    : "Last seen · \(current ?? "choose Target")",
                accent: theme.targetTint,
                isSelected: current != nil,
                systemImage: device.isBluetooth ? "wave.3.right" : "hifispeaker"
            )
        }
    }
}
