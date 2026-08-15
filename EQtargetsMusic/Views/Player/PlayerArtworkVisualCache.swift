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
        if s < 0.08, b < 0.18 { return nil }
        if s < 0.07, b > 0.90 { return nil }
        if b < 0.06 { return nil }
        // Keep cover hue; mild sat lift, readable mid brightness on OLED black.
        let sat = min(0.86, max(0.32, s * 1.22))
        let bri = min(0.68, max(0.30, b * 0.95))
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
    private static let clusterCount = 6
    private static let downsampleSide: CGFloat = 72
    private static let kMeansIterations = 12

    /// Bump when extraction logic changes so in-session cache can be cleared if needed.
    private static let extractVersion = 2

    static func prewarm(track: Track, accent: Color) {
        _ = visuals(for: track, accent: accent)
    }

    static func clearCache() {
        lock.lock()
        paletteCache.removeAll(keepingCapacity: true)
        lock.unlock()
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

    private static var loadedExtractVersion: Int = -1

    private static func palette(for track: Track, image: UIImage?) -> ArtworkPalette {
        lock.lock()
        if loadedExtractVersion != extractVersion {
            paletteCache.removeAll(keepingCapacity: true)
            loadedExtractVersion = extractVersion
        }
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

    // MARK: - Dominant colors (center-weighted k-means + chroma rank)

    /// Up to 6 cover-matching colors: frequency × saturation, white mats / pure black down-weighted.
    private static func extractDominantColors(from image: UIImage) -> [RGBAColor]? {
        guard let samples = rasterPixelsWeighted(image, side: downsampleSide), !samples.isEmpty else {
            return nil
        }
        let pixels = samples.map(\.rgb)
        let weights = samples.map(\.w)

        let k = min(clusterCount, max(3, pixels.count / 10))
        var centroids = seedCentroidsKMeansPP(from: pixels, weights: weights, k: k)
        var assignments = [Int](repeating: 0, count: pixels.count)

        for _ in 0 ..< kMeansIterations {
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
            var sums = Array(repeating: (r: 0.0, g: 0.0, b: 0.0, n: 0.0), count: k)
            for (i, p) in pixels.enumerated() {
                let a = assignments[i]
                let w = weights[i]
                sums[a].r += p.r * w
                sums[a].g += p.g * w
                sums[a].b += p.b * w
                sums[a].n += w
            }
            for ci in 0 ..< k {
                if sums[ci].n > 1e-6 {
                    let n = sums[ci].n
                    centroids[ci] = RGB(r: sums[ci].r / n, g: sums[ci].g / n, b: sums[ci].b / n)
                }
            }
        }

        var weightByCluster = [Double](repeating: 0, count: k)
        for (i, a) in assignments.enumerated() {
            weightByCluster[a] += weights[i]
        }

        // Score = mass × chroma so gray mats lose to real album hues.
        var ranked: [(RGB, Double)] = []
        for ci in 0 ..< k {
            guard weightByCluster[ci] > 0 else { continue }
            let c = centroids[ci]
            let chroma = max(c.r, c.g, c.b) - min(c.r, c.g, c.b)
            let sat = chroma / max(max(c.r, c.g, c.b), 1e-6)
            let score = weightByCluster[ci] * (0.35 + sat * 1.4)
            ranked.append((c, score))
        }
        ranked.sort { $0.1 > $1.1 }

        var result: [RGBAColor] = []
        for (rgb, _) in ranked {
            let color = softEnhanceForUI(RGBAColor(red: rgb.r, green: rgb.g, blue: rgb.b))
            // Skip pure ink / paper mats after ranking (unless nothing else).
            if isMatteNeutral(color), result.count >= 1 { continue }
            if result.contains(where: { colorDistance($0, color) < 0.06 }) { continue }
            result.append(color)
            if result.count >= 6 { break }
        }
        if result.isEmpty, let first = ranked.first {
            result = [softEnhanceForUI(RGBAColor(red: first.0.r, green: first.0.g, blue: first.0.b))]
        }
        _ = extractVersion
        return result.isEmpty ? nil : result
    }

    private static func isMatteNeutral(_ c: RGBAColor) -> Bool {
        let mx = max(c.red, c.green, c.blue)
        let mn = min(c.red, c.green, c.blue)
        let chroma = mx - mn
        if chroma < 0.06, mx > 0.88 { return true } // white mat
        if chroma < 0.05, mx < 0.12 { return true } // pure black
        return false
    }

    /// Mild sat lift + soft highlight pull — keeps cover hue, better glow on OLED.
    private static func softEnhanceForUI(_ c: RGBAColor) -> RGBAColor {
        let ui = UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return c }
        var sat = s
        var bri = b
        if b > 0.90 { bri = 0.86 }
        if s > 0.12, s < 0.85 { sat = min(0.92, s * 1.12) }
        return RGBAColor(UIColor(hue: h, saturation: sat, brightness: bri, alpha: 1))
    }

    private struct RGB {
        var r: Double
        var g: Double
        var b: Double
    }

    private struct WeightedRGB {
        var rgb: RGB
        var w: Double
    }

    /// DeviceRGB RGBA buffer (fixes BGRA R↔B swaps) + center weighting + mat filter.
    private static func rasterPixelsWeighted(_ image: UIImage, side: CGFloat) -> [WeightedRGB]? {
        let w = Int(side)
        let h = Int(side)
        let bytesPerPixel = 4
        let bytesPerRow = w * bytesPerPixel
        var data = [UInt8](repeating: 0, count: w * h * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &data,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Draw UIImage oriented correctly
        UIGraphicsPushContext(ctx)
        image.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        UIGraphicsPopContext()

        let cx = Double(w - 1) / 2
        let cy = Double(h - 1) / 2
        let maxDist = sqrt(cx * cx + cy * cy)

        var out: [WeightedRGB] = []
        out.reserveCapacity(w * h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = (y * w + x) * 4
                let r = Double(data[i]) / 255
                let g = Double(data[i + 1]) / 255
                let b = Double(data[i + 2]) / 255
                let mx = max(r, g, b)
                let mn = min(r, g, b)
                let chroma = mx - mn

                // Drop pure white borders / pure black letterbox (common on square art).
                var wgt = 1.0
                if chroma < 0.05, mx > 0.92 { wgt = 0.08 } // white mat
                else if chroma < 0.04, mx < 0.08 { wgt = 0.12 } // black bars
                else if chroma < 0.06 { wgt = 0.35 } // gray

                // Center-weighted: subject usually in middle of cover.
                let dx = Double(x) - cx
                let dy = Double(y) - cy
                let t = 1.0 - min(1.0, sqrt(dx * dx + dy * dy) / maxDist)
                wgt *= 0.45 + 0.55 * t * t

                // Slight boost for colorful pixels so k-means cares about album ink.
                wgt *= 0.55 + chroma * 1.2

                out.append(WeightedRGB(rgb: RGB(r: r, g: g, b: b), w: max(wgt, 0.02)))
            }
        }
        return out
    }

    private static func seedCentroidsKMeansPP(from pixels: [RGB], weights: [Double], k: Int) -> [RGB] {
        guard !pixels.isEmpty else { return [] }
        var centroids: [RGB] = []
        // First seed: highest weight sample
        var bestI = 0
        var bestW = -1.0
        for i in pixels.indices where weights[i] > bestW {
            bestW = weights[i]
            bestI = i
        }
        centroids.append(pixels[bestI])

        while centroids.count < k {
            var distSum = 0.0
            var dists = [Double](repeating: 0, count: pixels.count)
            for i in pixels.indices {
                var minD = Double.greatestFiniteMagnitude
                for c in centroids {
                    minD = min(minD, dist2(pixels[i], c))
                }
                let d = minD * weights[i]
                dists[i] = d
                distSum += d
            }
            if distSum < 1e-12 {
                centroids.append(pixels[pixels.count / 2])
                continue
            }
            var r = Double.random(in: 0 ..< distSum)
            var picked = pixels.count - 1
            for i in pixels.indices {
                r -= dists[i]
                if r <= 0 { picked = i; break }
            }
            centroids.append(pixels[picked])
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
