import Foundation

/// Every user preference lives here, backed by `UserDefaults`.
/// Views and services read and write these properties instead of raw keys.
@Observable
final class AppSettings {
    enum Key {
        static let showDockIcon = "showDockIcon"
        static let lastWallpaperURL = "wallpaperURL"
        static let resumeWallpaperOnLaunch = "resumeWallpaperOnLaunch"
        static let wallpaperWasActive = "wallpaperWasActive"
        static let pauseWhenDesktopCovered = "pauseWhenDesktopCovered"
        static let pauseInLowPowerMode = "pauseInLowPowerMode"
        static let pauseOnBattery = "pauseOnBattery"
        static let pauseForFullScreenApps = "pauseForFullScreenApps"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let schedule = "schedule"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: Key.showDockIcon) }
    }

    /// The wallpaper most recently started; used by Play/Start and to resume on launch.
    var lastWallpaperURL: URL? {
        didSet { defaults.set(lastWallpaperURL, forKey: Key.lastWallpaperURL) }
    }

    /// Start the last wallpaper again when the app launches (e.g. at login).
    var resumeWallpaperOnLaunch: Bool {
        didSet { defaults.set(resumeWallpaperOnLaunch, forKey: Key.resumeWallpaperOnLaunch) }
    }

    /// Whether a wallpaper was playing when the app last quit. Cleared only when the user
    /// stops the wallpaper, so quitting, logging out or crashing all resume it next time.
    var wallpaperWasActive: Bool {
        didSet { defaults.set(wallpaperWasActive, forKey: Key.wallpaperWasActive) }
    }

    // MARK: When to pause

    /// Pause while other windows hide the whole desktop.
    var pauseWhenDesktopCovered: Bool {
        didSet { defaults.set(pauseWhenDesktopCovered, forKey: Key.pauseWhenDesktopCovered) }
    }

    var pauseInLowPowerMode: Bool {
        didSet { defaults.set(pauseInLowPowerMode, forKey: Key.pauseInLowPowerMode) }
    }

    var pauseOnBattery: Bool {
        didSet { defaults.set(pauseOnBattery, forKey: Key.pauseOnBattery) }
    }

    var pauseForFullScreenApps: Bool {
        didSet { defaults.set(pauseForFullScreenApps, forKey: Key.pauseForFullScreenApps) }
    }

    /// The first-run onboarding sheet has been shown (finished or skipped). "Show Welcome
    /// Again" in Settings resets this.
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    // MARK: Schedule

    /// The time-of-day slots and Light/Dark appearance variants, read and written by
    /// `ScheduleService`. Stored as one JSON blob rather than separate keys, since it's a single
    /// nested value with no reason to read or write it piecemeal.
    var schedule: Schedule {
        didSet {
            guard let data = try? JSONEncoder().encode(schedule) else { return }
            defaults.set(data, forKey: Key.schedule)
        }
    }

    /// The pause rules for `PlaybackPolicy`. Screen sleep and a locked screen always pause.
    var pauseRules: PauseRules {
        PauseRules(
            whenDesktopCovered: pauseWhenDesktopCovered,
            inLowPowerMode: pauseInLowPowerMode,
            onBattery: pauseOnBattery,
            forFullScreenApps: pauseForFullScreenApps
        )
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showDockIcon = defaults.object(forKey: Key.showDockIcon) as? Bool ?? true
        lastWallpaperURL = defaults.url(forKey: Key.lastWallpaperURL)
        resumeWallpaperOnLaunch = defaults.object(forKey: Key.resumeWallpaperOnLaunch) as? Bool ?? true
        wallpaperWasActive = defaults.bool(forKey: Key.wallpaperWasActive)
        let rules = PauseRules()
        pauseWhenDesktopCovered = defaults.object(forKey: Key.pauseWhenDesktopCovered) as? Bool ?? rules.whenDesktopCovered
        pauseInLowPowerMode = defaults.object(forKey: Key.pauseInLowPowerMode) as? Bool ?? rules.inLowPowerMode
        pauseOnBattery = defaults.object(forKey: Key.pauseOnBattery) as? Bool ?? rules.onBattery
        pauseForFullScreenApps = defaults.object(forKey: Key.pauseForFullScreenApps) as? Bool ?? rules.forFullScreenApps
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        if let data = defaults.data(forKey: Key.schedule),
           let decoded = try? JSONDecoder().decode(Schedule.self, from: data) {
            schedule = decoded
        } else {
            schedule = Schedule()
        }
    }

    /// `lastWallpaperURL`, unless it is a local file that no longer exists (e.g. it was trashed).
    func availableLastWallpaperURL(
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    ) -> URL? {
        guard let url = lastWallpaperURL else { return nil }
        return url.isFileURL && !fileExists(url) ? nil : url
    }

    /// The wallpaper to start at launch, if any: resuming is on, a wallpaper was playing when
    /// the app last quit, and it is still available.
    func wallpaperToResume(
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    ) -> URL? {
        guard resumeWallpaperOnLaunch, wallpaperWasActive else { return nil }
        return availableLastWallpaperURL(fileExists: fileExists)
    }
}
