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
        static let readabilityByWallpaper = "readabilityByWallpaper"
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

    // MARK: Readability

    /// Dim, blur, vignette and speed per wallpaper, keyed by `URL.absoluteString`. Wallpapers
    /// with the default settings have no entry.
    private(set) var readabilityByWallpaper: [String: ReadabilitySettings] {
        didSet {
            defaults.set(try? JSONEncoder().encode(readabilityByWallpaper), forKey: Key.readabilityByWallpaper)
        }
    }

    func readability(for url: URL) -> ReadabilitySettings {
        readabilityByWallpaper[url.absoluteString] ?? ReadabilitySettings()
    }

    func setReadability(_ readability: ReadabilitySettings, for url: URL) {
        let value = readability.clamped
        let key = url.absoluteString
        guard readabilityByWallpaper[key] ?? ReadabilitySettings() != value else { return }
        readabilityByWallpaper[key] = value.isDefault ? nil : value
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
        readabilityByWallpaper = defaults.data(forKey: Key.readabilityByWallpaper)
            .flatMap { try? JSONDecoder().decode([String: ReadabilitySettings].self, from: $0) } ?? [:]
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
