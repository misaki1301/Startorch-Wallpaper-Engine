import Foundation

/// Every user preference lives here, backed by `UserDefaults`.
/// Views and services read and write these properties instead of raw keys.
@Observable
final class AppSettings {
    enum Key {
        static let showDockIcon = "showDockIcon"
        static let lastWallpaperURL = "wallpaperURL"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: Key.showDockIcon) }
    }

    /// The wallpaper most recently started; used by the menu bar Start button.
    var lastWallpaperURL: URL? {
        didSet { defaults.set(lastWallpaperURL, forKey: Key.lastWallpaperURL) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showDockIcon = defaults.object(forKey: Key.showDockIcon) as? Bool ?? true
        lastWallpaperURL = defaults.url(forKey: Key.lastWallpaperURL)
    }
}
