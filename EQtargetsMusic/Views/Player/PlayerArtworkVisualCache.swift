//
//  PlayerArtworkVisualCache.swift
//  EQtargetsMusic
//
//  Real dominant-color extraction from album art (frequency-ranked clusters).
//  UI-only. Cached once per track ID. No audio / engine involvement.
//

import SwiftUI
import UIKit

// MARK: - Color model

struct RGBAColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    init(_ ui: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
    }

    var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}

/// Frequency-ranked real colors from artwork (or empty when no art).
struct ArtworkPalette: Codable, Equatable {
    let trackID: UUID?
    /// Dominant colors most → least frequent. Empty ⇒ no artwork.
    let colors: [RGBAColor]
    let isDarkArtwork: Bool
    let hasArtwork: Bool

    static let matteBlack = ArtworkPalette(
        trackID: nil,
        colors: [],
        isDarkArtwork: true,
        hasArtwork: false
    )

    static func matteBlack(trackID: UUID?) -> ArtworkPalette {
        ArtworkPalette(trackID: trackID, colors: [], isDarkArtwork: true, hasArtwork: false)
    }
}

/// UI-facing visuals for player + queue.
struct PlayerArtworkVisuals: Equatable {
    let trackID: UUID?
    /// Frequency-ranked real colors (empty when no art).
    let dominantColors: [Color]
    let isDarkArtwork: Bool
    let hasArtwork: Bool
    let thumb: UIImage?

    /// Compatibility aliases used by gradient builders.
    var tint: Color { dominantColors.first ?? .black }
    var tintDeep: Color { dominantColors.dropFirst().first ?? dominantColors.first ?? .black }
    var accentWash: Color { dominantColors.dropFirst(2).first ?? dominantColors.first ?? .black }
    var surface: Color { hasArtwork ? (isDarkArtwork ? Color(white: 0.06) : Color(white: 0.12)) : .black }

    static func matteBlack(trackID: UUID? = nil) -> PlayerArtworkVisuals {
        PlayerArtworkVisuals(
            trackID: trackID,
            dominantColors: [],
            isDarkArtwork: true,
            hasArtwork: false,
            thumb: nil
        )
    }

    /// Legacy name used by root / fallbacks — pure matte black when no art.
    static func brandedFallback(accent: Color) -> PlayerArtworkVisuals {
        _ = accent
        return matteBlack(trackID: nil)
    }

    static func from(palette: ArtworkPalette, thumb: UIImage?) -> PlayerArtworkVisuals {
        PlayerArtworkVisuals(
            trackID: palette.trackID,
            dominantColors: palette.colors.map(\.color),
            isDarkArtwork: palette.isDarkArtwork,
            hasArtwork: palette.hasArtwork,
            thumb: thumb
        )
    }

    static func == (lhs: PlayerArtworkVisuals, rhs: PlayerArtworkVisuals) -> Bool {
        lhs.trackID == rhs.trackID
            && lhs.hasArtwork == rhs.hasArtwork
            && lhs.isDarkArtwork == rhs.isDarkArtwork
            && lhs.dominantColors.count == rhs.dominantColors.count
    }

    /// Multi-stop gradient colors (real hues only). Empty if no art.
    func gradientStops(maxStops: Int = 5) -> [Color] {
        guard hasArtwork, !dominantColors.isEmpty else { return [] }
        return Array(dominantColors.prefix(maxStops))
    }

    /// Colors tuned for full-player atmosphere: skip near-black/white, lift saturation,
    /// park brightness in a mid band so the room glows without looking muddy or neon.
    func atmosphericColors(maxStops: Int = 4) -> [Color] {
        guard hasArtwork else { return [] }
        var out: [Color] = []
        for c in dominantColors {
            guard let tuned = Self.atmosphereTune(c) else { continue }
            if out.contains(where: { Self.approxEqual($0, tuned) }) { continue }
            out.append(tuned)
            if out.count >= maxStops { break }
        }
        // Fallback: if filters ate everything, use softened first dominant.
        if out.isEmpty, let first = dominantColors.first {
            out = [Self.forceAtmosphere(first)]
        }
        return out
    }

    private static func atmosphereTune(_ color: Color) -> Color? {
        let ui = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return nil }
        // Skip neutrals / ink / paper — they make the background feel dead.
        if s < 0.10, b < 0.22 { return nil }
        if s < 0.08, b > 0.88 { return nil }
        if b < 0.08 { return nil }
        // Aesthetic mid-room: rich but not fluorescent.
        let sat = min(0.78, max(0.28, s * 1.18))
        let bri = min(0.62, max(0.28, b * 0.92))
        return Color(UIColor(hue: h, saturation: sat, brightness: bri, alpha: 1))
    }

    private static func forceAtmosphere(_ color: Color) -> Color {
        atmosphereTune(color) ?? color.opacity(0.85)
    }

    private static func approxEqual(_ a: Color, _ b: Color) -> Bool {
        let ua = UIColor(a), ub = UIColor(b)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        ua.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        ub.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let dr = Double(r1 - r2), dg = Double(g1 - g2), db = Double(b1 - b2)
        return (dr * dr + dg * dg + db * db) < 0.012
    }
}

// MARK: - Cache

enum PlayerArtworkVisualCache {
    private static let lock = NSLock()
    private static var paletteCache: [UUID: ArtworkPalette] = [:]
    private static let maxEntries = 64
    private static let clusterCount = 5
    private static let downsampleSide: CGFloat = 56
    private static let kMeansIterations = 10

    static func prewarm(track: Track, accent: Color) {
        _ = visuals(for: track, accent: accent)
    }

    static func visuals(for track: Track?, accent: Color) -> PlayerArtworkVisuals {
        _ = accent // no longer invent app-accent palettes for no-art
        guard let track else {
            return PlayerArtworkVisuals.matteBlack(trackID: nil)
        }
        let thumb = ArtworkImageCache.image(trackID: track.id, data: track.artworkData)
        // No artwork data / decode → matte black immediately.
        guard let thumb else {
            return PlayerArtworkVisuals.matteBlack(trackID: track.id)
        }
        let palette = palette(for: track, image: thumb)
        return .from(palette: palette, thumb: thumb)
    }

    static func palette(for track: Track?, accent: Color) -> ArtworkPalette {
        _ = accent
        guard let track else { return ArtworkPalette.matteBlack }
        let thumb = ArtworkImageCache.image(trackID: track.id, data: track.artworkData)
        guard let thumb else { return ArtworkPalette.matteBlack(trackID: track.id) }
        return palette(for: track, image: thumb)
    }

    private static func palette(for track: Track, image: UIImage?) -> ArtworkPalette {
        lock.lock()
        if let hit = paletteCache[track.id] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let built: ArtworkPalette
        if let image, let colors = extractDominantColors(from: image), !colors.isEmpty {
            let lum = colors.prefix(3).map(\.luminance).reduce(0, +) / Double(min(3, colors.count))
            built = ArtworkPalette(
                trackID: track.id,
                colors: colors,
                isDarkArtwork: lum < 0.45,
                hasArtwork: true
            )
        } else {
            built = .matteBlack(trackID: track.id)
        }

        lock.lock()
        if paletteCache.count >= maxEntries {
            let keys = Array(paletteCache.keys.prefix(maxEntries / 2))
            for k in keys { paletteCache.removeValue(forKey: k) }
        }
        paletteCache[track.id] = built
        lock.unlock()
        return built
    }

    // MARK: - Dominant colors (k-means on downsample, rank by frequency)

    /// Returns up to 6 colors sorted by pixel frequency (most dominant first).
    /// Colors keep source saturation/lightness — no synthetic boost/darken inventing hues.
    private static func extractDominantColors(from image: UIImage) -> [RGBAColor]? {
        guard let pixels = rasterPixels(image, side: downsampleSide), !pixels.isEmpty else {
            return nil
        }

        let k = min(clusterCount, max(2, pixels.count / 8))
        var centroids = seedCentroids(from: pixels, k: k)
        var assignments = [Int](repeating: 0, count: pixels.count)

        for _ in 0 ..< kMeansIterations {
            // Assign
            for (i, p) in pixels.enumerated() {
                var best = 0
                var bestD = Double.greatestFiniteMagnitude
                for (ci, c) in centroids.enumerated() {
                    let d = dist2(p, c)
                    if d < bestD {
                        bestD = d
                        best = ci
                    }
                }
                assignments[i] = best
            }
            // Update
            var sums = Array(repeating: (r: 0.0, g: 0.0, b: 0.0, n: 0), count: k)
            for (i, p) in pixels.enumerated() {
                let a = assignments[i]
                sums[a].r += p.r
                sums[a].g += p.g
                sums[a].b += p.b
                sums[a].n += 1
            }
            for ci in 0 ..< k {
                if sums[ci].n > 0 {
                    let n = Double(sums[ci].n)
                    centroids[ci] = RGB(r: sums[ci].r / n, g: sums[ci].g / n, b: sums[ci].b / n)
                }
            }
        }

        // Frequency per cluster
        var counts = [Int](repeating: 0, count: k)
        for a in assignments { counts[a] += 1 }

        var ranked: [(RGB, Int)] = []
        for ci in 0 ..< k {
            guard counts[ci] > 0 else { continue }
            ranked.append((centroids[ci], counts[ci]))
        }
        ranked.sort { $0.1 > $1.1 }

        // Merge near-duplicates; keep distinct real colors. Soften only extreme brights.
        var result: [RGBAColor] = []
        for (rgb, _) in ranked {
            let color = softCapBrightness(RGBAColor(red: rgb.r, green: rgb.g, blue: rgb.b))
            if result.contains(where: { colorDistance($0, color) < 0.07 }) { continue }
            result.append(color)
            if result.count >= 6 { break }
        }
        return result.isEmpty ? nil : result
    }

    /// Soften only extreme highlights for readability — keep hue & most saturation.
    private static func softCapBrightness(_ c: RGBAColor) -> RGBAColor {
        let ui = UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return c }
        // Only pull down near-white glare; do not invent new hues or desaturate.
        if b > 0.92 {
            let capped = UIColor(hue: h, saturation: s, brightness: 0.88, alpha: 1)
            return RGBAColor(capped)
        }
        return c
    }

    private struct RGB {
        var r: Double
        var g: Double
        var b: Double
    }

    private static func rasterPixels(_ image: UIImage, side: CGFloat) -> [RGB]? {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let tiny = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cg = tiny.cgImage,
              let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }

        let length = CFDataGetLength(data)
        let bpp = max(cg.bitsPerPixel / 8, 1)
        var out: [RGB] = []
        out.reserveCapacity(Int(side * side))
        var i = 0
        while i + 2 < length {
            let r = Double(ptr[i]) / 255
            let g = Double(ptr[i + 1]) / 255
            let b = Double(ptr[i + 2]) / 255
            // Keep nearly all pixels — even near-black/white if they dominate the art.
            out.append(RGB(r: r, g: g, b: b))
            i += bpp
        }
        return out
    }

    private static func seedCentroids(from pixels: [RGB], k: Int) -> [RGB] {
        // Spread seeds across the pixel list for stable k-means++-lite init.
        var centroids: [RGB] = []
        let step = max(pixels.count / k, 1)
        for i in 0 ..< k {
            centroids.append(pixels[min(i * step, pixels.count - 1)])
        }
        return centroids
    }

    private static func dist2(_ a: RGB, _ b: RGB) -> Double {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return dr * dr + dg * dg + db * db
    }

    private static func colorDistance(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        let dr = a.red - b.red, dg = a.green - b.green, db = a.blue - b.blue
        return sqrt(dr * dr + dg * dg + db * db)
    }
}
