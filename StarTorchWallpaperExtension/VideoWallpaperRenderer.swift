import AVFoundation
import QuartzCore
import os

private let rendererLog = Logger(subsystem: "com.shibuyaxpress.ikuyo-live-wallpaper.WallpaperExtension", category: "renderer")

/// A layer context the host composites. The private `CAContext` behind it lives in
/// Private/WallpaperHostBridge.swift; the renderer only needs these two things.
@MainActor
protocol RemoteLayerHosting: AnyObject {
    var contextID: UInt32 { get }
    var hostedLayer: CALayer? { get set }
}

/// One `acquire` from WallpaperAgent, already decoded into plain values.
nonisolated struct HostSurfaceRequest: Sendable {
    /// The host's surface UUID; stable across invalidate / re-acquire.
    var key: String
    var size: CGSize
    var scale: CGFloat
    /// System Settings' preview tiles.
    var isPreview: Bool
    var displayID: UInt32?
    var presentation: SystemWallpaperPresentation
}

/// One `update` from WallpaperAgent. Nil fields weren't in the request.
nonisolated struct HostSurfaceUpdate: Sendable {
    var key: String
    var modeName: String?
    var activityName: String?
    var size: CGSize?
    var scale: CGFloat?
}

/// Plays the exported StarTorch clip into the remote layer contexts WallpaperAgent hosts on each
/// display's desktop and lock screen. Replaces the prototype's WebWallpaperRenderer (WKWebView +
/// 30 fps snapshot timer) with plain AVFoundation layers:
///
/// - `AVQueuePlayer` + `AVPlayerLooper`, muted, never holding the display awake;
/// - one player (one decoder) per unique clip, shared by every surface showing it;
/// - an `AVPlayerLayer` (aspect fill) under a dim layer and a vignette, over a poster layer that
///   covers the moment before the first frame and any clip that fails to load;
/// - the player runs only while at least one non-preview surface is visible: a `suspended`
///   activity pauses it, `invalidate` detaches it, and the last detach frees the decoder.
///
/// No timers or polling: everything is driven by host calls, KVO and the content folder watcher.
@MainActor
final class VideoWallpaperRenderer {
    static let shared = VideoWallpaperRenderer(content: WallpaperContentSource())

    private let content: WallpaperContentSource
    private var surfaces: [String: Surface] = [:]
    private var players: [URL: SharedPlayer] = [:]

    init(content: WallpaperContentSource) {
        self.content = content
        content.onChange = { [weak self] in self?.contentDidChange() }
    }

    /// The exported poster, for System Settings' thumbnail.
    var settingsThumbnailURL: URL? { content.content?.posterURL }

    // MARK: Host calls

    /// Creates (or reuses) the surface's layer tree and returns the remote context ID to hand back.
    func acquire(_ request: HostSurfaceRequest, makeContext: (UInt32?) -> (any RemoteLayerHosting)?) -> UInt32? {
        // Cheap (one small JSON read) and covers a watcher that missed an event.
        content.reload()
        let surface: Surface
        if let existing = surfaces[request.key] {
            surface = existing
        } else {
            guard let context = makeContext(request.displayID) else { return nil }
            surface = Surface(context: context)
            surfaces[request.key] = surface
            rendererLog.info("Created surface \(request.key, privacy: .public)")
        }
        surface.isAcquired = true
        surface.isPreview = request.isPreview
        surface.presentation = request.presentation
        surface.layers.resize(to: request.size, scale: request.scale)
        showContent(on: surface, animated: false)
        reconcilePlayers()
        return surface.context.contextID
    }

    func update(_ update: HostSurfaceUpdate) {
        guard let surface = surfaces[update.key] else { return }
        surface.presentation = SystemWallpaperPresentation(
            modeName: update.modeName, activityName: update.activityName, default: surface.presentation
        )
        if let size = update.size {
            surface.layers.resize(to: size, scale: update.scale ?? surface.layers.root.contentsScale)
        }
        applyOverlay(to: surface, animated: true)
        reconcilePlayers()
    }

    /// The host no longer shows the surface. Its context and layers are kept for a quick
    /// re-acquire (the host reuses surface IDs), but it stops holding a decoder.
    func invalidate(key: String) {
        guard let surface = surfaces[key] else { return }
        surface.isAcquired = false
        reconcilePlayers()
    }

    /// The poster frame, for the host's snapshot of the surface.
    func snapshotImage(forKey key: String) -> CGImage? {
        content.poster
    }

    // MARK: Content

    private func contentDidChange() {
        for surface in surfaces.values {
            showContent(on: surface, animated: true)
        }
        reconcilePlayers()
        HostAgents.shared.invalidateSnapshots()
    }

    private func showContent(on surface: Surface, animated: Bool) {
        let current = content.content
        surface.clipURL = current?.clipURL
        surface.layers.setPoster(content.poster)
        applyOverlay(to: surface, animated: animated)
    }

    private func applyOverlay(to surface: Surface, animated: Bool) {
        let manifest = content.content?.manifest
        let overlay = surface.presentation.overlay(dim: manifest?.dim ?? 0, vignette: manifest?.vignette ?? false)
        surface.layers.applyOverlay(dim: overlay.dim, vignette: overlay.vignette, animated: animated)
    }

    // MARK: Players

    /// Gives every clip on screen exactly one player, attaches it to the surfaces that should
    /// show video, plays or pauses it, and releases players nobody needs.
    private func reconcilePlayers() {
        var demands: [URL: [SystemWallpaperPlayback.Demand]] = [:]
        for surface in surfaces.values where surface.isAcquired {
            guard let url = surface.clipURL else { continue }
            demands[url, default: []].append(.init(isPreview: surface.isPreview, presentation: surface.presentation))
        }

        for (url, player) in players where !SystemWallpaperPlayback.needsPlayer(demands[url] ?? []) {
            player.tearDown()
            players[url] = nil
            rendererLog.info("Released the player for \(url.lastPathComponent, privacy: .public)")
        }

        let speed = Float(content.content?.manifest.speed ?? 1)
        for (url, clipDemands) in demands where SystemWallpaperPlayback.needsPlayer(clipDemands) {
            let player = players[url] ?? {
                let made = SharedPlayer(url: url)
                players[url] = made
                rendererLog.info("Created the player for \(url.lastPathComponent, privacy: .public)")
                return made
            }()
            player.setPlaying(SystemWallpaperPlayback.shouldPlay(clipDemands), rate: speed)
        }

        for surface in surfaces.values {
            let wantsVideo = surface.isAcquired && !surface.isPreview
            surface.layers.attach(wantsVideo ? surface.clipURL.flatMap { players[$0]?.player } : nil)
        }
    }

    // MARK: - Types

    @MainActor
    private final class Surface {
        let context: any RemoteLayerHosting
        let layers = SurfaceLayers()
        var isAcquired = false
        var isPreview = false
        var presentation = SystemWallpaperPresentation()
        var clipURL: URL?

        init(context: any RemoteLayerHosting) {
            self.context = context
            context.hostedLayer = layers.root
        }
    }

    /// One muted, looping player for one clip.
    @MainActor
    private final class SharedPlayer {
        let player = AVQueuePlayer()
        private let looper: AVPlayerLooper

        init(url: URL) {
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.actionAtItemEnd = .advance
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: AVURLAsset(url: url)))
        }

        func setPlaying(_ playing: Bool, rate: Float) {
            player.defaultRate = rate
            if playing {
                if player.rate != rate { player.rate = rate }
            } else if player.rate != 0 {
                player.pause()
            }
        }

        func tearDown() {
            looper.disableLooping()
            player.pause()
            player.removeAllItems()
        }
    }
}

/// The layer tree of one surface: poster, video, dim, vignette.
@MainActor
private final class SurfaceLayers {
    let root = CALayer()
    private let posterLayer = CALayer()
    private let playerLayer = AVPlayerLayer()
    private let dimLayer = CALayer()
    private let vignetteLayer = CAGradientLayer()
    private var readyObservation: NSKeyValueObservation?

    /// The same look as the app's own vignette (ReadabilitySettings.vignetteOpacity / InnerRadius).
    private static let vignetteOpacity = 0.55
    private static let vignetteInnerRadius = 0.55

    init() {
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        root.masksToBounds = true
        let fill: CAAutoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        posterLayer.contentsGravity = .resizeAspectFill
        posterLayer.autoresizingMask = fill
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.autoresizingMask = fill
        playerLayer.opacity = 0
        dimLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        dimLayer.opacity = 0
        dimLayer.autoresizingMask = fill
        vignetteLayer.type = .radial
        vignetteLayer.colors = [
            CGColor(gray: 0, alpha: 0),
            CGColor(gray: 0, alpha: 0),
            CGColor(gray: 0, alpha: Self.vignetteOpacity),
        ]
        vignetteLayer.locations = [0, NSNumber(value: Self.vignetteInnerRadius), 1]
        vignetteLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignetteLayer.endPoint = CGPoint(x: 0.5 + 0.5 * 2.0.squareRoot(), y: 0.5 + 0.5 * 2.0.squareRoot())
        vignetteLayer.isHidden = true
        vignetteLayer.autoresizingMask = fill

        for layer in [posterLayer, playerLayer, dimLayer, vignetteLayer] {
            root.addSublayer(layer)
        }

        // The video fades in over the poster once it has a frame; KVO, no polling.
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.videoReadinessChanged(ready) }
            }
        }
    }

    func resize(to size: CGSize, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        for layer in [root, posterLayer, playerLayer, dimLayer, vignetteLayer] {
            layer.contentsScale = scale
            if layer !== root { layer.frame = root.bounds }
        }
        CATransaction.commit()
    }

    func setPoster(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        posterLayer.contents = image
        CATransaction.commit()
    }

    func applyOverlay(dim: Double, vignette: Bool, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.35)
        dimLayer.opacity = Float(dim)
        vignetteLayer.isHidden = !vignette
        CATransaction.commit()
    }

    /// Shows `player`'s video, or only the poster when nil.
    func attach(_ player: AVPlayer?) {
        guard playerLayer.player !== player else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.player = player
        if player == nil { playerLayer.opacity = 0 }
        CATransaction.commit()
    }

    private func videoReadinessChanged(_ ready: Bool) {
        guard playerLayer.player != nil else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        playerLayer.opacity = ready ? 1 : 0
        CATransaction.commit()
    }
}
