import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Shows a player on the desktop of every display. The manager talks to this protocol so its
/// logic can be tested without windows or the real desktop picture.
protocol WallpaperPresenting: AnyObject {
    /// The desktop windows currently on screen, one per display.
    var windows: [NSWindow] { get }
    /// Called after displays were added, removed or rearranged and `windows` changed.
    var onWindowsChange: (() -> Void)? { get set }
    /// Shows `player` on every display, reusing existing windows, and sets the first frame of
    /// `playbackURL` as the desktop picture once `url` changes.
    func present(_ player: AVPlayer, for url: URL, playbackURL: URL)
    /// Removes the windows but leaves the desktop picture alone, so switching wallpapers
    /// doesn't flash the original in between.
    func dismiss()
    /// Gives every display its original desktop picture back.
    func restoreOriginalDesktops()
}

/// Which displays gained, lost or moved a desktop window.
nonisolated struct ScreenLayoutChanges: Equatable, Sendable {
    var added: Set<CGDirectDisplayID> = []
    var removed: Set<CGDirectDisplayID> = []
    var resized: Set<CGDirectDisplayID> = []

    var isEmpty: Bool { added.isEmpty && removed.isEmpty && resized.isEmpty }

    init(added: Set<CGDirectDisplayID> = [], removed: Set<CGDirectDisplayID> = [], resized: Set<CGDirectDisplayID> = []) {
        self.added = added
        self.removed = removed
        self.resized = resized
    }

    /// Compares the frames of the windows we have with the frames of the connected displays.
    init(windows: [CGDirectDisplayID: CGRect], screens: [CGDirectDisplayID: CGRect]) {
        added = Set(screens.keys).subtracting(windows.keys)
        removed = Set(windows.keys).subtracting(screens.keys)
        resized = Set(screens.compactMap { id, frame in
            windows[id].flatMap { $0 == frame ? nil : id }
        })
    }
}

/// Owns the borderless desktop-level window on each display and the still frame used as the
/// desktop picture. Display changes update, add or remove windows in place; the player keeps
/// running.
final class WallpaperController: WallpaperPresenting {
    private struct DesktopWindow {
        let window: NSWindow
        let playerLayer: AVPlayerLayer
    }

    var onWindowsChange: (() -> Void)?

    private let restorer: DesktopRestorer
    private var desktopWindows: [CGDirectDisplayID: DesktopWindow] = [:]
    private var player: AVPlayer?
    private var currentURL: URL?
    /// The still frame of the current wallpaper, once written.
    private var frameURL: URL?
    private var frameTask: Task<Void, Never>?
    private var screenChangeTask: Task<Void, Never>?
    private var screenObserver: (any NSObjectProtocol)?

    var windows: [NSWindow] {
        desktopWindows.values.map(\.window)
    }

    init(restorer: DesktopRestorer) {
        self.restorer = restorer
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenParametersDidChange() }
        }
    }

    func present(_ player: AVPlayer, for url: URL, playbackURL: URL) {
        self.player = player
        for desktopWindow in desktopWindows.values {
            desktopWindow.playerLayer.player = player
        }
        updateWindowsForScreens()

        if url != currentURL {
            currentURL = url
            frameURL = nil
            showStaticFrame(of: playbackURL, for: url)
        }
    }

    func dismiss() {
        screenChangeTask?.cancel()
        screenChangeTask = nil
        frameTask?.cancel()
        frameTask = nil

        for desktopWindow in desktopWindows.values {
            desktopWindow.playerLayer.player = nil
            desktopWindow.window.contentView = nil
            desktopWindow.window.orderOut(nil)
        }
        let hadWindows = !desktopWindows.isEmpty
        desktopWindows.removeAll()
        player = nil
        currentURL = nil
        frameURL = nil
        if hadWindows { onWindowsChange?() }
    }

    func restoreOriginalDesktops() {
        restorer.restoreOriginalDesktops()
    }

    // MARK: - Screens

    private func screenParametersDidChange() {
        guard player != nil else { return }
        // Displays report several changes while they settle.
        screenChangeTask?.cancel()
        screenChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.updateWindowsForScreens()
        }
    }

    /// Adds a window for each new display, moves or resizes the ones that changed and removes
    /// the ones whose display is gone. The player is untouched, so playback never restarts.
    private func updateWindowsForScreens() {
        guard let player else { return }
        var screens: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = screen.displayID { screens[id] = screen }
        }
        let changes = ScreenLayoutChanges(
            windows: desktopWindows.mapValues { $0.window.frame },
            screens: screens.mapValues(\.frame)
        )
        guard !changes.isEmpty else { return }

        for id in changes.removed {
            guard let desktopWindow = desktopWindows.removeValue(forKey: id) else { continue }
            desktopWindow.playerLayer.player = nil
            desktopWindow.window.contentView = nil
            desktopWindow.window.orderOut(nil)
        }
        for id in changes.resized {
            guard let frame = screens[id]?.frame else { continue }
            desktopWindows[id]?.window.setFrame(frame, display: true)
        }
        for id in changes.added {
            guard let screen = screens[id] else { continue }
            desktopWindows[id] = makeDesktopWindow(on: screen, player: player)
        }

        // A new display gets the still frame too; its own picture is recorded first.
        if !changes.added.isEmpty, let frameURL {
            restorer.showFrame(frameURL)
        }
        onWindowsChange?()
    }

    private func makeDesktopWindow(on screen: NSScreen, player: AVPlayer) -> DesktopWindow {
        let viewRect = CGRect(origin: .zero, size: screen.frame.size)

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = viewRect
        // Follows the window when the display's resolution changes.
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        let contentView = NSView(frame: viewRect)
        contentView.wantsLayer = true
        contentView.layer?.addSublayer(playerLayer)

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        window.orderFrontRegardless()

        return DesktopWindow(window: window, playerLayer: playerLayer)
    }

    // MARK: - Static Frame

    /// Also sets the first frame as the desktop picture, so Mission Control, Spaces transitions
    /// and the moment before our windows appear match the video. The original picture is
    /// recorded first and restored on stop.
    private func showStaticFrame(of playbackURL: URL, for url: URL) {
        frameTask?.cancel()
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
            guard let self, let frameURL, !Task.isCancelled, self.currentURL == url else { return }
            self.frameURL = frameURL
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
