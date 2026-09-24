import AVFoundation
import CoreImage
import QuartzCore

/// The layers that draw one wallpaper on one display: the video, then a dim overlay and a
/// vignette on top.
///
/// Energy: dim and vignette are static layers the window server composites once per frame for
/// free. Blur is a Core Image filter on the video layer, so every video frame is blurred on the
/// GPU and the video can no longer go straight to the display; expect noticeably more GPU work
/// (and some CPU) while it's on. Speed is a playback rate and decodes fewer frames per second.
/// The host view must set `layerUsesCoreImageFilters` for the blur to render.
final class WallpaperLayerStack {
    let root = CALayer()
    let playerLayer: AVPlayerLayer
    private let dimLayer = CALayer()
    private let vignetteLayer = CAGradientLayer()
    private(set) var readability = ReadabilitySettings()

    init(player: AVPlayer, readability: ReadabilitySettings, frame: CGRect) {
        playerLayer = AVPlayerLayer(player: player)

        root.frame = frame
        root.masksToBounds = true
        // Follows the window when the display's resolution changes.
        root.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.backgroundColor = CGColor(gray: 0, alpha: 1)

        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = root.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        dimLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        dimLayer.frame = root.bounds
        dimLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        vignetteLayer.type = .radial
        vignetteLayer.colors = Self.vignetteColors
        vignetteLayer.locations = Self.vignetteLocations
        vignetteLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        // A radial gradient's end point sets the ellipse's radii; this one reaches the corners.
        vignetteLayer.endPoint = CGPoint(x: 0.5 + 0.5 * 2.0.squareRoot(), y: 0.5 + 0.5 * 2.0.squareRoot())
        vignetteLayer.frame = root.bounds
        vignetteLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        root.addSublayer(playerLayer)
        root.addSublayer(dimLayer)
        root.addSublayer(vignetteLayer)
        apply(readability, force: true)
    }

    private static let vignetteLocations: [NSNumber] = [0, NSNumber(value: ReadabilitySettings.vignetteInnerRadius), 1]
    private static let vignetteColors: [CGColor] = [
        CGColor(gray: 0, alpha: 0),
        CGColor(gray: 0, alpha: 0),
        CGColor(gray: 0, alpha: ReadabilitySettings.vignetteOpacity),
    ]

    func apply(_ readability: ReadabilitySettings) {
        apply(readability, force: false)
    }

    private func apply(_ readability: ReadabilitySettings, force: Bool) {
        guard force || readability != self.readability else { return }
        let blurChanged = force || readability.blur != self.readability.blur
        self.readability = readability

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.opacity = Float(readability.dim)
        dimLayer.isHidden = readability.dim <= 0
        vignetteLayer.isHidden = !readability.vignette
        if blurChanged {
            if readability.blur > 0, let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(readability.blur, forKey: kCIInputRadiusKey)
                playerLayer.filters = [blur]
                // Blurring pulls in black from beyond the edges; drawing the video a little larger
                // than the display keeps the edges clean.
                let outset = readability.blur * 2
                playerLayer.frame = root.bounds.insetBy(dx: -outset, dy: -outset)
            } else {
                playerLayer.filters = nil
                playerLayer.frame = root.bounds
            }
        }
        CATransaction.commit()
    }

    /// Stops drawing: releases the player and leaves the layer tree.
    func detach() {
        playerLayer.player = nil
        root.removeFromSuperlayer()
    }
}
