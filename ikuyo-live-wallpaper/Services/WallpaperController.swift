import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// One display's wallpaper: which video and the player that decodes it. Displays showing the
/// same wallpaper share the player.
struct PresentedWallpaper {
    let url: URL
    /// The local copy when there is one; used for the still frame.
    let playbackURL: URL
    let player: AVPlayer
    var readability = ReadabilitySettings()
}

/// Shows wallpapers on the desktops of the connected displays. The manager talks to this
/// protocol so its logic can be tested without windows or the real desktop picture.
protocol WallpaperPresenting: AnyObject {
    /// UUIDs of the connected displays, the main display first.
    var connectedDisplays: [String] { get }
    /// The desktop windows currently on screen, keyed by display UUID.
    var windowsByDisplay: [String: NSWindow] { get }
    /// Called after displays were connected, disconnected or rearranged, once they settled.
    /// The manager answers with a new `present(_:completion:)`.
    var onDisplaysChange: (() -> Void)? { get set }
    /// Shows `layout` (display UUID → wallpaper), reusing existing windows. Displays missing from
    /// the layout lose their window. Each wallpaper's first frame becomes the desktop picture of
    /// its displays. `completion` runs once players no longer in the layout can be torn down.
    func present(_ layout: [String: PresentedWallpaper], completion: @escaping () -> Void)
    /// Removes the windows but leaves the desktop picture alone, so a restart doesn't flash the
    /// original in between. `completion` runs once the windows are gone.
    func dismiss(animated: Bool, completion: @escaping () -> Void)
    /// Gives every display its original desktop picture back.
    func restoreOriginalDesktops()
}

extension WallpaperPresenting {
    var windows: [NSWindow] { Array(windowsByDisplay.values) }
}

/// Which displays (by UUID) gained, lost or moved a desktop window.
nonisolated struct ScreenLayoutChanges: Equatable, Sendable {
    var added: Set<String> = []
    var removed: Set<String> = []
    var resized: Set<String> = []

    var isEmpty: Bool { added.isEmpty && removed.isEmpty && resized.isEmpty }

    init(added: Set<String> = [], removed: Set<String> = [], resized: Set<String> = []) {
        self.added = added
        self.removed = removed
        self.resized = resized
    }

    /// Compares the frames of the windows we have with the frames of the displays that should
    /// have one.
    init(windows: [String: CGRect], screens: [String: CGRect]) {
        added = Set(screens.keys).subtracting(windows.keys)
        removed = Set(windows.keys).subtracting(screens.keys)
        resized = Set(screens.compactMap { id, frame in
            windows[id].flatMap { $0 == frame ? nil : id }
        })
    }
}

/// Owns the borderless desktop-level window on each display and the still frames used as desktop
/// pictures. Display changes update, add or remove windows in place; players keep running.
final class WallpaperController: WallpaperPresenting {
    private final class DesktopWindow {
        let window: NSWindow
        var content: WallpaperLayerStack
        var url: URL

        init(window: NSWindow, content: WallpaperLayerStack, url: URL) {
            self.window = window
            self.content = content
            self.url = url
        }

        func close() {
            content.detach()
            window.contentView = nil
            window.orderOut(nil)
        }
    }

    /// A still frame is specific to a wallpaper and the readability settings baked into it.
    private struct FrameKey: Hashable {
        let url: URL
        let readability: ReadabilitySettings

        init(_ wallpaper: PresentedWallpaper) {
            url = wallpaper.url
            // Speed doesn't change the picture.
            readability = ReadabilitySettings(
                dim: wallpaper.readability.dim,
                blur: wallpaper.readability.blur,
                vignette: wallpaper.readability.vignette
            )
        }
    }

    var onDisplaysChange: (() -> Void)?

    private let restorer: DesktopRestorer
    private var desktopWindows: [String: DesktopWindow] = [:]
    private var layout: [String: PresentedWallpaper] = [:]
    /// Its still frame file, or nil when extracting it failed.
    private var frames: [FrameKey: URL?] = [:]
    private var frameTasks: [FrameKey: Task<Void, Never>] = [:]
    private var shownFrames: [String: URL]?
    private var screenChangeTask: Task<Void, Never>?
    private var screenObserver: (any NSObjectProtocol)?

    var connectedDisplays: [String] {
        NSScreen.screens.compactMap(\.displayUUID)
    }

    var windowsByDisplay: [String: NSWindow] {
        desktopWindows.mapValues(\.window)
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

    func present(_ layout: [String: PresentedWallpaper], completion: @escaping () -> Void) {
        self.layout = layout
        var screens: [String: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let id = screen.displayUUID { screens[id] = screen }
        }

        let targets = screens.filter { layout[$0.key] != nil }
        let changes = ScreenLayoutChanges(
            windows: desktopWindows.mapValues { $0.window.frame },
            screens: targets.mapValues(\.frame)
        )
        for id in changes.removed {
            desktopWindows.removeValue(forKey: id)?.close()
        }
        for id in changes.resized {
            guard let frame = targets[id]?.frame else { continue }
            desktopWindows[id]?.window.setFrame(frame, display: true)
        }
        for (id, wallpaper) in layout {
            if let desktopWindow = desktopWindows[id] {
                if desktopWindow.content.playerLayer.player !== wallpaper.player {
                    desktopWindow.content.playerLayer.player = wallpaper.player
                }
                desktopWindow.content.apply(wallpaper.readability)
                desktopWindow.url = wallpaper.url
            } else if let screen = targets[id] {
                desktopWindows[id] = makeDesktopWindow(on: screen, showing: wallpaper)
            }
        }

        updateStillFrames()
        completion()
    }

    func dismiss(animated: Bool, completion: @escaping () -> Void) {
        screenChangeTask?.cancel()
        screenChangeTask = nil
        for task in frameTasks.values { task.cancel() }
        frameTasks.removeAll()
        frames.removeAll()
        shownFrames = nil
        layout.removeAll()

        for desktopWindow in desktopWindows.values { desktopWindow.close() }
        desktopWindows.removeAll()
        completion()
    }

    func restoreOriginalDesktops() {
        restorer.restoreOriginalDesktops()
    }

    // MARK: - Screens

    /// Always forwarded, even with nothing on screen: a reconnected display may be the only one
    /// with a wallpaper assigned.
    private func screenParametersDidChange() {
        // Displays report several changes while they settle.
        screenChangeTask?.cancel()
        screenChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.onDisplaysChange?()
        }
    }

    private func makeDesktopWindow(on screen: NSScreen, showing wallpaper: PresentedWallpaper) -> DesktopWindow {
        let viewRect = CGRect(origin: .zero, size: screen.frame.size)
        let content = WallpaperLayerStack(player: wallpaper.player, readability: wallpaper.readability, frame: viewRect)

        let contentView = NSView(frame: viewRect)
        contentView.wantsLayer = true
        // Needed for the blur filter on the video layer.
        contentView.layerUsesCoreImageFilters = true
        contentView.layer?.addSublayer(content.root)

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

        return DesktopWindow(window: window, content: content, url: wallpaper.url)
    }

    // MARK: - Still Frames

    /// Makes each wallpaper's first frame, with its dim, blur and vignette baked in, the desktop
    /// picture of its displays, so Mission Control, Spaces transitions, the menu bar's text color
    /// and the moment before our windows appear match the video. Originals are recorded first and
    /// restored on stop. Waits until every wallpaper in the layout has its frame, so a display
    /// never briefly gets its original back.
    private func updateStillFrames() {
        let keys = Set(layout.values.map(FrameKey.init))
        for (key, task) in frameTasks where !keys.contains(key) {
            task.cancel()
            frameTasks[key] = nil
        }
        let hadFrameFor = Set(frames.keys.map(\.url))
        frames = frames.filter { keys.contains($0.key) }

        for wallpaper in layout.values {
            let key = FrameKey(wallpaper)
            guard frames[key] == nil, frameTasks[key] == nil else { continue }
            // While a readability slider moves, only the settled value gets rendered.
            extractStillFrame(of: wallpaper, key: key, after: hadFrameFor.contains(key.url) ? .milliseconds(600) : .zero)
        }
        guard keys.allSatisfy({ frames[$0] != nil }) else { return }

        var shown: [String: URL] = [:]
        var untouched: Set<String> = []
        for (id, wallpaper) in layout {
            if let frame = frames[FrameKey(wallpaper)] ?? nil { shown[id] = frame } else { untouched.insert(id) }
        }
        guard shown != shownFrames else { return }
        shownFrames = shown
        restorer.showFrames(shown, leaving: untouched)
    }

    private func extractStillFrame(of wallpaper: PresentedWallpaper, key: FrameKey, after delay: Duration) {
        let name = WallpaperCacheManager.cacheKey(for: key.url) + "-" + key.readability.imageFingerprint + ".png"
        let destination = restorer.framesDirectory.appending(path: name)
        let screens = NSScreen.screens
        let targetSize = screens
            .map { CGSize(width: $0.frame.width * $0.backingScaleFactor, height: $0.frame.height * $0.backingScaleFactor) }
            .max { $0.width * $0.height < $1.width * $1.height }
            ?? CGSize(width: 1920, height: 1080)
        let pointScale = screens.map(\.backingScaleFactor).max() ?? 2

        frameTasks[key] = Task { [weak self, playbackURL = wallpaper.playbackURL, readability = key.readability] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let frameURL = await Self.writeFirstFrame(
                of: playbackURL, maximumSize: targetSize, readability: readability, pointScale: pointScale, to: destination
            )
            // The wallpaper may have been stopped or switched while the frame was extracted.
            guard let self, !Task.isCancelled, self.frameTasks[key] != nil else { return }
            self.frameTasks[key] = nil
            self.frames[key] = .some(frameURL)
            self.updateStillFrames()
        }
    }

    private nonisolated static func writeFirstFrame(
        of videoURL: URL,
        maximumSize: CGSize,
        readability: ReadabilitySettings,
        pointScale: CGFloat,
        to destination: URL
    ) async -> URL? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize

        do {
            let image = StillFrameRenderer.render(
                try await generator.image(at: .zero).image,
                readability: readability,
                pointScale: pointScale
            )
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
