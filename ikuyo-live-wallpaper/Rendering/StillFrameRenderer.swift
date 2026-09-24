import CoreGraphics
import CoreImage

/// Bakes a wallpaper's readability settings into its still frame.
///
/// The still frame is the real desktop picture while a wallpaper runs. macOS picks the menu bar's
/// text color from it and shows it in Mission Control and whenever our window fades, so it
/// should look like the dimmed / blurred / vignetted video rather than the raw first frame.
nonisolated enum StillFrameRenderer {
    /// Blends in (non-linear) sRGB, like the dim and vignette layers over the video do, so the
    /// frame matches what's on screen. Core Image's default linear working space would make the
    /// same dim look much lighter.
    private static let context = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
    ])

    /// `image` with `readability` applied. `pointScale` is pixels per point (the blur radius is
    /// in points). Returns the image unchanged when nothing alters it.
    static func render(_ image: CGImage, readability: ReadabilitySettings, pointScale: CGFloat = 2) -> CGImage {
        guard readability.altersImage else { return image }
        var output = CIImage(cgImage: image)
        let extent = output.extent

        if readability.blur > 0 {
            output = output.clampedToExtent()
                .applyingGaussianBlur(sigma: readability.blur * pointScale)
                .cropped(to: extent)
        }
        if readability.dim > 0 {
            output = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: readability.dim))
                .cropped(to: extent)
                .composited(over: output)
        }
        if readability.vignette, let gradient = vignette(in: extent) {
            output = gradient.composited(over: output)
        }
        return context.createCGImage(output, from: extent) ?? image
    }

    /// The same radial darkening as `WallpaperLayerStack`'s vignette layer.
    private static func vignette(in extent: CGRect) -> CIImage? {
        let halfDiagonal = hypot(extent.width, extent.height) / 2
        guard let filter = CIFilter(name: "CIRadialGradient") else { return nil }
        filter.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: "inputCenter")
        filter.setValue(halfDiagonal * ReadabilitySettings.vignetteInnerRadius, forKey: "inputRadius0")
        filter.setValue(halfDiagonal, forKey: "inputRadius1")
        filter.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor0")
        filter.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: ReadabilitySettings.vignetteOpacity), forKey: "inputColor1")
        return filter.outputImage?.cropped(to: extent)
    }
}
