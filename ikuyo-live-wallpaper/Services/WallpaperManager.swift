import AppKit

/// What the views talk to: which wallpapers run where and whether they play.
///
/// Windows and desktop pictures belong to `WallpaperController`, decoding to `PlaybackEngine`,
/// and which display shows what to `DisplayAssignmentStore`. This type keeps the user's intent
/// (running, paused by the user) apart from automatic pauses, which `PlaybackPolicy` decides from
/// the system signals. An automatic resume never overrides a pause by the user.
///
/// There is one engine per *unique* wallpaper on screen, shared by every display showing it.
/// Automatic pauses are decided per engine — an engine pauses when all of its displays are
/// covered — while the user's pause applies to all of them.
@Observable
final class WallpaperManager {
    private(set) var isActive = false
    /// Paused by the user. Automatic pauses don't set this; see `pauseReason`.
    private(set) var isPaused = false
    /// The wallpaper on the main display (or the "All Displays" wallpaper when the main display
    /// shows nothing); nil when nothing runs.
    private(set) var currentURL: URL?
    /// What each connected display shows (display UUID → wallpaper); empty when nothing runs.
    private(set) var displayedURLs: [String: URL] = [:]
    /// Why the running wallpapers aren't playing right now (`.user` included); nil while any of
    /// them plays or when nothing runs.
    private(set) var pauseReason: PauseReason?

    /// A wallpaper runs and is actually playing.
    var isPlaying: Bool { isActive && pauseReason == nil }

    /// Whether `url` is on screen on at least one display.
    func isShowing(_ url: URL) -> Bool {
        isActive && displayedURLs.values.contains(url)
    }

    /// Which display shows what, persisted across launches and reconnects.
    @ObservationIgnored let assignments: DisplayAssignmentStore
    /// Played and paused time per day, for the energy summary.
    @ObservationIgnored let stats: PlaybackStats
    @ObservationIgnored private let presenter: any WallpaperPresenting
    @ObservationIgnored private let signalSource: any PlaybackSignalSource
    @ObservationIgnored private let makeEngine: (URL) -> any WallpaperPlayback
    /// One engine per wallpaper URL on screen.
    @ObservationIgnored private var engines: [URL: any WallpaperPlayback] = [:]
    @ObservationIgnored private let settings: AppSettings?
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    @ObservationIgnored var policy = PlaybackPolicy() {
        didSet { applyPolicy() }
    }

    init(
        restorer: DesktopRestorer = DesktopRestorer(),
        settings: AppSettings? = nil,
        assignments: DisplayAssignmentStore? = nil,
        presenter: (any WallpaperPresenting)? = nil,
        signals: (any PlaybackSignalSource)? = nil,
        stats: PlaybackStats? = nil,
        makeEngine: @escaping (URL) -> any WallpaperPlayback = { PlaybackEngine(url: $0) }
    ) {
        self.presenter = presenter ?? WallpaperController(restorer: restorer)
        self.signalSource = signals ?? (AppEnvironment.isHostingTests ? FixedSignalSource() : SystemSignalMonitor())
        self.makeEngine = makeEngine
        // A test run must never write to the real statistics or assignments.
        self.stats = stats ?? (AppEnvironment.isHostingTests
            ? PlaybackStats(fileURL: .temporaryDirectory.appending(path: "playback-stats-\(UUID().uuidString).json"))
            : PlaybackStats())
        self.assignments = assignments ?? (AppEnvironment.isHostingTests
            ? DisplayAssignmentStore(fileURL: .temporaryDirectory.appending(path: "display-assignments-\(UUID().uuidString).json"))
            : DisplayAssignmentStore())
        self.settings = settings

        signalSource.onChange = { [weak self] _ in self?.applyPolicy() }
        self.presenter.onDisplaysChange = { [weak self] in self?.displaysDidChange() }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationWillTerminate() }
        }
        followPauseRules()
    }

    /// Keeps `policy` in step with the "When to Pause" settings, so a toggle applies at once.
    private func followPauseRules() {
        guard let settings else { return }
        policy.rules = withObservationTracking {
            settings.pauseRules
        } onChange: { [weak self] in
            // Called before the new value is stored; read it on the next turn.
            Task { @MainActor in self?.followPauseRules() }
        }
    }

    /// Puts back desktop pictures left behind by a previous run that crashed or was killed.
    func recoverDesktopFromPreviousSession() {
        guard !isActive else { return }
        presenter.restoreOriginalDesktops()
    }

    /// The UUIDs of the connected displays, the main display first.
    var connectedDisplays: [String] { presenter.connectedDisplays }

    // MARK: - Start

    /// Shows `url` on every display, replacing any per-display choices. The desktop windows are
    /// reused.
    func start(with url: URL) {
        assign(url, to: .allDisplays)
    }

    /// Shows `url` on `target` and starts the wallpaper if it wasn't running.
    func assign(_ url: URL, to target: DisplayTarget) {
        assignments.assign(url, to: target)
        settings?.lastWallpaperURL = url
        activate()
    }

    /// The display follows the "All Displays" wallpaper again.
    func clearOverride(forDisplay id: String) {
        assignments.clearOverride(forDisplay: id)
        if isActive { refreshLayout() }
    }

    /// Forgets `url` on every display, e.g. after its file was moved to the Trash, and stops when
    /// nothing is left to show.
    func remove(_ url: URL) {
        assignments.remove(url)
        if settings?.lastWallpaperURL == url {
            settings?.lastWallpaperURL = assignments.assignments.allURLs.first
        }
        guard isActive else { return }
        if assignments.assignments.isEmpty {
            stop()
        } else {
            refreshLayout()
        }
    }

    /// Starts the wallpapers saved for each display, as they were when the app last quit.
    /// `fallback` is used when nothing was saved (e.g. after updating from a version without
    /// per-display wallpapers).
    func resumeLastSession(
        fallback: URL?,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    ) {
        assignments.removeMissingFiles(fileExists: fileExists)
        if assignments.assignments.isEmpty {
            guard let fallback else { return }
            assignments.assign(fallback, to: .allDisplays)
        }
        activate()
    }

    /// Choosing a wallpaper is a request to see it, so it also clears the user's pause.
    private func activate() {
        isActive = true
        isPaused = false
        settings?.wallpaperWasActive = true
        refreshLayout()
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

    /// Resumes a paused wallpaper, or starts the saved assignments (or `lastURL` when there are
    /// none) when nothing is playing.
    func play(orStart lastURL: URL?) {
        if isActive {
            resume()
        } else if !assignments.assignments.isEmpty {
            activate()
        } else if let lastURL {
            start(with: lastURL)
        }
    }

    /// Stops playback and gives every display its original desktop picture back. The
    /// assignments are kept for the next Play.
    func stop() {
        tearDown(animated: true) { [weak self] in
            // Unless a wallpaper was started again while the windows faded out.
            guard let self, !self.isActive else { return }
            self.presenter.restoreOriginalDesktops()
        }
        settings?.wallpaperWasActive = false
    }

    /// Restores the desktop but remembers the wallpaper was playing, so it resumes on next launch.
    private func applicationWillTerminate() {
        tearDown(animated: false) {}
        presenter.restoreOriginalDesktops()
    }

    /// Removes the players and windows but leaves the desktop picture alone.
    private func tearDown(animated: Bool, then completion: @escaping () -> Void) {
        let retired = Array(engines.values)
        engines.removeAll()
        signalSource.monitorWallpaperWindows([:])

        displayedURLs = [:]
        currentURL = nil
        isActive = false
        isPaused = false
        applyPolicy()

        presenter.dismiss(animated: animated) {
            for engine in retired { engine.tearDown() }
            completion()
        }
    }

    // MARK: - Layout

    private func displaysDidChange() {
        guard isActive else { return }
        refreshLayout()
    }

    /// Works out what every connected display shows, keeps one engine per unique wallpaper and
    /// hands the result to the presenter. Engines no longer needed are torn down once the
    /// presenter is done with them.
    private func refreshLayout() {
        let connected = presenter.connectedDisplays
        let resolved = assignments.assignments.resolved(for: connected)
        let needed = Set(resolved.values)

        var retired: [any WallpaperPlayback] = []
        for (url, engine) in engines where !needed.contains(url) {
            retired.append(engine)
            engines[url] = nil
        }
        var playbackURLs: [URL: URL] = [:]
        for url in needed {
            let playbackURL = WallpaperCacheManager.resolvedURL(for: url)
            playbackURLs[url] = playbackURL
            if engines[url] == nil { engines[url] = makeEngine(playbackURL) }
        }

        var layout: [String: PresentedWallpaper] = [:]
        for (id, url) in resolved {
            guard let engine = engines[url], let playbackURL = playbackURLs[url] else { continue }
            layout[id] = PresentedWallpaper(url: url, playbackURL: playbackURL, player: engine.player)
        }

        if displayedURLs != resolved { displayedURLs = resolved }
        let current = connected.first.flatMap { resolved[$0] } ?? assignments.assignments.allDisplays
        if currentURL != current { currentURL = current }

        presenter.present(layout) {
            for engine in retired { engine.tearDown() }
        }
        signalSource.monitorWallpaperWindows(presenter.windowsByDisplay)
        applyPolicy()
    }

    // MARK: - Policy

    /// Plays or pauses each engine to match the policy for the signals of the displays it is on,
    /// and counts the time spent in the previous state.
    private func applyPolicy() {
        var reason: PauseReason?
        var state: PlaybackState?
        if isActive {
            let signals = signalSource.signals
            var reasons: [PauseReason] = []
            var anyPlaying = false
            for (url, engine) in engines {
                let displays = Set(displayedURLs.filter { $0.value == url }.keys)
                if let engineReason = policy.decision(for: signals.restricted(to: displays), userPaused: isPaused).pauseReason {
                    engine.pause()
                    reasons.append(engineReason)
                } else {
                    engine.play()
                    anyPlaying = true
                }
            }
            if anyPlaying {
                state = .playing
            } else if let first = PauseReason.allCases.first(where: reasons.contains) {
                reason = first
                state = .paused(first)
            } else if isPaused {
                // Nothing on screen (no display has a wallpaper), but the user's pause still shows.
                reason = .user
            }
        }
        if pauseReason != reason { pauseReason = reason }
        stats.record(state)
    }
}
