//
//  TrackRowView.swift
//  EQtargetsMusic
//

import SwiftUI

struct TrackRowView: View {
    let track: Track
    var isPlaying: Bool = false
    var trackIndex: Int? = nil

    @Environment(\.grokTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            if let trackIndex {
                Text("\(trackIndex)")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(isPlaying ? theme.accent : theme.tertiaryText)
                    .frame(width: 24, alignment: .center)
            }

            artwork
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(isPlaying ? theme.accent : theme.primaryText)
                    .lineLimit(1)
                Text("\(track.artist) · \(track.album)")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if track.hasBPM, let bpm = track.bpm {
                Text(String(format: "%.0f", bpm))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.accent.opacity(0.14)))
                    .accessibilityLabel(String(format: "%.0f BPM", bpm))
            }

            if track.duration > 0 {
                Text(formatDuration(track.duration))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
            }

            if isPlaying {
                // Static icon — continuous symbolEffect was burning scroll frames.
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
                theme.elevated
                Image(systemName: "music.note")
                    .foregroundStyle(theme.tertiaryText)
            }
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
