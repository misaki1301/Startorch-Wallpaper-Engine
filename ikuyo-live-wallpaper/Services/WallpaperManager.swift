import AppKit

/// What the views talk to: which wallpaper runs and whether it plays.
///
/// Windows and the desktop picture belong to `WallpaperController`, decoding to
/// `PlaybackEngine`. This type keeps the user's intent (running, paused by the user) apart from
/// automatic pauses, which `PlaybackPolicy` decides from the system signals. An automatic resume
/// never overrides a pause by the user.
@Observable
final class WallpaperManager {
    private(set) var isActive = false
    /// Paused by the user. Automatic pauses don't set this; see `pauseReason`.
    private(set) var isPaused = false
    private(set) var currentURL: URL?
    /// Why the running wallpaper isn't playing right now (`.user` included); nil while it plays
    /// or when nothing runs.
    private(set) var pauseReason: PauseReason?

    /// A wallpaper runs and is actually playing.
    var isPlaying: Bool { isActive && pauseReason == nil }

    @ObservationIgnored private let presenter: any WallpaperPresenting
    @ObservationIgnored private let signalSource: any PlaybackSignalSource
    @ObservationIgnored private let makeEngine: (URL) -> any WallpaperPlayback
    @ObservationIgnored private var engine: (any WallpaperPlayback)?
    @ObservationIgnored private let settings: AppSettings?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    @ObservationIgnored var policy = PlaybackPolicy() {
        didSet { applyPolicy() }
    }

    init(
        restorer: DesktopRestorer = DesktopRestorer(),
        settings: AppSettings? = nil,
        presenter: (any WallpaperPresenting)? = nil,
        signals: (any PlaybackSignalSource)? = nil,
        makeEngine: @escaping (URL) -> any WallpaperPlayback = { PlaybackEngine(url: $0) }
    ) {
        self.presenter = presenter ?? WallpaperController(restorer: restorer)
        self.signalSource = signals ?? (AppEnvironment.isHostingTests ? FixedSignalSource() : SystemSignalMonitor())
        self.makeEngine = makeEngine
        self.settings = settings

        signalSource.onChange = { [weak self] _ in self?.applyPolicy() }
        self.presenter.onWindowsChange = { [weak self] in self?.windowsDidChange() }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationWillTerminate() }
        }
    }

    /// Puts back desktop pictures left behind by a previous run that crashed or was killed.
    func recoverDesktopFromPreviousSession() {
        guard !isActive else { return }
        presenter.restoreOriginalDesktops()
    }

    // MARK: - Start

    /// Starts `url`, replacing any running wallpaper. The desktop windows are reused.
    func start(with url: URL) {
        engine?.tearDown()

        let playbackURL = WallpaperCacheManager.resolvedURL(for: url)
        let engine = makeEngine(playbackURL)
        self.engine = engine
        presenter.present(engine.player, for: url, playbackURL: playbackURL)

        currentURL = url
        isActive = true
        isPaused = false
        settings?.lastWallpaperURL = url
        settings?.wallpaperWasActive = true

        windowsDidChange()
    }

    // MARK: - Pause / Stop

    func pause() {
        guard isActive else { return }
        isPaused = true
        applyPolicy()
    }

    /// Clears the user's pause. The wallpaper plays unless something else still pauses it.
    func resume() {
        guard isActive else { return }
        isPaused = false
        applyPolicy()
    }

    /// Resumes a paused wallpaper, or starts `lastURL` when nothing is playing.
    func play(orStart lastURL: URL?) {
        if isActive {
            resume()
        } else if let lastURL {
            start(with: lastURL)
        }
    }

    /// Stops playback and gives every display its original desktop picture back.
    func stop() {
        tearDown()
        presenter.restoreOriginalDesktops()
        settings?.wallpaperWasActive = false
    }

    /// Restores the desktop but remembers the wallpaper was playing, so it resumes on next launch.
    private func applicationWillTerminate() {
        tearDown()
        presenter.restoreOriginalDesktops()
    }

    /// Removes the player and windows but leaves the desktop picture alone.
    private func tearDown() {
        engine?.tearDown()
        engine = nil
        presenter.dismiss()
        signalSource.monitorWallpaperWindows([])

        currentURL = nil
        isActive = false
        isPaused = false
        applyPolicy()
    }

    // MARK: - Policy

    private func windowsDidChange() {
        signalSource.monitorWallpaperWindows(isActive ? presenter.windows : [])
        applyPolicy()
    }

    /// Plays or pauses the engine to match the policy for the current signals.
    private func applyPolicy() {
        var reason: PauseReason?
        if isActive, let engine {
            reason = policy.decision(for: signalSource.signals, userPaused: isPaused).pauseReason
            if reason == nil { engine.play() } else { engine.pause() }
        }
        if pauseReason != reason { pauseReason = reason }
    }
}
