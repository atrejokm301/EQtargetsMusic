//
//  EQGraphView.swift
//  EQtargetsMusic
//
//  Premium frequency-response plot (plugin-style, 2025–26).
//  Performance: 96 log points, debounced updates, skip redraw when dual unchanged,
//  no heavy blur / continuous animation / complex shaders.
//

import SwiftUI

struct EQGraphView: View {
    let dual: DualEQState
    var yRange: ClosedRange<Double> = -20 ... 20

    @Environment(\.grokTheme) private var theme

    @State private var combinedPoints: [FrequencyResponse.Point] = []
    @State private var targetPoints: [FrequencyResponse.Point] = []
    @State private var finePoints: [FrequencyResponse.Point] = []
    @State private var peak: FrequencyResponse.Peak?
    @State private var lastDual: DualEQState?
    @State private var graphUpdateTask: Task<Void, Never>?

    private let xTicks: [Double] = [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]
    private let yTicks: [Double] = [-20, -10, 0, 10, 20]

    /// Plot inset: left for dB labels, bottom for Hz labels, top for peak chip.
    private let plotInsets = EdgeInsets(top: 18, leading: 34, bottom: 22, trailing: 10)

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(
                x: plotInsets.leading,
                y: plotInsets.top,
                width: max(geo.size.width - plotInsets.leading - plotInsets.trailing, 1),
                height: max(geo.size.height - plotInsets.top - plotInsets.bottom, 1)
            )

            ZStack {
                // Chassis
                chassis

                // Grid + curves (Canvas = one draw pass, cheap)
                Canvas { ctx, _ in
                    drawGrid(ctx: ctx, plot: plot)
                    if !dual.isBypassed {
                        // Underlays: Target + Fine (faint)
                        if !dual.target.isBypassed, !targetPoints.isEmpty {
                            strokeCurve(
                                ctx: ctx,
                                points: targetPoints,
                                plot: plot,
                                color: theme.targetTint.opacity(0.38),
                                lineWidth: 1.15,
                                dash: [4, 3]
                            )
                        }
                        if !dual.fineTune.isBypassed, !dual.fineTune.isFlat, !finePoints.isEmpty {
                            strokeCurve(
                                ctx: ctx,
                                points: finePoints,
                                plot: plot,
                                color: theme.fineTint.opacity(0.42),
                                lineWidth: 1.15,
                                dash: [2, 3]
                            )
                        }
                        // Combined fill + soft “glow” (double stroke, no blur) + main line
                        if !combinedPoints.isEmpty {
                            fillUnderCurve(ctx: ctx, points: combinedPoints, plot: plot)
                            strokeCurve(
                                ctx: ctx,
                                points: combinedPoints,
                                plot: plot,
                                color: theme.accent.opacity(0.22),
                                lineWidth: 5.5,
                                dash: nil
                            )
                            strokeCurve(
                                ctx: ctx,
                                points: combinedPoints,
                                plot: plot,
                                color: nil,
                                gradient: true,
                                lineWidth: 2.2,
                                dash: nil
                            )
                        }
                    } else {
                        // Flat reference when global bypass
                        var mid = Path()
                        let y0 = yFor(0, plot: plot)
                        mid.move(to: CGPoint(x: plot.minX, y: y0))
                        mid.addLine(to: CGPoint(x: plot.maxX, y: y0))
                        ctx.stroke(mid, with: .color(theme.secondaryText.opacity(0.35)), lineWidth: 1.2)
                    }
                }
                .drawingGroup(opaque: false) // flatten once; avoid per-layer blur cost

                // Axis labels (SwiftUI Text — Canvas text is awkward)
                dBLabels(plot: plot)
                frequencyLabels(plot: plot)

                // Peak callout
                if !dual.isBypassed, let peak {
                    peakMarker(peak, plot: plot)
                }

                // Bypass badge
                if dual.isBypassed {
                    Text("BYPASSED")
                        .font(.app(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.danger.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.danger.opacity(0.12)))
                        .position(x: plot.midX, y: plot.minY + 10)
                }
            }
        }
        .frame(height: 172)
        .accessibilityLabel(accessibilitySummary)
        .onAppear { updatePoints(force: true) }
        .onChange(of: dual) { _, newValue in
            scheduleUpdatePoints(for: newValue)
        }
        .onDisappear { graphUpdateTask?.cancel() }
    }

    // MARK: - Chassis

    private var chassis: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(theme.isDark ? Color(white: 0.06) : Color.white.opacity(0.55))
            .overlay {
                // Subtle top sheen (static gradient — not live Material thrash)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(theme.isDark ? 0.06 : 0.35),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(theme.isDark ? 0.14 : 0.55),
                                theme.accent.opacity(theme.isDark ? 0.12 : 0.18),
                                Color.white.opacity(theme.isDark ? 0.04 : 0.12)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            }
    }

    // MARK: - Grid

    private func drawGrid(ctx: GraphicsContext, plot: CGRect) {
        // Vertical (frequency) — very faint
        for f in xTicks {
            let x = plot.minX + FrequencyResponse.xPosition(f) * plot.width
            var p = Path()
            p.move(to: CGPoint(x: x, y: plot.minY))
            p.addLine(to: CGPoint(x: x, y: plot.maxY))
            ctx.stroke(p, with: .color(Color.white.opacity(theme.isDark ? 0.045 : 0.07)), lineWidth: 0.6)
        }
        // Horizontal (dB)
        for g in yTicks {
            let y = yFor(g, plot: plot)
            var p = Path()
            p.move(to: CGPoint(x: plot.minX, y: y))
            p.addLine(to: CGPoint(x: plot.maxX, y: y))
            let isZero = abs(g) < 0.01
            ctx.stroke(
                p,
                with: .color(
                    isZero
                        ? theme.secondaryText.opacity(theme.isDark ? 0.28 : 0.32)
                        : Color.white.opacity(theme.isDark ? 0.05 : 0.08)
                ),
                lineWidth: isZero ? 1.0 : 0.6
            )
        }
    }

    // MARK: - Curves (Canvas helpers)

    private func fillUnderCurve(ctx: GraphicsContext, points: [FrequencyResponse.Point], plot: CGRect) {
        guard let first = points.first, let last = points.last else { return }
        var path = Path()
        let start = point(first, plot: plot)
        path.move(to: CGPoint(x: start.x, y: plot.maxY))
        path.addLine(to: start)
        for p in points.dropFirst() {
            path.addLine(to: point(p, plot: plot))
        }
        let end = point(last, plot: plot)
        path.addLine(to: CGPoint(x: end.x, y: plot.maxY))
        path.closeSubpath()

        // Cyan/teal-ish fill using accent → accentSecondary, low opacity → clear
        let gradient = Gradient(colors: [
            theme.accent.opacity(theme.isDark ? 0.32 : 0.26),
            theme.accentSecondary.opacity(theme.isDark ? 0.12 : 0.10),
            theme.accent.opacity(0.02)
        ])
        ctx.fill(
            path,
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: plot.midX, y: plot.minY),
                endPoint: CGPoint(x: plot.midX, y: plot.maxY)
            )
        )
    }

    private func strokeCurve(
        ctx: GraphicsContext,
        points: [FrequencyResponse.Point],
        plot: CGRect,
        color: Color?,
        gradient: Bool = false,
        lineWidth: CGFloat,
        dash: [CGFloat]?
    ) {
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: point(first, plot: plot))
        for p in points.dropFirst() {
            path.addLine(to: point(p, plot: plot))
        }
        let style = StrokeStyle(
            lineWidth: lineWidth,
            lineCap: .round,
            lineJoin: .round,
            dash: dash ?? []
        )
        if gradient {
            let g = Gradient(colors: [theme.accent, theme.accentSecondary.opacity(0.95)])
            ctx.stroke(
                path,
                with: .linearGradient(
                    g,
                    startPoint: CGPoint(x: plot.minX, y: plot.midY),
                    endPoint: CGPoint(x: plot.maxX, y: plot.midY)
                ),
                style: style
            )
        } else if let color {
            ctx.stroke(path, with: .color(color), style: style)
        }
    }

    // MARK: - Labels

    private func dBLabels(plot: CGRect) -> some View {
        ForEach(yTicks, id: \.self) { g in
            let y = yFor(g, plot: plot)
            Text(g > 0 ? "+\(Int(g))" : "\(Int(g))")
                .font(.app(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(abs(g) < 0.01 ? theme.secondaryText : theme.tertiaryText)
                .position(x: 16, y: y)
        }
    }

    private func frequencyLabels(plot: CGRect) -> some View {
        ForEach(xTicks, id: \.self) { f in
            let x = plot.minX + FrequencyResponse.xPosition(f) * plot.width
            Text(FrequencyResponse.formatFrequencyHz(f))
                .font(.app(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(theme.tertiaryText)
                .position(x: x, y: plot.maxY + 11)
        }
    }

    // MARK: - Peak marker

    private func peakMarker(_ peak: FrequencyResponse.Peak, plot: CGRect) -> some View {
        let pt = point(
            FrequencyResponse.Point(frequency: peak.frequency, magnitudeDB: peak.magnitudeDB),
            plot: plot
        )
        // Keep chip inside plot bounds
        let chipW: CGFloat = 108
        let chipX = min(max(pt.x, plot.minX + chipW / 2 + 4), plot.maxX - chipW / 2 - 4)
        let chipY = max(pt.y - 18, plot.minY + 10)

        return ZStack {
            // Stem
            Path { p in
                p.move(to: CGPoint(x: pt.x, y: pt.y))
                p.addLine(to: CGPoint(x: pt.x, y: min(pt.y + 8, plot.maxY)))
            }
            .stroke(theme.accent.opacity(0.45), lineWidth: 1)

            // Dot
            Circle()
                .fill(theme.accent)
                .frame(width: 6, height: 6)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 0.8))
                .position(pt)

            // Callout
            Text("\(FrequencyResponse.formatGainDB(peak.magnitudeDB))  ·  \(FrequencyResponse.formatFrequencyHz(peak.frequency)) Hz")
                .font(.app(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background {
                    Capsule()
                        .fill(theme.isDark ? Color.black.opacity(0.55) : Color.white.opacity(0.88))
                        .overlay {
                            Capsule()
                                .strokeBorder(theme.accent.opacity(0.35), lineWidth: 0.7)
                        }
                }
                .position(x: chipX, y: chipY)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Geometry

    private func point(_ p: FrequencyResponse.Point, plot: CGRect) -> CGPoint {
        let x = plot.minX + FrequencyResponse.xPosition(p.frequency) * plot.width
        let y = yFor(p.magnitudeDB, plot: plot)
        return CGPoint(x: x, y: y)
    }

    private func yFor(_ db: Double, plot: CGRect) -> CGFloat {
        let t = (db - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)
        let clamped = min(max(t, 0), 1)
        return plot.maxY - clamped * plot.height
    }

    // MARK: - Updates (debounced + skip if unchanged)

    private func scheduleUpdatePoints(for newDual: DualEQState) {
        if let lastDual, lastDual == newDual { return }
        graphUpdateTask?.cancel()
        graphUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 36_000_000) // ~2 frames while dragging
            guard !Task.isCancelled else { return }
            updatePoints(force: false)
        }
    }

    private func updatePoints(force: Bool) {
        if !force, let lastDual, lastDual == dual { return }
        lastDual = dual
        let pack = FrequencyResponse.curves(dual: dual)
        combinedPoints = pack.combined
        targetPoints = pack.target
        finePoints = pack.fine
        peak = dual.isBypassed ? nil : FrequencyResponse.peak(of: pack.combined)
    }

    private var accessibilitySummary: String {
        if dual.isBypassed { return "Equalizer frequency response, bypassed" }
        if let peak {
            return "Equalizer frequency response, peak \(FrequencyResponse.formatGainDB(peak.magnitudeDB)) at \(FrequencyResponse.formatFrequencyHz(peak.frequency)) hertz"
        }
        return "Equalizer frequency response graph"
    }
}
