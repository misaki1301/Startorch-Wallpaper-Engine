import AVFoundation
import AppKit

/// A small, shared helper for grabbing a single still frame from a video — used anywhere a
/// compact poster is needed (the menu bar panel's Now Playing thumbnail and favorites strip).
enum VideoThumbnailLoader {
    static func thumbnail(for url: URL, maxSize: CGSize) async -> NSImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        do {
            let cgImage = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 1)).image
            return NSImage(cgImage: cgImage, size: .zero)
        } catch {
            return nil
        }
    }
}
