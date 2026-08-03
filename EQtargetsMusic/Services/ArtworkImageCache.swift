//
//  ArtworkImageCache.swift
//  EQtargetsMusic
//
//  List thumbs stay small; hero art can load a higher-res cover from the file.
//

import UIKit
import AVFoundation

enum ArtworkImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 400
        c.totalCostLimit = 40 * 1024 * 1024
        return c
    }()

    private static let heroCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 40
        c.totalCostLimit = 80 * 1024 * 1024
        return c
    }()

    /// List / mini-player thumbnail (uses embedded small catalog JPEG).
    static func image(trackID: UUID, data: Data?) -> UIImage? {
        guard let data, !data.isEmpty else { return nil }
        let key = trackID.uuidString as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = decode(data: data, maxPixelSide: 256) else { return nil }
        cache.setObject(img, forKey: key, cost: data.count)
        return img
    }

    static func image(dataKey: String, data: Data?) -> UIImage? {
        guard let data, !data.isEmpty else { return nil }
        let key = dataKey as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = decode(data: data, maxPixelSide: 256) else { return nil }
        cache.setObject(img, forKey: key, cost: data.count)
        return img
    }

    /// Full-player cover: prefer full metadata art from disk, scaled for retina display.
    /// Falls back to the list thumb while loading / if file art is missing.
    static func heroImage(
        trackID: UUID,
        thumbData: Data?,
        fileURL: URL?,
        maxPointSide: CGFloat
    ) async -> UIImage? {
        let scale = await MainActor.run { UIScreen.main.scale }
        let maxPixels = max(maxPointSide * scale, 600)
        let heroKey = "hero-\(trackID.uuidString)-\(Int(maxPixels))" as NSString

        if let hit = heroCache.object(forKey: heroKey) {
            return hit
        }

        // Prefer full-res cover from the audio file.
        if let fileURL {
            if let full = await loadEmbeddedArtwork(from: fileURL),
               let img = decode(data: full, maxPixelSide: maxPixels) {
                heroCache.setObject(img, forKey: heroKey, cost: Int(maxPixels * maxPixels * 4))
                return img
            }
        }

        // Fallback: upscale-friendly decode of catalog thumb (better than raw blurry 96px blit).
        if let thumbData, let img = decode(data: thumbData, maxPixelSide: min(maxPixels, 512)) {
            heroCache.setObject(img, forKey: heroKey, cost: thumbData.count)
            return img
        }
        return nil
    }

    // MARK: - Decode / load

    private static func decode(data: Data, maxPixelSide: CGFloat) -> UIImage? {
        // Prefer ImageIO so we don't decode megapixel covers into full RAM when possible.
        if let down = downsampled(data: data, maxPixelSide: maxPixelSide) {
            return down
        }
        guard let image = UIImage(data: data) else { return nil }
        return resized(image, maxPixelSide: maxPixelSide)
    }

    private static func downsampled(data: Data, maxPixelSide: CGFloat) -> UIImage? {
        let srcOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, srcOptions as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSide, 64)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    private static func resized(_ image: UIImage, maxPixelSide: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let longest = max(size.width, size.height)
        guard longest > maxPixelSide else { return image }
        let scale = maxPixelSide / longest
        let newSize = CGSize(width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private static func loadEmbeddedArtwork(from url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        do {
            let meta = try await asset.load(.commonMetadata)
            for item in meta where item.commonKey == .commonKeyArtwork {
                if let d = try? await item.load(.dataValue), !d.isEmpty {
                    return d
                }
            }
        } catch {
            return nil
        }
        return nil
    }
}
