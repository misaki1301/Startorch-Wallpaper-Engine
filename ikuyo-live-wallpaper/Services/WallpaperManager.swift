import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
@Observable
final class WallpaperManager {
    @ObservationIgnored private var windows: [NSWindow] = []
    @ObservationIgnored private var player: AVQueuePlayer?
    @ObservationIgnored private var playerLooper: AVPlayerLooper?
    @ObservationIgnored private var screenChangeTimer: Timer?
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private let restorer: DesktopRestorer

    private(set) var isActive = false
    private(set) var isPaused = false
    private(set) var currentURL: URL?

    init(restorer: DesktopRestorer = DesktopRestorer()) {
        self.restorer = restorer

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    /// Puts back desktop pictures left behind by a previous run that crashed or was killed.
    func recoverDesktopFromPreviousSession() {
        guard !isActive else { return }
        restorer.restoreOriginalDesktops()
    }

    // MARK: - Start

    func start(with url: URL) {
        tearDown()

        let playbackURL = WallpaperCacheManager.resolvedURL(for: url)

        // Stream straight from disk (or the network); AVFoundation only buffers what it needs.
        // AVPlayerLooper clones the template item into the queue for gapless looping.
        let templateItem = AVPlayerItem(url: playbackURL)
        templateItem.preferredForwardBufferDuration = 0
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: templateItem)
        queuePlayer.play()
        player = queuePlayer

        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))

        for screen in NSScreen.screens {
            let screenRect = screen.frame
            let viewRect = CGRect(origin: .zero, size: screenRect.size)

            let playerLayer = AVPlayerLayer(player: queuePlayer)
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.frame = viewRect

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

        currentURL = url
        isActive = true
        isPaused = false

        showStaticFrame(of: playbackURL, for: url)
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

    /// Stops playback and gives every display its original desktop picture back.
    func stop() {
        tearDown()
        restorer.restoreOriginalDesktops()
    }

    @objc private func applicationWillTerminate() {
        stop()
    }

    /// Removes the player and windows but leaves the desktop picture alone, so switching
    /// wallpapers doesn't flash the original in between.
    private func tearDown() {
        screenChangeTimer?.invalidate()
        screenChangeTimer = nil
        frameTask?.cancel()
        frameTask = nil

        player?.pause()
        playerLooper?.disableLooping()
        playerLooper = nil
        player = nil

        for window in windows {
            window.contentView = nil
            window.orderOut(nil)
        }
        windows.removeAll()

        currentURL = nil
        isActive = false
        isPaused = false
    }

    // MARK: - Screen Changes

    @objc private func screenParametersDidChange() {
        guard isActive, currentURL != nil else { return }

        screenChangeTimer?.invalidate()
        screenChangeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let url = self.currentURL else { return }
                let wasPaused = self.isPaused
                self.start(with: url)
                if wasPaused { self.pause() }
            }
        }
    }

    // MARK: - Static Frame

    /// Also sets the first frame as the desktop picture, so Mission Control, Spaces transitions
    /// and the moment before our windows appear match the video. The original picture is
    /// recorded first and restored on stop.
    private func showStaticFrame(of playbackURL: URL, for url: URL) {
        let framesDirectory = restorer.framesDirectory
        let targetSize = NSScreen.screens
            .map { CGSize(width: $0.frame.width * $0.backingScaleFactor, height: $0.frame.height * $0.backingScaleFactor) }
            .max { $0.width * $0.height < $1.width * $1.height }
            ?? CGSize(width: 1920, height: 1080)

        frameTask = Task { [weak self] in
            let frameURL = await Self.writeFirstFrame(
                of: playbackURL,
                maximumSize: targetSize,
                to: framesDirectory.appending(path: WallpaperCacheManager.cacheKey(for: url) + ".png")
            )
            // The wallpaper may have been stopped or switched while the frame was extracted.
            guard let self, let frameURL, !Task.isCancelled, self.isActive, self.currentURL == url else { return }
            self.restorer.showFrame(frameURL)
        }
    }

    private nonisolated static func writeFirstFrame(
        of videoURL: URL,
        maximumSize: CGSize,
        to destination: URL
    ) async -> URL? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize

        do {
            let image = try await generator.image(at: .zero).image
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let output = CGImageDestinationCreateWithURL(
                destination as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else { return nil }
            CGImageDestinationAddImage(output, image, nil)
            return CGImageDestinationFinalize(output) ? destination : nil
        } catch {
            return nil
        }
    }
}
