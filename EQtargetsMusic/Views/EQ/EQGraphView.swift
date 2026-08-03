//
//  EQGraphView.swift
//  EQtargetsMusic
//

import SwiftUI

struct EQGraphView: View {
    let dual: DualEQState
    var yRange: ClosedRange<Double> = -20 ... 20

    @Environment(\.grokTheme) private var theme

    @State private var combinedPoints: [FrequencyResponse.Point] = []
    @State private var targetPoints: [FrequencyResponse.Point] = []
    @State private var finePoints: [FrequencyResponse.Point] = []
    @State private var graphUpdateTask: Task<Void, Never>?

    private let xTicks: [Double] = [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]
    private let yTicks: [Double] = [-20, -10, 0, 10, 20]

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(x: 36, y: 12, width: max(geo.size.width - 48, 1), height: max(geo.size.height - 32, 1))

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.isDark ? Color.white.opacity(0.03) : Color.clear)
                    .background {
                        if !theme.isDark {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.ultraThinMaterial)
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(theme.isDark ? Color.white.opacity(0.02) : Color.black.opacity(0.03))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                Color.white.opacity(theme.isDark ? 0.08 : 0.15),
                                lineWidth: 0.5
                            )
                    }

                Canvas { ctx, _ in
                    for f in xTicks {
                        let x = plot.minX + FrequencyResponse.xPosition(f) * plot.width
                        var p = Path()
                        p.move(to: CGPoint(x: x, y: plot.minY))
                        p.addLine(to: CGPoint(x: x, y: plot.maxY))
                        ctx.stroke(p, with: .color(theme.separator), lineWidth: 1)
                    }
                    for g in yTicks {
                        let t = (g - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)
                        let y = plot.maxY - t * plot.height
                        var p = Path()
                        p.move(to: CGPoint(x: plot.minX, y: y))
                        p.addLine(to: CGPoint(x: plot.maxX, y: y))
                        ctx.stroke(
                            p,
                            with: .color(abs(g) < 0.01 ? theme.secondaryText.opacity(0.35) : theme.separator),
                            lineWidth: abs(g) < 0.01 ? 1.2 : 1
                        )
                    }
                }

                if !dual.isBypassed && !dual.target.isBypassed {
                    path(targetPoints, plot: plot)
                        .stroke(theme.targetTint.opacity(0.65), style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
                }
                if !dual.isBypassed && !dual.fineTune.isBypassed && !dual.fineTune.isFlat {
                    path(finePoints, plot: plot)
                        .stroke(theme.fineTint.opacity(0.7), style: StrokeStyle(lineWidth: 1.4, dash: [2, 3]))
                }

                path(combinedPoints, plot: plot, fill: true)
                    .fill(
                        LinearGradient(
                            colors: [theme.accent.opacity(0.28), theme.accent.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                path(combinedPoints, plot: plot)
                    .stroke(
                        LinearGradient(colors: [theme.accent, theme.accentSecondary], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                    )

                // Axis labels
                ForEach(yTicks, id: \.self) { g in
                    let t = (g - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)
                    let y = plot.maxY - t * plot.height
                    Text(g > 0 ? "+\(Int(g))" : "\(Int(g))")
                        .font(.app(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.tertiaryText)
                        .position(x: 16, y: y)
                }
            }
        }
        .frame(height: 160)
        .accessibilityLabel("Equalizer frequency response graph")
        .onAppear { updatePoints() }
        // Debounce while dragging EQ sliders so we don't recompute 3 curves per sample.
        .onChange(of: dual) { _ in scheduleUpdatePoints() }
    }

    private func scheduleUpdatePoints() {
        graphUpdateTask?.cancel()
        graphUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 32_000_000) // ~2 frames
            guard !Task.isCancelled else { return }
            updatePoints()
        }
    }

    private func updatePoints() {
        combinedPoints = FrequencyResponse.combined(dual: dual)
        targetPoints = FrequencyResponse.curve(layer: dual.target)
        finePoints = FrequencyResponse.curve(layer: dual.fineTune)
    }

    private func path(_ pts: [FrequencyResponse.Point], plot: CGRect, fill: Bool = false) -> Path {
        Path { path in
            guard let first = pts.first else { return }
            let start = point(first, plot: plot)
            if fill {
                path.move(to: CGPoint(x: start.x, y: plot.maxY))
                path.addLine(to: start)
            } else {
                path.move(to: start)
            }
            for p in pts.dropFirst() {
                path.addLine(to: point(p, plot: plot))
            }
            if fill, let last = pts.last {
                let end = point(last, plot: plot)
                path.addLine(to: CGPoint(x: end.x, y: plot.maxY))
                path.closeSubpath()
            }
        }
    }

    private func point(_ p: FrequencyResponse.Point, plot: CGRect) -> CGPoint {
        let x = plot.minX + FrequencyResponse.xPosition(p.frequency) * plot.width
        let t = (p.magnitudeDB - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)
        let y = plot.maxY - t * plot.height
        return CGPoint(x: x, y: y)
    }
}
