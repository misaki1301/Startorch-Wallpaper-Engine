import AVFoundation
import SwiftUI

/// Small posters (a frame one second in) shared by the Displays view, kept in memory.
enum PosterCache {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    static func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    static func poster(for url: URL, maximumSize: CGSize = CGSize(width: 640, height: 400)) async -> NSImage? {
        if let image = cached(url) { return image }
        // Prefer the offline copy, so a downloaded wallpaper never hits the network.
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: WallpaperCacheManager.resolvedURL(for: url)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        guard let cgImage = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 1)).image else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: .zero)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// A wallpaper's poster, filling its frame.
struct PosterImage: View {
    let url: URL?

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.fill.tertiary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if url != nil {
                ProgressView().controlSize(.small)
            }
        }
        .clipped()
        .task(id: url) {
            image = url.flatMap(PosterCache.cached)
            guard let url, image == nil else { return }
            image = await PosterCache.poster(for: url)
        }
    }
}
