import Foundation
import Observation
import os

/// Keeps the system wallpaper extension (lock screen & desktop) and the screen saver in sync with
/// whatever wallpaper StarTorch is currently playing, with no manual "Export" click.
///
/// Three things can make an export stale, and each is *observed*, not polled, exactly like
/// `ScreenSaverExporter` already follows `WallpaperManager`:
///
/// - the current wallpaper changing (covers `start`/`apply`, schedules, shuffle, App Intents and
///   `resumeLastSession`, since they all go through `WallpaperManager.currentURL`),
/// - that wallpaper's readability settings changing (dragging the dim/vignette/speed controls),
/// - a pending remote wallpaper's download finishing, when it was the sync's target.
///
/// Every trigger reschedules a single ~1.5s debounce, so a burst of changes (dragging a slider,
/// shuffling) produces one export of the last target rather than one per change. When a newer
/// target arrives while an export is still running, that export is cancelled first.
///
/// The system wallpaper is synced before the screen saver, never in parallel, so at most one big
/// copy/transcode runs at a time (see `runSyncPass`).
///
/// Stopping playback is not itself a reason to change anything: `WallpaperManager.currentURL`
/// becomes nil, `sourceURL` in each exporter (and the target this coordinator computes) falls
/// back to `AppSettings.availableLastWallpaperURL()`, so the last export is simply left in place
/// — the lock screen never goes blank because the desktop engine paused.
///
/// Per-display assignments aren't part of this: the system extension and the screen saver each
/// show one clip, so auto-sync always uses the wallpaper `WallpaperManager.currentURL` reports
/// (the "All Displays" / primary assignment). Per-display lock-screen clips are a follow-up.
@MainActor
@Observable
final class ExportCoordinator {
    @ObservationIgnored private let manager: WallpaperManager
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let cacheManager: WallpaperCacheManager
    @ObservationIgnored private let titleForWallpaper: (URL) -> String
    @ObservationIgnored private let screenSaverInstalled: () -> Bool
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let sleep: (Duration) async throws -> Void

    let systemWallpaperExporter: WallpaperExtensionExporter
    let screenSaverExporter: ScreenSaverExporter

    /// Waiting on a remote wallpaper's download before that target can be exported. Neither
    /// exporter knows about pending downloads on its own — only the coordinator does — so this is
    /// overlaid in front of the exporter's own `syncPhase` by `systemWallpaperSyncPhase` /
    /// `screenSaverSyncPhase` below, which is what the UI should read.
    private(set) var isWaitingForSystemWallpaperDownload = false
    private(set) var isWaitingForScreenSaverDownload = false

    /// How many times each exporter's `export` was actually invoked. Not used by the UI; it's
    /// what the tests use to check debouncing and no-op skipping without reaching into private
    /// exporter internals.
    @ObservationIgnored private(set) var systemWallpaperExportCount = 0
    @ObservationIgnored private(set) var screenSaverExportCount = 0
    @ObservationIgnored private(set) var syncPassCount = 0

    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    /// Bumped at the start of every sync pass. A download-watch loop started by an older pass
    /// checks this before acting, so a selection change during a wait never exports the stale
    /// target once the old download finishes.
    @ObservationIgnored private var passToken = 0

    private static let log = Logger(subsystem: "com.shibuyaxpress.startorch-wallpaper", category: "ExportCoordinator")

    /// - Parameters:
    ///   - titleForWallpaper: Resolves a wallpaper's display name — the catalog/imported item's
    ///     name, falling back to the file name — the same way Settings names a manual export.
    ///   - screenSaverInstalled: Whether `StarTorch.saver` is installed, where that's detectable.
    ///     Defaults to checking the well-known `Library/Screen Savers` folders. See
    ///     `shouldAutoSyncScreenSaver`.
    ///   - debounce: How long to wait after the last trigger before syncing.
    ///   - sleep: Stands in for `Task.sleep` so tests don't wait on a real clock.
    init(
        manager: WallpaperManager,
        settings: AppSettings,
        cacheManager: WallpaperCacheManager,
        systemWallpaperExporter: WallpaperExtensionExporter,
        screenSaverExporter: ScreenSaverExporter,
        titleForWallpaper: @escaping (URL) -> String,
        screenSaverInstalled: @escaping () -> Bool = ExportCoordinator.defaultScreenSaverInstalled,
        debounce: Duration = .milliseconds(1500),
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.manager = manager
        self.settings = settings
        self.cacheManager = cacheManager
        self.systemWallpaperExporter = systemWallpaperExporter
        self.screenSaverExporter = screenSaverExporter
        self.titleForWallpaper = titleForWallpaper
        self.screenSaverInstalled = screenSaverInstalled
        self.debounce = debounce
        self.sleep = sleep
    }

    /// Starts observing the triggers above. Call once; `StarTorchApp` never calls this under the
    /// test host, so a unit test never races real auto-sync unless it builds its own coordinator.
    func start() {
        followCurrentWallpaper()
        followReadability()
        // Covers whatever's already current at launch (e.g. a resumed session) without waiting
        // for the next change.
        scheduleSync()
    }

    // MARK: - Sync state for the UI

    var systemWallpaperSyncPhase: WallpaperSyncPhase {
        isWaitingForSystemWallpaperDownload ? .waitingForDownload : systemWallpaperExporter.syncPhase
    }

    var screenSaverSyncPhase: WallpaperSyncPhase {
        isWaitingForScreenSaverDownload ? .waitingForDownload : screenSaverExporter.syncPhase
    }

    /// Whether auto-sync is currently allowed to export the screen saver: the toggle is on, and
    /// either the saver is installed or it's been exported before. That second half means someone
    /// who has never touched the screen saver feature never pays for a background transcode just
    /// because the toggle defaults to on; once they install the saver or sync it by hand once,
    /// auto-sync takes over from there.
    var shouldAutoSyncScreenSaver: Bool {
        settings.autoSyncScreenSaver && (screenSaverInstalled() || screenSaverExporter.status != .neverExported)
    }

    // MARK: - Triggers (observed, not polled)

    private func followCurrentWallpaper() {
        _ = withObservationTracking {
            manager.currentURL
        } onChange: { [weak self] in
            // Observation fires before the new value is stored; read it on the next turn.
            Task { @MainActor in
                guard let self else { return }
                self.scheduleSync()
                self.followCurrentWallpaper()
            }
        }
    }

    private func followReadability() {
        _ = withObservationTracking {
            settings.readabilityByWallpaper
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduleSync()
                self.followReadability()
            }
        }
    }

    /// Watches `url`'s download while a sync pass is waiting on it. `token` ties this loop to the
    /// pass that started it, so it stops mattering the moment a newer pass begins.
    ///
    /// Two things drive the re-check: `withObservationTracking` on the whole `states` dictionary
    /// (reading a single key back out of it doesn't reliably register as a dependency for
    /// Observation's tracking, unlike `manager.currentURL` or `settings.readabilityByWallpaper`
    /// above, so this reads the property itself) is the primary trigger, and a ~2s fallback timer
    /// is the safety net — re-checking is cheap, and it means a download that finishes between
    /// two Observation ticks costs at most one extra ~2s wait rather than leaving the lock screen
    /// stuck on "waiting for download" indefinitely.
    private func followDownload(for url: URL, token: Int) {
        _ = withObservationTracking {
            cacheManager.states
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.passToken == token else { return }
                self.scheduleSync()
                self.followDownload(for: url, token: token)
            }
        }
        Task { [weak self, sleep] in
            try? await sleep(.seconds(2))
            guard let self, self.passToken == token else { return }
            self.scheduleSync()
        }
    }

    // MARK: - Debounce

    private func scheduleSync() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounce, sleep] in
            guard let self else { return }
            try? await sleep(debounce)
            guard !Task.isCancelled else { return }
            await self.runSyncPass()
        }
    }

    // MARK: - Sync pass

    private func runSyncPass() async {
        syncPassCount += 1
        passToken += 1
        let token = passToken
        let target = manager.currentURL ?? settings.availableLastWallpaperURL()

        guard let target else {
            // Nothing playing and nothing to resume: there's nothing to sync to, so the last
            // export (if any) is simply left in place.
            isWaitingForSystemWallpaperDownload = false
            isWaitingForScreenSaverDownload = false
            return
        }

        let readability = settings.readability(for: target)
        // The instance method, not the static `resolvedURL(for:)`, which defaults to the real
        // app cache directory: with an injected `cacheManager` (tests), that default silently
        // misses everything the injected instance actually downloaded to its own directory.
        let resolved = cacheManager.cachedURL(for: target) ?? target
        let isAvailableLocally = resolved.isFileURL

        // The system wallpaper first, then the screen saver — never in parallel, so at most one
        // big copy/transcode is running at any moment.
        if settings.autoSyncSystemWallpaper {
            await syncSystemWallpaper(target: target, resolved: resolved, isAvailableLocally: isAvailableLocally, readability: readability, token: token)
        } else {
            isWaitingForSystemWallpaperDownload = false
        }
        guard passToken == token else { return } // superseded while the system wallpaper synced

        if shouldAutoSyncScreenSaver {
            await syncScreenSaver(target: target, isAvailableLocally: isAvailableLocally, token: token)
        } else {
            isWaitingForScreenSaverDownload = false
        }
    }

    private func syncSystemWallpaper(
        target: URL,
        resolved: URL,
        isAvailableLocally: Bool,
        readability: ReadabilitySettings,
        token: Int
    ) async {
        guard isAvailableLocally else {
            isWaitingForSystemWallpaperDownload = true
            followDownload(for: target, token: token)
            return
        }
        isWaitingForSystemWallpaperDownload = false
        guard !systemWallpaperExporter.matchesCurrentExport(sourceURL: target, readability: readability) else { return }

        if systemWallpaperExporter.isExporting {
            systemWallpaperExporter.cancelExport()
            await waitWhileExporting(systemWallpaperExporter)
        }
        guard passToken == token else { return } // a newer target arrived while we waited

        let title = titleForWallpaper(target)
        let succeeded = await systemWallpaperExporter.export(sourceURL: target, playbackURL: resolved, title: title, readability: readability)
        // Counted on completion, not on invocation, so tests that wait on this count can rely on
        // the manifest already being written (or the failure already recorded).
        systemWallpaperExportCount += 1
        if succeeded {
            Self.log.notice("auto-synced the system wallpaper to \(target.lastPathComponent, privacy: .public)")
        }
    }

    private func syncScreenSaver(target: URL, isAvailableLocally: Bool, token: Int) async {
        guard isAvailableLocally else {
            isWaitingForScreenSaverDownload = true
            followDownload(for: target, token: token)
            return
        }
        isWaitingForScreenSaverDownload = false
        // `ScreenSaverExporter` already follows the manager and readability itself, so its own
        // `status` is the source of truth for whether this target/readability is current.
        guard screenSaverExporter.sourceURL == target, !isUpToDate(screenSaverExporter.status) else {
            return
        }

        if screenSaverExporter.isExporting {
            screenSaverExporter.cancelExport()
            await waitWhileExporting(screenSaverExporter)
        }
        guard passToken == token else { return }
        try? await screenSaverExporter.exportCurrentWallpaper()
        screenSaverExportCount += 1
    }

    private func isUpToDate(_ status: ScreenSaverExportStatus) -> Bool {
        if case .upToDate = status { return true }
        return false
    }

    private func waitWhileExporting(_ exporter: WallpaperExtensionExporter) async {
        while exporter.isExporting {
            try? await sleep(.milliseconds(20))
        }
    }

    private func waitWhileExporting(_ exporter: ScreenSaverExporter) async {
        while exporter.isExporting {
            try? await sleep(.milliseconds(20))
        }
    }

    /// `~/Library/Screen Savers/StarTorch.saver` or `/Library/Screen Savers/StarTorch.saver`.
    nonisolated static func defaultScreenSaverInstalled() -> Bool {
        let fileManager = FileManager.default
        let candidates = [
            ScreenSaverHandoff.realHomeDirectory.appending(path: "Library/Screen Savers/StarTorch.saver", directoryHint: .isDirectory),
            URL(filePath: "/Library/Screen Savers/StarTorch.saver", directoryHint: .isDirectory),
        ]
        return candidates.contains { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
}
