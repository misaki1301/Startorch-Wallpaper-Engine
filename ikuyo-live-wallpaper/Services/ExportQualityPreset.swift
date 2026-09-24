import CoreGraphics
import Foundation

/// What the import studio asks the encoder for, in words people pick instead of codec numbers.
/// Every preset writes HEVC; they differ in how big, how smooth and how heavy the result is.
nonisolated enum ExportQualityPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case batterySaver
    case balanced
    case best

    static let `default` = ExportQualityPreset.balanced

    var id: Self { self }

    var title: String {
        switch self {
        case .batterySaver: String(localized: "Battery Saver")
        case .balanced: String(localized: "Balanced")
        case .best: String(localized: "Best")
        }
    }

    var summary: String {
        switch self {
        case .batterySaver: String(localized: "Up to 1080p at 24 fps. Smallest file, lightest to play.")
        case .balanced: String(localized: "Up to 4K at 30 fps. Looks great on most displays.")
        case .best: String(localized: "Source resolution and frame rate at a high bitrate.")
        }
    }

    /// The box the upright picture must fit in, as (long side, short side). `nil` keeps the
    /// source resolution.
    var maximumDimensions: (long: CGFloat, short: CGFloat)? {
        switch self {
        case .batterySaver: (1920, 1080)
        case .balanced: (3840, 2160)
        case .best: nil
        }
    }

    /// `nil` keeps the source frame rate.
    var maximumFrameRate: Float? {
        switch self {
        case .batterySaver: 24
        case .balanced: 30
        case .best: nil
        }
    }

    /// HEVC bits per pixel per frame. Wallpapers are mostly slow, soft motion, so these sit
    /// well below what fast camera footage would need.
    var bitsPerPixel: Double {
        switch self {
        case .batterySaver: 0.04
        case .balanced: 0.07
        case .best: 0.12
        }
    }

    /// Never ask for more than this fraction of the source's own bitrate: re-encoding can't add
    /// detail that isn't there, it only makes the file bigger.
    var sourceBitrateFraction: Double {
        switch self {
        case .batterySaver: 0.35
        case .balanced: 0.5
        case .best: 0.8
        }
    }

    static let minimumBitrate = 400_000

    /// Maps a source (upright size, frame rate and bitrate in bits/s, 0 when unknown) to the
    /// encoder settings this preset produces.
    func outputSettings(
        sourceSize: CGSize,
        sourceFrameRate: Float,
        sourceBitrate: Float
    ) -> ExportOutputSettings {
        let renderSize = Self.fittedSize(sourceSize, within: maximumDimensions)
        let sourceRate = VideoConverter.effectiveFrameRate(sourceFrameRate)
        let frameRate = maximumFrameRate.map { min($0, sourceRate) } ?? sourceRate

        var bitrate = Double(renderSize.width * renderSize.height) * Double(frameRate) * bitsPerPixel
        if sourceBitrate.isFinite, sourceBitrate > 0 {
            bitrate = min(bitrate, Double(sourceBitrate) * sourceBitrateFraction)
        }
        return ExportOutputSettings(
            renderSize: renderSize,
            frameRate: frameRate,
            bitrate: max(Self.minimumBitrate, Int(bitrate.rounded()))
        )
    }

    /// Scales `size` down (never up) to fit `box` in its own orientation, so a portrait clip is
    /// held to 1080×1920 rather than 1920×1080. Encoders need even dimensions.
    static func fittedSize(_ size: CGSize, within box: (long: CGFloat, short: CGFloat)?) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        var scale: CGFloat = 1
        if let box {
            let long = max(size.width, size.height)
            let short = min(size.width, size.height)
            scale = min(1, box.long / long, box.short / short)
        }
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * scale / 2).rounded(.down) * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }
}

/// The encoder side of an export: the picture size, the frame rate the video composition
/// renders at, and the average HEVC bitrate.
nonisolated struct ExportOutputSettings: Equatable, Sendable {
    var renderSize: CGSize
    var frameRate: Float
    /// Bits per second.
    var bitrate: Int

    /// Roughly how big `seconds` of this output will be. Only an estimate: the encoder spends
    /// fewer bits on still scenes and more on busy ones.
    func estimatedFileSize(seconds: Double) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(Double(bitrate) / 8 * seconds)
    }
}
