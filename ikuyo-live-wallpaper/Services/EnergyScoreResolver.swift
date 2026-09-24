import AVFoundation

/// Resolves an `EnergyScore` for a wallpaper: catalog entries already carry resolution/fps/
/// bitrate, but imported and local files don't, so those are probed once via `AVAsset` and
/// cached in memory — a card never re-reads the same file twice.
actor EnergyScoreResolver {
    static let shared = EnergyScoreResolver()

    private var cache: [URL: EnergyScore] = [:]
    /// Injectable so tests don't need a real, readable video file on disk. `@Sendable` because
    /// it's created outside the actor (often on `@MainActor`) and called from inside it.
    private let probe: @Sendable (URL) async -> EnergyScore

    init(probe: @escaping @Sendable (URL) async -> EnergyScore = EnergyScoreResolver.probeAsset) {
        self.probe = probe
    }

    /// Uses `item`'s own metadata when the catalog provided it; otherwise probes the file at
    /// `item.url`. The result is cached under `item.url`.
    func score(for item: WallpaperItem) async -> EnergyScore {
        if let cached = cache[item.url] { return cached }

        let score: EnergyScore
        if item.width != nil || item.height != nil || item.fps != nil || item.bitrate != nil {
            score = EnergyScore.score(width: item.width, height: item.height, fps: item.fps, bitrate: item.bitrate)
        } else {
            score = await probe(item.url)
        }
        cache[item.url] = score
        return score
    }

    /// Reads a video track's natural size, nominal frame rate and estimated data rate. Any
    /// field AVFoundation can't report is left out of the score rather than failing it.
    nonisolated static func probeAsset(_ url: URL) async -> EnergyScore {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return .low
        }
        guard let (size, fps, dataRate) = try? await track.load(.naturalSize, .nominalFrameRate, .estimatedDataRate) else {
            return .low
        }
        return EnergyScore.score(
            width: Int(size.width),
            height: Int(size.height),
            fps: Double(fps),
            bitrate: Int(dataRate)
        )
    }
}
