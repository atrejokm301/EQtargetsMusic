//
//  EQControlsView.swift
//  EQtargetsMusic
//
//  Now Playing: EQGraphView stays here + entry tiles for frosted editor sheets.
//  Detailed controls live in EQEditorSheet / BassStyleEditorSheet / LimiterEditorSheet.
//  Dual EQ chain: Target → Fine-Tune. Bass and Limiter are separate post stages.
//

import SwiftUI
import AVFoundation

// MARK: - Now Playing surface (graph stays put)

struct EQControlsView: View {
    @Binding var dual: DualEQState
    @Binding var bass: BassProcessorState
    @Binding var limiter: LimiterState
    var onImportAutoEQ: () -> Void
    /// Optional toast when assigning devices (wired from Now Playing / player).
    var onToast: ((String) -> Void)? = nil
    /// Live limiter gain reduction in dB (positive) for the editor's meter.
    var limiterGainReduction: () -> Double = { 0 }
    /// Live Transient Punch attack boost in dB (positive) for the bass meter.
    var punchAttackBoost: () -> Double = { 0 }
    /// Live Transient Punch sustain trim in dB (positive) for the bass meter.
    var punchSustainTrim: () -> Double = { 0 }

    @Environment(\.grokTheme) private var theme
    @EnvironmentObject private var presetStore: EQPresetStore

    @State private var showEQEditor = false
    @State private var showBassSheet = false
    @State private var showLimiterSheet = false

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
            // Graph shows Target + Fine-Tune only (Bass / Limiter are post-PEQ).
            EQGraphView(dual: dual)

            // Shared tile style: icon + title + subtitle + chevron.up on glassCard
            effectEntryTile(
                icon: "slider.vertical.3",
                iconTint: theme.accent,
                title: "EQ Controls",
                subtitle: "Profiles, preamp & 10 bands",
                accessibilityLabel: "Open EQ controls",
                accessibilityHint: "Opens Target and Fine-Tune band editor"
            ) {
                showEQEditor = true
            }

            effectEntryTile(
                icon: "hifispeaker.fill",
                iconTint: theme.accentSecondary,
                title: "Bass Style",
                subtitle: bassTileSubtitle,
                accessibilityLabel: "Open Bass Style",
                accessibilityHint: "Opens bass processor settings"
            ) {
                showBassSheet = true
            }

            effectEntryTile(
                icon: "waveform.badge.minus",
                iconTint: theme.fineTint,
                title: "Limiter",
                subtitle: limiter.isEnabled ? limiter.summaryLabel : "Threshold, ratio & post-gain",
                accessibilityLabel: "Open Limiter",
                accessibilityHint: "Opens limiter settings",
                accessibilityValue: limiter.summaryLabel
            ) {
                showLimiterSheet = true
            }
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
        .sheet(isPresented: $showBassSheet) {
            BassStyleEditorSheet(
                bass: $bass,
                punchAttackBoost: punchAttackBoost,
                punchSustainTrim: punchSustainTrim
            )
            .environment(\.grokTheme, theme)
        }
        .sheet(isPresented: $showLimiterSheet) {
            LimiterEditorSheet(
                limiter: $limiter,
                gainReduction: limiterGainReduction,
                onToast: onToast
            )
            .environmentObject(presetStore)
            .environment(\.grokTheme, theme)
        }
    }

    private var bassTileSubtitle: String {
        guard bass.style != .none else { return "Styles, strength & post gain" }
        let pct = Int((bass.strength * 100).rounded())
        return "\(bass.style.title) · \(pct)%"
    }

    private func effectEntryTile(
        icon: String,
        iconTint: Color,
        title: String,
        subtitle: String,
        accessibilityLabel: String,
        accessibilityHint: String,
        accessibilityValue: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.app(size: 16, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 22, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.app(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text(subtitle)
                        .font(.app(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
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
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityValue(accessibilityValue ?? "")
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

// MARK: - Bass Style editor sheet (same chrome as EQ Controls)

/// Full bass processor UI in a frosted bottom sheet — never touches DualEQ.
struct BassStyleEditorSheet: View {
    @Binding var bass: BassProcessorState
    /// Live attack boost in dB (positive) from the active deck's Punch stage.
    var punchAttackBoost: () -> Double = { 0 }
    /// Live sustain trim in dB (positive) from the same stage.
    var punchSustainTrim: () -> Double = { 0 }

    @Environment(\.grokTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Meter ballistics: instant rise, ~150 ms decay — same feel as the limiter's
    /// gain-reduction meter so the two read identically.
    @State private var meterBoost: Double = 0
    @State private var meterTrim: Double = 0

    private var bassTint: Color { theme.accentSecondary }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Style chips
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Style")
                            .font(.app(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.secondaryText)

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
                                        Text(style.compactTitle)
                                            .font(.app(size: 11, weight: .semibold, design: .rounded))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.85)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .foregroundStyle(selected ? theme.background : theme.primaryText)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 10)
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
                            Text(bass.style.subtitle)
                                .font(.app(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .padding(14)
                    .glassCard(corner: 16)

                    if bass.style != .none {
                        VStack(spacing: 14) {
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
                                format: { String(format: "%.0f%%", $0 * 100) }
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
                                format: { String(format: "%.0f Hz", $0) }
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
                                format: { String(format: "%+.1f dB", $0) }
                            )
                        }
                        .padding(14)
                        .glassCard(corner: 16)
                    }

                    // Dynamic controls. Punch and Rumble share one time-domain
                    // stage running opposite gain laws; Clean and Off are static
                    // by design, so the card would be inert for them.
                    if bass.style.hasDynamics {
                        dynamicsCard
                    }

                    Text("Runs after Target and Fine-Tune. Does not edit AutoEQ or EQ bands.")
                        .font(.app(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.visible)
            .background(Color.clear)
            .navigationTitle("Bass Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        bass = .flat
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    .font(.app(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.app(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accent)
                }
            }
            .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
                // Only Punch and Rumble drive the dynamic stage; the others leave
                // the kernel bypassed, so polling it would just read zeros.
                guard bass.style.hasDynamics else {
                    if meterBoost != 0 { meterBoost = 0 }
                    if meterTrim != 0 { meterTrim = 0 }
                    return
                }
                let boost = punchAttackBoost()
                let trim = punchSustainTrim()
                meterBoost = boost > meterBoost ? boost : meterBoost * 0.82 + boost * 0.18
                meterTrim = trim > meterTrim ? trim : meterTrim * 0.82 + trim * 0.18
            }
        }
        .frostedBleedSheet(accent: bassTint)
        .presentationDetents([.fraction(0.55), .large])
        .presentationContentInteraction(.scrolls)
    }

    // MARK: Dynamics
    //
    // Punch and Rumble drive the same stage in opposite directions, so they get
    // the same card with mirrored wording: one slider that boosts, one that
    // cuts, and the meter showing which is currently acting.

    private var dynamicsCard: some View {
        let rumble = bass.style == .sustainRumble

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: rumble ? "water.waves" : "waveform.path")
                    .font(.app(size: 12, weight: .semibold))
                Text("Dynamics")
                    .font(.app(size: 12, weight: .bold, design: .rounded))
                    .textCase(.uppercase)
                    .tracking(0.6)
            }
            .foregroundStyle(theme.secondaryText)

            // Boosting half.
            bassSlider(
                title: rumble ? "Sustain length" : "Attack emphasis",
                value: Binding(
                    get: { rumble ? bass.rumbleSustain : bass.punchAttack },
                    set: { v in
                        var n = bass
                        if rumble { n.rumbleSustain = v } else { n.punchAttack = v }
                        n.sanitize()
                        bass = n
                    }
                ),
                range: BassProcessorState.punchAttackRange,
                format: { $0 < 0.005 ? "Off" : String(format: "%.0f%%", $0 * 100) }
            )

            // Cutting half.
            bassSlider(
                title: rumble ? "Attack softening" : "Sustain control",
                value: Binding(
                    get: { rumble ? bass.rumbleSoften : bass.punchSustain },
                    set: { v in
                        var n = bass
                        if rumble { n.rumbleSoften = v } else { n.punchSustain = v }
                        n.sanitize()
                        bass = n
                    }
                ),
                range: BassProcessorState.punchSustainRange,
                format: { $0 < 0.005 ? "Off" : String(format: "%.0f%%", $0 * 100) }
            )

            activityMeter(
                title: "\(bass.style.compactTitle) activity",
                leftLabel: rumble ? "soften" : "trim",
                rightLabel: rumble ? "sustain" : "boost"
            )

            Text(rumble
                 ? "Sustain holds a note up as it decays, so the low end rings on longer — it only acts once the note is already falling, so steady bass keeps its level. Attack softening rounds the leading edge, the deliberate opposite of Punch."
                 : "Attack lifts the leading edge of kicks. Sustain control trims what sits behind them — raise it for a tighter, drier low end.")
                .font(.app(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .glassCard(corner: 16)
    }

    // MARK: Activity meter

    /// Centre-anchored bar: boost grows right, trim grows left, because the two
    /// stages pull the low band in opposite directions and the *contrast* between
    /// them is the whole point of the style. Both halves share one 9 dB scale
    /// (the attack stage's own ceiling) so a bar twice as long really is twice
    /// the gain change — the trim side simply never fills past its 6 dB limit.
    private func activityMeter(title: String, leftLabel: String, rightLabel: String) -> some View {
        // One shared scale across both styles so switching chips compares like
        // with like. Punch's 9 dB boost is the larger of the four ceilings.
        let fullScaleDB = TransientPunchTuning.maxAttackBoostDB
        let boostFraction = min(1.0, max(0.0, meterBoost / fullScaleDB))
        let trimFraction = min(1.0, max(0.0, meterTrim / fullScaleDB))
        let idle = meterBoost < 0.05 && meterTrim < 0.05

        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.app(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Text(punchReadout)
                    .font(.app(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(idle ? theme.tertiaryText : theme.primaryText)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                let half = geo.size.width / 2
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(theme.primaryText.opacity(0.08))
                    // Centre tick — the 0 dB reference the two stages move away from.
                    Rectangle()
                        .fill(theme.primaryText.opacity(0.22))
                        .frame(width: 1)
                        .offset(x: half - 0.5)
                    // Trim: right-aligned inside the left half so it grows leftward.
                    // Neutral rather than tinted — same stage, opposite direction,
                    // and 0.9 keeps it legible against the 8% track in dark mode.
                    Capsule()
                        .fill(theme.secondaryText.opacity(0.9))
                        .frame(width: max(0, half * trimFraction))
                        .offset(x: half - max(0, half * trimFraction))
                    // Boost: starts at centre, grows right.
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [bassTint.opacity(0.75), bassTint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, half * boostFraction))
                        .offset(x: half)
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.08), value: boostFraction)
            .animation(.easeOut(duration: 0.08), value: trimFraction)

            HStack {
                Text(leftLabel)
                Spacer()
                Text(rightLabel)
            }
            .font(.app(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.tertiaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            idle
                ? "Idle"
                : String(format: "Boost %.1f decibels, trim %.1f decibels", meterBoost, meterTrim)
        )
    }

    /// Single-line numeric readout. Shows whichever stage is doing more work, so
    /// the number never fights the bar for attention.
    private var punchReadout: String {
        if meterBoost < 0.05 && meterTrim < 0.05 { return "0.0 dB" }
        if meterBoost >= meterTrim { return String(format: "+%.1f dB", meterBoost) }
        return String(format: "−%.1f dB", meterTrim)
    }

    private func bassSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String
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
                .tint(bassTint)
        }
    }
}

// MARK: - Limiter editor sheet (same chrome as EQ Controls)
//
// Layout order is deliberate: enable + live gain-reduction meter, then genre
// presets, then the user's own presets, then headphone links, and only then
// the raw parameters. Most people pick a genre and never open the sliders, so
// the sliders sit last behind a disclosure rather than greeting them first.

struct LimiterEditorSheet: View {
    @Binding var limiter: LimiterState
    /// Live gain reduction in dB (positive) from the active deck.
    var gainReduction: () -> Double = { 0 }
    var onToast: ((String) -> Void)? = nil

    @EnvironmentObject private var presetStore: EQPresetStore
    @Environment(\.grokTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var showSaveAlert = false
    @State private var newPresetName = ""
    @State private var showAdvanced = false
    /// Meter ballistics: fast rise, slow fall, so brief reduction stays readable.
    @State private var meterGR: Double = 0
    @State private var renameTarget: LimiterPreset?
    @State private var renameText = ""

    private var tint: Color { theme.fineTint }

    private static let genreColumns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 4
    )

    /// Name of the preset the live state currently matches, or "" once edited.
    private var activePresetName: String {
        presetStore.limiterPresetName(matching: limiter)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    enableCard
                    genreSection
                    myPresetsSection
                    advancedSection

                    Text("Runs after Target, Fine-Tune and Bass. Never edits your EQ bands. The ceiling is a hard output limit — nothing leaves this stage above it.")
                        .font(.app(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.visible)
            .background(Color.clear)
            .navigationTitle("Limiter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        limiter = .flat
                        presetStore.selectedLimiterName = ""
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    .font(.app(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.app(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.accent)
                }
            }
            .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
                guard limiter.isEnabled else {
                    if meterGR != 0 { meterGR = 0 }
                    return
                }
                let v = gainReduction()
                // Rise instantly to the peak, decay ~150 ms — standard meter feel.
                meterGR = v > meterGR ? v : meterGR * 0.82 + v * 0.18
            }
        }
        .frostedBleedSheet(accent: tint)
        .presentationDetents([.fraction(0.55), .large])
        .presentationContentInteraction(.scrolls)
        .alert("Save limiter preset", isPresented: $showSaveAlert) {
            TextField("Name", text: $newPresetName)
            Button("Save") {
                guard let saved = presetStore.saveLimiterPreset(name: newPresetName, state: limiter) else { return }
                limiter.isEnabled = true
                onToast?("Saved “\(saved)”")
                newPresetName = ""
            }
            Button("Cancel", role: .cancel) { newPresetName = "" }
        } message: {
            Text("Stores the current limiter settings so you can recall them or link them to headphones.")
        }
        .alert("Rename preset", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let target = renameTarget {
                    presetStore.renameLimiterPreset(target, to: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    // MARK: Enable + meter

    private var enableCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Enable limiter")
                        .font(.app(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("Lookahead brickwall · after Target, Fine-Tune and Bass")
                        .font(.app(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { limiter.isEnabled },
                    set: { on in
                        var n = limiter
                        n.isEnabled = on
                        n.sanitize()
                        limiter = n
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                ))
                .labelsHidden()
                .tint(tint)
            }

            if limiter.isEnabled {
                gainReductionMeter
            }
        }
        .padding(14)
        .glassCard(corner: 16)
    }

    /// Horizontal gain-reduction meter. Fills right-to-left because gain
    /// reduction pulls *down* from 0 dB — the bar shrinking the signal.
    private var gainReductionMeter: some View {
        let maxGR = 12.0
        let fraction = min(1.0, max(0.0, meterGR / maxGR))
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Gain reduction")
                    .font(.app(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Text(meterGR < 0.05 ? "0.0 dB" : String(format: "−%.1f dB", meterGR))
                    .font(.app(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(meterGR > 6 ? theme.danger : theme.primaryText)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .trailing) {
                    Capsule()
                        .fill(theme.primaryText.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint, meterGR > 6 ? theme.danger : tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.08), value: fraction)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gain reduction")
        .accessibilityValue(String(format: "%.1f decibels", meterGR))
    }

    // MARK: Genre presets

    private var genreSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Genre presets")
            // Four columns rather than one row: at seven presets a single row
            // leaves ~46pt per chip, which clips "Adoración" and crowds the
            // 44pt minimum tap target. 4 × ~84pt keeps both intact.
            LazyVGrid(columns: Self.genreColumns, spacing: 6) {
                ForEach(LimiterGenre.allCases) { genre in
                    let selected = activePresetName == genre.title
                    Button {
                        var s = genre.state
                        s.isEnabled = true
                        limiter = s
                        presetStore.selectedLimiterName = genre.title
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: genre.systemImage)
                                .font(.app(size: 15, weight: .semibold))
                            Text(genre.compactTitle)
                                .font(.app(size: 10, weight: .bold, design: .rounded))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(selected ? theme.background : theme.primaryText)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(selected ? tint : theme.elevated))
                        .overlay(
                            Capsule().strokeBorder(
                                selected ? Color.clear : theme.primaryText.opacity(0.08),
                                lineWidth: 1
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(genre.title)
                    .accessibilityHint(genre.subtitle)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            if let genre = LimiterGenre.allCases.first(where: { $0.title == activePresetName }) {
                Text(genre.subtitle)
                    .font(.app(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(14)
        .glassCard(corner: 16)
    }

    // MARK: User presets

    private var myPresetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("My presets")

            let mine = presetStore.userLimiterPresets
            if mine.isEmpty {
                Text("None yet. Dial in the sliders below, then save the result here.")
                    .font(.app(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(mine) { preset in
                    Menu {
                        Button {
                            limiter = preset.state
                            presetStore.selectedLimiterName = preset.name
                        } label: {
                            Label("Load", systemImage: "arrow.down.circle")
                        }
                        Button {
                            presetStore.saveLimiterPreset(name: preset.name, state: limiter)
                            onToast?("Updated “\(preset.name)”")
                        } label: {
                            Label("Overwrite with current", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            renameText = preset.name
                            renameTarget = preset
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            presetStore.deleteLimiterPreset(preset)
                            onToast?("Deleted “\(preset.name)”")
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        GlassProfilePill(
                            title: preset.name,
                            subtitle: preset.state.summaryLabel,
                            accent: tint,
                            isSelected: activePresetName == preset.name,
                            systemImage: preset.systemImage
                        )
                    }
                }
            }

            Button {
                newPresetName = suggestedPresetName()
                showSaveAlert = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.app(size: 15, weight: .semibold))
                    Text("Save current as…")
                        .font(.app(size: 14, weight: .bold, design: .rounded))
                    Spacer()
                }
                .foregroundStyle(tint)
                .frame(minHeight: 44)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save current limiter settings as a preset")
        }
        .padding(14)
        .glassCard(corner: 16)
    }

    /// Seed the save dialog with something meaningful rather than a blank field.
    private func suggestedPresetName() -> String {
        let base = activePresetName.isEmpty ? "My Limiter" : "\(activePresetName) Custom"
        guard presetStore.limiterPreset(named: base) != nil else { return base }
        var n = 2
        while presetStore.limiterPreset(named: "\(base) \(n)") != nil { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Parameters

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { showAdvanced.toggle() }
            } label: {
                HStack {
                    Text("Fine controls")
                        .font(.app(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer()
                    Text(limiter.summaryLabel)
                        .font(.app(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.app(size: 12, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showAdvanced ? "Hide fine controls" : "Show fine controls")

            if showAdvanced {
                VStack(spacing: 14) {
                    paramSlider(
                        title: "Ceiling",
                        subtitle: "Hard output limit — nothing exceeds this",
                        value: binding(\.ceilingDB),
                        range: LimiterState.ceilingRange,
                        format: { String(format: "%.1f dB", $0) }
                    )
                    paramSlider(
                        title: "Threshold",
                        subtitle: "Gain reduction starts above this level",
                        value: binding(\.thresholdDB),
                        range: LimiterState.thresholdRange,
                        format: { String(format: "%+.1f dB", $0) }
                    )
                    paramSlider(
                        title: "Ratio",
                        subtitle: ratioSubtitle,
                        value: binding(\.ratio),
                        range: LimiterState.ratioRange,
                        format: { r in
                            if r >= LimiterState.infiniteRatioDisplay - 0.05 { return "∞:1" }
                            return String(format: "%.1f:1", r)
                        }
                    )
                    paramSlider(
                        title: "Knee",
                        subtitle: "Wider = compression eases in more gradually",
                        value: binding(\.kneeDB),
                        range: LimiterState.kneeRange,
                        format: { $0 < 0.05 ? "Hard" : String(format: "%.1f dB", $0) }
                    )
                    paramSlider(
                        title: "Attack",
                        subtitle: "How fast peaks are caught (capped by lookahead)",
                        value: binding(\.attackMs),
                        range: LimiterState.attackMsRange,
                        format: { String(format: "%.1f ms", $0) }
                    )
                    paramSlider(
                        title: "Release",
                        subtitle: "Base recovery time · stretches automatically on sustained loudness",
                        value: binding(\.releaseMs),
                        range: LimiterState.releaseMsRange,
                        format: { String(format: "%.0f ms", $0) }
                    )
                    paramSlider(
                        title: "Lookahead",
                        subtitle: "Larger = more transparent, adds this much latency",
                        value: binding(\.lookaheadMs),
                        range: LimiterState.lookaheadMsRange,
                        format: { String(format: "%.1f ms", $0) }
                    )

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto makeup")
                                .font(.app(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                            Text(limiter.autoMakeup
                                 ? String(format: "Deriving %+.1f dB from threshold and ratio", limiter.effectiveMakeupDB)
                                 : "Set makeup manually below")
                                .font(.app(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(theme.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { limiter.autoMakeup },
                            set: { on in
                                var n = limiter
                                n.autoMakeup = on
                                n.sanitize()
                                limiter = n
                            }
                        ))
                        .labelsHidden()
                        .tint(tint)
                    }

                    if !limiter.autoMakeup {
                        paramSlider(
                            title: "Makeup",
                            subtitle: "Gain after limiting · the ceiling still applies",
                            value: binding(\.postGainDB),
                            range: LimiterState.postGainRange,
                            format: { String(format: "%+.1f dB", $0) }
                        )
                    }
                }
                .opacity(limiter.isEnabled ? 1 : 0.45)
                .allowsHitTesting(limiter.isEnabled)
            }
        }
        .padding(14)
        .glassCard(corner: 16)
    }

    private var ratioSubtitle: String {
        if limiter.ratio >= LimiterState.infiniteRatioDisplay - 0.05 {
            return "Near brickwall — strongest peak control"
        }
        if limiter.ratio >= 8 {
            return "Strong limiting — good for hot live tracks"
        }
        if limiter.ratio >= 4 {
            return "Musical compression / soft limiting"
        }
        return "Gentle leveling"
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.app(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(theme.secondaryText)
            .textCase(.uppercase)
            .tracking(0.6)
    }

    private func binding(_ keyPath: WritableKeyPath<LimiterState, Double>) -> Binding<Double> {
        Binding(
            get: { limiter[keyPath: keyPath] },
            set: { v in
                var n = limiter
                n[keyPath: keyPath] = v
                n.sanitize()
                limiter = n
            }
        )
    }

    private func paramSlider(
        title: String,
        subtitle: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: @escaping (Double) -> String
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
            Text(subtitle)
                .font(.app(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(theme.secondaryText)
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
                    // Switch editing layer first so sliders match the curve you're picking.
                    selectEditingLayer(.target)
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
                    .contentShape(Capsule())
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
                    selectEditingLayer(.fineTune)
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
                    .contentShape(Capsule())
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
            selectEditingLayer(layer)
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
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(isSelected ? tint.opacity(0.20) : Color.clear)
                    .overlay {
                        if isSelected {
                            Capsule().strokeBorder(tint.opacity(0.40), lineWidth: 0.9)
                        }
                    }
            }
            // Full half-width hit target (not just the text glyphs).
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Switch EQ editor to \(title)")
    }

    /// Write whole `DualEQState` so `@Published` / `@Binding` always notice `editingLayer` changes.
    private func selectEditingLayer(_ layer: EQLayer) {
        guard dual.editingLayer != layer else { return }
        var next = dual
        next.editingLayer = layer
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            dual = next
        }
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
