//
//  EQControlsView.swift
//  EQtargetsMusic
//
//  Target | Fine-Tune divider + 10-band controls + preamp −20…+20
//

import SwiftUI

struct EQControlsView: View {
    @Binding var dual: DualEQState
    var onImportAutoEQ: () -> Void

    @Environment(\.grokTheme) private var theme
    @EnvironmentObject private var presetStore: EQPresetStore

    @State private var showSaveTargetAlert = false
    @State private var newTargetName = ""
    @State private var showSaveFineTuneAlert = false
    @State private var newFineTuneName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Profile dropdowns above graph
            VStack(spacing: 8) {
                // Target profile selection
                HStack(spacing: 8) {
                    legendDot(theme.targetTint, "Target:")

                    Menu {
                        ForEach(presetStore.targetPresets) { preset in
                            if !preset.isSystemDefault {
                                Button(role: .destructive) {
                                    presetStore.deleteTargetPreset(preset)
                                } label: {
                                    Label("Delete “\(preset.name)”", systemImage: "trash")
                                }
                            }
                            Button {
                                dual.target = preset.layer
                                presetStore.selectedTargetName = preset.name
                            } label: {
                                HStack {
                                    Text(preset.name)
                                    if presetStore.selectedTargetName == preset.name {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }

                        Divider()

                        Button(action: onImportAutoEQ) {
                            Label("Import AutoEQ (.txt/.xml)...", systemImage: "doc.badge.plus")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(presetStore.selectedTargetName)
                                .font(.app(size: 12, weight: .bold, design: .rounded))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.app(size: 10, weight: .bold))
                        }
                        .foregroundStyle(theme.targetTint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.targetTint.opacity(0.15)))
                    }

                    Spacer()

                    Button(action: onImportAutoEQ) {
                        Image(systemName: "doc.badge.plus")
                            .font(.app(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(theme.targetTint)

                    Button {
                        newTargetName = presetStore.selectedTargetName
                        showSaveTargetAlert = true
                    } label: {
                        Label("Save", systemImage: "bookmark.fill")
                            .font(.app(size: 11, weight: .bold, design: .rounded))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(theme.targetTint)
                }

                // Fine-Tune profile selection + Save button
                HStack(spacing: 8) {
                    legendDot(theme.fineTint, "Fine-Tune:")

                    Menu {
                        ForEach(presetStore.fineTunePresets) { preset in
                            if !preset.isSystemDefault {
                                Button(role: .destructive) {
                                    presetStore.deleteFineTunePreset(preset)
                                } label: {
                                    Label("Delete “\(preset.name)”", systemImage: "trash")
                                }
                            }
                            Button {
                                dual.fineTune = preset.layer
                                presetStore.selectedFineTuneName = preset.name
                            } label: {
                                HStack {
                                    Text(preset.name)
                                    if presetStore.selectedFineTuneName == preset.name {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(presetStore.selectedFineTuneName)
                                .font(.app(size: 12, weight: .bold, design: .rounded))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.app(size: 10, weight: .bold))
                        }
                        .foregroundStyle(theme.fineTint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.fineTint.opacity(0.15)))
                    }

                    Spacer()

                    Button {
                        newFineTuneName = presetStore.selectedFineTuneName
                        showSaveFineTuneAlert = true
                    } label: {
                        Label("Save", systemImage: "bookmark.fill")
                            .font(.app(size: 11, weight: .bold, design: .rounded))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(theme.fineTint)
                }
            }
            .padding(10)
            .glassCard(corner: 14)

            EQGraphView(dual: dual)

            // Modern Liquid Glass Switch (Target Curve | Fine-Tune Adjust)
            liquidGlassSegmentedSwitch

            Text(dual.editingLayer.subtitle)
                .font(.app(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(theme.tertiaryText)

            // Preamp −20…+20
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(dual.editingLayer.title) Preamp")
                        .font(.app(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text(String(format: "%+.1f dB", dual.activeLayer.preamp))
                        .font(.app(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(theme.accent)
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
                .tint(theme.accent)
            }
            .padding(12)
            .glassCard(corner: 14)

            // 10 bands horizontal scroll
            Text("10 parametric bands · F / Gain / Q")
                .font(.app(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.secondaryText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(dual.activeLayer.bands.indices), id: \.self) { i in
                        bandCard(index: i)
                    }
                }
                .padding(.vertical, 4)
            }

            HStack(spacing: 8) {
                Button {
                    dual.isBypassed.toggle()
                } label: {
                    Label(dual.isBypassed ? "EQ Bypassed" : "EQ Active", systemImage: dual.isBypassed ? "speaker.slash" : "waveform")
                }
                .buttonStyle(.bordered)
                .tint(dual.isBypassed ? theme.danger : theme.accent)

                Button {
                    dual.resetFineTune()
                } label: {
                    Label("Reset Fine-Tune", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .tint(theme.fineTint)

                Spacer()
            }
            .font(.app(size: 12, weight: .semibold, design: .rounded))
        }
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
    }

    private var liquidGlassSegmentedSwitch: some View {
        HStack(spacing: 4) {
            switchPillSegment(.target, title: "Target Curve", subtitle: "Compensation", tint: theme.targetTint)
            switchPillSegment(.fineTune, title: "Fine-Tune Adjust", subtitle: "Personal EQ", tint: theme.fineTint)
        }
        .padding(4)
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
        .shadow(color: .black.opacity(theme.isDark ? 0.20 : 0.08), radius: theme.isDark ? 6 : 10, y: theme.isDark ? 2 : 4)
    }

    private func switchPillSegment(_ layer: EQLayer, title: String, subtitle: String, tint: Color) -> some View {
        let isSelected = dual.editingLayer == layer
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                dual.editingLayer = layer
            }
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(.app(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(isSelected ? tint : theme.secondaryText)
                Text(subtitle)
                    .font(.app(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? tint.opacity(0.85) : theme.tertiaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                if isSelected {
                    Capsule()
                        .fill(tint.opacity(0.20))
                        .overlay {
                            Capsule().strokeBorder(tint.opacity(0.40), lineWidth: 1.0)
                        }
                        .shadow(color: tint.opacity(0.35), radius: 6)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func bandCard(index: Int) -> some View {
        let band = dual.activeLayer.bands[index]

        func update(_ mutate: (inout EQBand) -> Void) {
            var layer = dual.activeLayer
            mutate(&layer.bands[index])
            layer.bands[index].sanitize() // clamp F / G / Q into legal ranges
            dual.activeLayer = layer
        }

        return VStack(spacing: 8) {
            HStack {
                Text("B\(index + 1)")
                    .font(.app(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.accent)
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { dual.activeLayer.bands[index].isEnabled },
                        set: { v in update { $0.isEnabled = v } }
                    )
                )
                .labelsHidden()
                .controlSize(.mini)
            }

            Text(String(format: "%+.1f dB", band.gain))
                .font(.app(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(
                    abs(band.gain) < 0.05
                        ? theme.secondaryText
                        : (band.gain > 0 ? theme.positive : theme.danger)
                )

            Slider(
                value: Binding(
                    get: { dual.activeLayer.bands[index].gain },
                    set: { v in update { $0.gain = v } }
                ),
                in: EQBand.gainRange
            )
            .controlSize(.small)
            .tint(theme.accent)
            .frame(width: 100)

            labeledLogSlider(
                "Hz",
                value: Binding(
                    get: { dual.activeLayer.bands[index].frequency },
                    set: { v in update { $0.frequency = v } }
                ),
                range: EQBand.frequencyRange
            )
            labeledSlider(
                "Q",
                value: Binding(
                    get: { dual.activeLayer.bands[index].q },
                    set: { v in update { $0.q = v } }
                ),
                range: EQBand.qRange
            )

            Text(freqLabel(band.frequency))
                .font(.app(size: 10, design: .monospaced))
                .foregroundStyle(theme.tertiaryText)
            Text(String(format: "Q %.2f", band.q))
                .font(.app(size: 10, design: .monospaced))
                .foregroundStyle(theme.tertiaryText)
        }
        .padding(10)
        .frame(width: 120)
        .glassCard(corner: 14)
        .opacity(band.isEnabled ? 1 : 0.5)
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.app(size: 9, weight: .semibold))
                .foregroundStyle(theme.tertiaryText)
            Slider(value: value, in: range)
                .controlSize(.mini)
                .tint(theme.accentSecondary)
        }
    }

    private func labeledLogSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.app(size: 9, weight: .semibold))
                .foregroundStyle(theme.tertiaryText)
            Slider(
                value: Binding(
                    get: { log10(value.wrappedValue) },
                    set: { value.wrappedValue = pow(10, $0) }
                ),
                in: log10(range.lowerBound) ... log10(range.upperBound)
            )
            .controlSize(.mini)
            .tint(theme.accentSecondary)
        }
    }

    private func legendDot(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 12, height: 3)
            Text(title)
                .font(.app(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func freqLabel(_ f: Double) -> String {
        f >= 1000 ? String(format: "%.2f kHz", f / 1000) : String(format: "%.0f Hz", f)
    }
}
