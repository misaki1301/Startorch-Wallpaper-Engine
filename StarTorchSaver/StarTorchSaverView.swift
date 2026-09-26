import AppKit
import AVFoundation
import QuartzCore
import ScreenSaver
import os

/// The StarTorch screen saver: plays the clip the app exported to the handoff folder, looping,
/// muted and aspect-filled, with the wallpaper's dim and vignette on top. Falls back to the
/// clip's poster, then to a dark gradient.
///
/// The `legacyScreenSaver` host that runs third-party savers since macOS 14 doesn't reliably call
/// `stopAnimation`, keeps instances alive after the saver ends and makes one instance per display
/// plus one for the System Settings preview. So every instance tears itself down on any of
/// `stopAnimation`, the `com.apple.screensaver.willstop` distributed notification or leaving its
/// window, and all full-screen instances share one player (one decoder) per process.
@objc(StarTorchSaverView)
final class StarTorchSaverView: ScreenSaverView {
    private static let log = Logger(subsystem: "com.shibuyaxpress.ikuyo-live-wallpaper.saver", category: "view")

    private var playerLayer: AVPlayerLayer?
    private var posterLayer: CALayer?
    private var overlayLayers: [CALayer] = []
    private var lease: SharedSaverPlayer.Lease?
    private let observers = DistributedObservers()

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        // AVFoundation drives the frames; the host's animation timer has nothing to do.
        animationTimeInterval = 3600
        observers.observe("com.apple.screensaver.willstop") { [weak self] in
            Self.log.debug("willstop received")
            self?.tearDown()
        }
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    override func startAnimation() {
        super.startAnimation()
        buildContent()
    }

    override func stopAnimation() {
        super.stopAnimation()
        tearDown()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tearDown() }
    }

    override func animateOneFrame() {
        // Nothing to draw per tick: the layers render themselves.
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    // MARK: - Content

    private func buildContent() {
        tearDown()
        guard let root = layer else { return }

        let (content, manifest) = ScreenSaverContent.load(from: Self.handoffDirectories(), isPreview: isPreview)
        Self.log.info("showing \(String(describing: content), privacy: .public) preview=\(self.isPreview)")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        switch content {
        case .gradient:
            root.addSublayer(track(Self.gradientLayer(frame: root.bounds)))
        case .poster(let url):
            addPoster(url, to: root)
        case .video(let url, let poster):
            // The poster sits under the video until its first frame is ready.
            if let poster { addPoster(poster, to: root) }
            let lease = SharedSaverPlayer.shared.acquire(url: url)
            let playerLayer = AVPlayerLayer(player: lease.player)
            playerLayer.videoGravity = .resizeAspectFill
            fill(playerLayer, in: root)
            root.addSublayer(playerLayer)
            self.lease = lease
            self.playerLayer = playerLayer
        }

        if let manifest { addOverlays(dim: manifest.dim, vignette: manifest.vignette, to: root) }
    }

    /// Where to look for the app's export: the host's container (see `ScreenSaverHandoff`).
    private static func handoffDirectories() -> [URL] {
        #if DEBUG
        // Lets a debug build be driven outside the host against a scratch folder.
        if let override = ProcessInfo.processInfo.environment["STARTORCH_SAVER_DIRECTORY"] {
            return [URL(filePath: override, directoryHint: .isDirectory)]
        }
        #endif
        return ScreenSaverHandoff.saverCandidateDirectories(
            applicationSupport: .applicationSupportDirectory,
            realHome: ScreenSaverHandoff.realHomeDirectory
        )
    }

    /// Pauses and drops the player and every layer. Safe to call any number of times.
    private func tearDown() {
        if let lease {
            playerLayer?.player = nil
            SharedSaverPlayer.shared.release(lease)
            self.lease = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        posterLayer?.removeFromSuperlayer()
        posterLayer = nil
        overlayLayers.forEach { $0.removeFromSuperlayer() }
        overlayLayers = []
        CATransaction.commit()
    }

    private func addPoster(_ url: URL, to root: CALayer) {
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            root.addSublayer(track(Self.gradientLayer(frame: root.bounds)))
            return
        }
        let poster = CALayer()
        poster.contents = image
        poster.contentsGravity = .resizeAspectFill
        poster.masksToBounds = true
        fill(poster, in: root)
        root.addSublayer(poster)
        posterLayer = poster
    }

    private func addOverlays(dim: Double, vignette: Bool, to root: CALayer) {
        if dim > 0 {
            let dimLayer = CALayer()
            dimLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
            dimLayer.opacity = Float(dim)
            fill(dimLayer, in: root)
            root.addSublayer(track(dimLayer))
        }
        if vignette {
            let vignetteLayer = CAGradientLayer()
            vignetteLayer.type = .radial
            vignetteLayer.colors = [
                CGColor(gray: 0, alpha: 0),
                CGColor(gray: 0, alpha: 0),
                CGColor(gray: 0, alpha: ScreenSaverManifest.vignetteOpacity),
            ]
            vignetteLayer.locations = [0, NSNumber(value: ScreenSaverManifest.vignetteInnerRadius), 1]
            vignetteLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
            // A radial gradient's end point sets the ellipse's radii; this one reaches the corners.
            vignetteLayer.endPoint = CGPoint(x: 0.5 + 0.5 * 2.0.squareRoot(), y: 0.5 + 0.5 * 2.0.squareRoot())
            fill(vignetteLayer, in: root)
            root.addSublayer(track(vignetteLayer))
        }
    }

    private func fill(_ sublayer: CALayer, in root: CALayer) {
        sublayer.frame = root.bounds
        sublayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }

    private func track(_ sublayer: CALayer) -> CALayer {
        overlayLayers.append(sublayer)
        return sublayer
    }

    private static func gradientLayer(frame: CGRect) -> CALayer {
        let gradient = CAGradientLayer()
        gradient.colors = [
            CGColor(red: 0.09, green: 0.07, blue: 0.16, alpha: 1),
            CGColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1),
        ]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.frame = frame
        gradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        return gradient
    }
}

/// Distributed-notification observers that unregister themselves when their owner goes away, so
/// an instance the host forgets to release doesn't leave callbacks behind.
private nonisolated final class DistributedObservers {
    private var tokens: [any NSObjectProtocol] = []

    func observe(_ name: String, handler: @escaping @MainActor @Sendable () -> Void) {
        let token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(name),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
        tokens.append(token)
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        tokens.forEach(center.removeObserver)
    }
}
