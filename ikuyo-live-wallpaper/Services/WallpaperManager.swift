import AppKit
import AVKit
import SwiftUI

@MainActor
@Observable
final class WallpaperManager {
    private var windows: [NSWindow] = []
    private var player: AVPlayer?
    private var playerLayers: [AVPlayerLayer] = []
    private var isStopping = false
    private var playbackURL: URL?
    private var playerLooper: AVPlayerLooper?
    private var memoryLoader: MemoryResourceLoader?

    private(set) var isActive = false
    private(set) var isPaused = false
    private(set) var currentURL: URL?
    private var staticFrameURL: URL?
    private var screenChangeTimer: Timer?

    // MARK: - Start

    func start(with url: URL) {
        if isActive { stop() }
        isPaused = false
        isStopping = false

        let playbackURL = WallpaperCacheManager.resolvedURL(for: url)
        self.playbackURL = playbackURL

        // Extract static frame in background
        Task { [weak self] in
            guard let frameURL = await self?.extractFirstFrame(from: url) else { return }
            await MainActor.run {
                self?.staticFrameURL = frameURL
                self?.applyStaticFrame(frameURL)
            }
        }

        // AVPlayerLooper for seamless gapless looping
        let playerItem: AVPlayerItem
        if playbackURL.isFileURL, let data = try? Data(contentsOf: playbackURL) {
            let loader = MemoryResourceLoader(data: data, fileExtension: playbackURL.pathExtension)
            memoryLoader = loader
            let asset = AVURLAsset(url: URL(string: "memory://wallpaper")!)
            asset.resourceLoader.setDelegate(loader, queue: .main)
            playerItem = AVPlayerItem(asset: asset)
        } else {
            playerItem = AVPlayerItem(url: playbackURL)
        }
        playerItem.preferredForwardBufferDuration = 0
        let queuePlayer = AVQueuePlayer(playerItem: playerItem)
        queuePlayer.isMuted = true
        self.playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
        queuePlayer.play()
        self.player = queuePlayer
        currentURL = url

        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))

        for screen in NSScreen.screens {
            let screenRect = screen.frame
            let viewRect = CGRect(origin: .zero, size: screenRect.size)

            let playerLayer = AVPlayerLayer(player: queuePlayer)
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.frame = viewRect
            playerLayers.append(playerLayer)

            let contentView = NSView(frame: viewRect)
            contentView.wantsLayer = true
            contentView.layer?.addSublayer(playerLayer)

            let window = NSWindow(
                contentRect: screenRect,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = NSWindow.Level(rawValue: desktopLevel + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.isOpaque = true
            window.backgroundColor = .black
            window.hasShadow = false
            window.contentView = contentView
            window.orderFrontRegardless()

            windows.append(window)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        isActive = true
    }

    // MARK: - Pause / Stop

    func pause() {
        player?.pause()
        isPaused = true
    }

    func resume() {
        player?.play()
        isPaused = false
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        screenChangeTimer?.invalidate()
        screenChangeTimer = nil

        if let frameURL = staticFrameURL {
            try? FileManager.default.removeItem(at: frameURL)
            staticFrameURL = nil
        }

        player?.pause()
        playerLooper?.disableLooping()
        playerLooper = nil
        memoryLoader = nil
        player = nil
        playbackURL = nil

        for layer in playerLayers {
            layer.removeFromSuperlayer()
        }
        playerLayers.removeAll()

        for window in windows {
            window.contentView = nil
            window.orderOut(nil)
        }
        windows.removeAll()

        NotificationCenter.default.removeObserver(self)

        currentURL = nil
        isActive = false
        isPaused = false
    }

    // MARK: - Screen Changes

    private func applyStaticFrame(_ frameURL: URL) {
        for screen in NSScreen.screens {
            try? NSWorkspace.shared.setDesktopImageURL(frameURL, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
            ])
        }
    }

    @objc private func screenParametersDidChange() {
        guard isActive, let url = currentURL else { return }

        screenChangeTimer?.invalidate()
        screenChangeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.restartWithCurrentURL()
            }
        }
    }

    private func restartWithCurrentURL() {
        guard let url = currentURL else { return }
        stop()
        start(with: url)
    }

    // MARK: - Static Frame Extraction

    private func extractFirstFrame(from videoURL: URL) async -> URL? {
        let playbackURL = WallpaperCacheManager.resolvedURL(for: videoURL)
        let asset = AVAsset(url: playbackURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let targetSize = NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        generator.maximumSize = targetSize

        do {
            let cgImage = try await generator.image(at: .zero).image
            let destURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("png")

            let nsImage = NSImage(cgImage: cgImage, size: .zero)
            guard let tiffData = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                return nil
            }

            try pngData.write(to: destURL)
            return destURL
        } catch {
            return nil
        }
    }
}
