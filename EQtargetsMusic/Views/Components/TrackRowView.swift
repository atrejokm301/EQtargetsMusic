//
//  TrackRowView.swift
//  EQtargetsMusic
//

import SwiftUI

struct TrackRowView: View {
    let track: Track
    var isPlaying: Bool = false
    var trackIndex: Int? = nil
    /// Brighter labels for dark glass surfaces (queue sheet).
    var highContrast: Bool = false

    @Environment(\.grokTheme) private var theme

    private var titleColor: Color {
        if isPlaying { return theme.accent }
        return highContrast ? Color.white.opacity(0.96) : theme.primaryText
    }

    private var subtitleColor: Color {
        highContrast ? Color.white.opacity(0.72) : theme.secondaryText
    }

    private var metaColor: Color {
        highContrast ? Color.white.opacity(0.55) : theme.tertiaryText
    }

    var body: some View {
        HStack(spacing: 12) {
            if let trackIndex {
                Text("\(trackIndex)")
                    .font(.app(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(isPlaying ? theme.accent : metaColor)
                    .frame(width: 24, alignment: .center)
            }

            artwork
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.app(size: 16, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Text("\(track.artist) · \(track.album)")
                    .font(.app(size: 13, weight: .medium))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if track.hasBPM, let bpm = track.bpm {
                Text(String(format: "%.0f", bpm))
                    .font(.app(size: 10, weight: .bold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule(style: .continuous).fill(theme.accent.opacity(highContrast ? 0.22 : 0.14)))
                    .accessibilityLabel(String(format: "%.0f BPM", bpm))
            }

            if track.duration > 0 {
                Text(formatDuration(track.duration))
                    .font(.app(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(metaColor)
            }

            if isPlaying {
                Image(systemName: "waveform")
                    .foregroundStyle(theme.accent)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(track.title), \(track.artist), \(track.album)")
    }

    @ViewBuilder
    private var artwork: some View {
        if let img = ArtworkImageCache.image(trackID: track.id, data: track.artworkData) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                (highContrast ? Color.white.opacity(0.10) : theme.elevated)
                Image(systemName: "music.note")
                    .foregroundStyle(metaColor)
            }
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
