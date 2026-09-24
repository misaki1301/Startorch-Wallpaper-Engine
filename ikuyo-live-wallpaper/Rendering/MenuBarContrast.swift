import CoreGraphics
import Foundation

/// Estimates whether menu bar text would be legible over a wallpaper.
///
/// macOS picks dark or light menu bar text from the desktop picture's overall brightness. That
/// works over calm areas but fails where the strip under the menu bar mixes bright and dark
/// patches: wherever the chosen text color has too little contrast with what's behind it. This
/// looks at the top of the picture (about the menu bar's height), applies the wallpaper's dim,
/// and reports how much of the strip falls below a 3:1 contrast ratio (WCAG's minimum for large
/// or bold text) with the text color macOS would choose. Blur and vignette are not modeled.
nonisolated enum MenuBarContrast {
    /// Menu bar height in points.
    static let menuBarHeight: CGFloat = 24
    static let minimumContrast = 3.0
    /// The share of the strip allowed to fall below `minimumContrast` before we warn.
    static let tolerance = 0.2

    struct Analysis: Equatable, Sendable {
        /// Average relative luminance of the strip, 0 (black) – 1 (white).
        var meanLuminance: Double
        /// Whether macOS would draw dark text (over a bright strip).
        var usesDarkText: Bool
        /// Share of the strip where that text would have less than `minimumContrast`.
        var lowContrastFraction: Double

        var isHardToRead: Bool { lowContrastFraction > MenuBarContrast.tolerance }
    }

    /// Relative luminance (WCAG 2) of an sRGB color with components in 0...1.
    static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two relative luminances, 1...21.
    static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Analyzes the top of `image` as it would sit under the menu bar of a display `screenHeight`
    /// points tall (the image filling the display), with `dim` (0...1) applied. Nil if the image
    /// can't be read.
    static func analyze(_ image: CGImage, screenHeight: CGFloat = 982, dim: Double = 0) -> Analysis? {
        guard image.width > 0, image.height > 0, screenHeight > 0 else { return nil }
        let rows = max(1, Int((CGFloat(image.height) * menuBarHeight / screenHeight).rounded(.up)))
        guard let strip = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: min(rows, image.height))),
              let samples = samples(of: strip) else { return nil }

        let keep = 1 - min(max(dim, 0), 1)
        let luminances = samples.map { relativeLuminance(red: $0.0 * keep, green: $0.1 * keep, blue: $0.2 * keep) }
        let mean = luminances.reduce(0, +) / Double(luminances.count)
        let usesDarkText = contrastRatio(mean, 0) >= contrastRatio(mean, 1)
        let text = usesDarkText ? 0.0 : 1.0
        let low = luminances.filter { contrastRatio($0, text) < minimumContrast }.count
        return Analysis(
            meanLuminance: mean,
            usesDarkText: usesDarkText,
            lowContrastFraction: Double(low) / Double(luminances.count)
        )
    }

    /// The strip scaled down to a grid of sRGB samples, roughly glyph-sized areas.
    private static func samples(of strip: CGImage) -> [(Double, Double, Double)]? {
        let width = min(64, strip.width)
        let height = min(4, strip.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        return (0..<(width * height)).map { index in
            let alpha = Double(pixels[index * 4 + 3]) / 255
            // Transparent areas count as black, like the desktop behind them.
            guard alpha > 0 else { return (0, 0, 0) }
            return (
                Double(pixels[index * 4]) / 255,
                Double(pixels[index * 4 + 1]) / 255,
                Double(pixels[index * 4 + 2]) / 255
            )
        }
    }
}
