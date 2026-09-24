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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showDockIcon = defaults.object(forKey: Key.showDockIcon) as? Bool ?? true
        lastWallpaperURL = defaults.url(forKey: Key.lastWallpaperURL)
        resumeWallpaperOnLaunch = defaults.object(forKey: Key.resumeWallpaperOnLaunch) as? Bool ?? true
        wallpaperWasActive = defaults.bool(forKey: Key.wallpaperWasActive)
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
