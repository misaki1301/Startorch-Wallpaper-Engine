import Foundation

/// How a wallpaper is toned down so icons and the menu bar stay legible. Stored per wallpaper.
nonisolated struct ReadabilitySettings: Codable, Hashable, Sendable {
    static let dimRange: ClosedRange<Double> = 0...0.6
    static let blurRange: ClosedRange<Double> = 0...20
    static let speedRange: ClosedRange<Double> = 0.5...1

    /// The vignette's look, shared by the desktop layers, the still frame and the preview: clear
    /// out to `vignetteInnerRadius` of the half-diagonal, then darkening to `vignetteOpacity`.
    static let vignetteOpacity = 0.55
    static let vignetteInnerRadius = 0.55

    /// Black overlay opacity, 0–60%.
    var dim: Double
    /// Gaussian blur radius in points, 0–20.
    var blur: Double
    /// Darkens the edges and corners.
    var vignette: Bool
    /// Playback rate, 0.5×–1× ("ambient" speed).
    var speed: Double

    init(dim: Double = 0, blur: Double = 0, vignette: Bool = false, speed: Double = 1) {
        self.dim = dim.clamped(to: Self.dimRange)
        self.blur = blur.clamped(to: Self.blurRange)
        self.vignette = vignette
        self.speed = speed.clamped(to: Self.speedRange)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dim: try container.decodeIfPresent(Double.self, forKey: .dim) ?? 0,
            blur: try container.decodeIfPresent(Double.self, forKey: .blur) ?? 0,
            vignette: try container.decodeIfPresent(Bool.self, forKey: .vignette) ?? false,
            speed: try container.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        )
    }

    /// Values outside the allowed ranges pulled back in.
    var clamped: ReadabilitySettings {
        ReadabilitySettings(dim: dim, blur: blur, vignette: vignette, speed: speed)
    }

    var isDefault: Bool { self == ReadabilitySettings() }

    /// Whether anything changes the picture itself (speed doesn't).
    var altersImage: Bool { dim > 0 || blur > 0 || vignette }

    /// A short, file-name-safe summary of what alters the picture, so a still frame rendered with
    /// these settings gets its own file.
    var imageFingerprint: String {
        guard altersImage else { return "plain" }
        return "d\(Int((dim * 100).rounded()))b\(Int((blur * 10).rounded()))v\(vignette ? 1 : 0)"
    }
}

private extension Comparable {
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
