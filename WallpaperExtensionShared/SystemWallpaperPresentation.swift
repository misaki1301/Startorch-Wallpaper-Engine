import Foundation

// Compiled into BOTH the app and the StarTorchWallpaperExtension target so the playback rules can
// be unit-tested from the app's test bundle. No private API here: the extension's host bridge
// turns WallpaperAgent's private request objects into the plain strings these types parse.

/// Where and how WallpaperAgent is showing one wallpaper surface right now.
///
/// The case names are those of the host's private `WallpaperPresentationMode` (`default`,
/// `locked`, `idle`) and `WallpaperActivityState` (`active`, `suspended`) enums, as read from the
/// macOS 27 (26A428) runtime. Unknown names — a future macOS adding cases — fall back to "show it
/// and play", which is what the desktop needs.
nonisolated struct SystemWallpaperPresentation: Equatable, Sendable {
    enum Mode: String, Sendable {
        /// The desktop.
        case desktop = "default"
        /// The lock screen / login window.
        case locked
        /// The idle (screen saver) presentation.
        case idle
        case unknown
    }

    enum Activity: String, Sendable {
        case active
        /// The host says nobody can see this surface (e.g. covered, display asleep).
        case suspended
        case unknown
    }

    /// The minimum dim on the lock screen, so the clock and the password field stay legible
    /// over a bright clip. The desktop uses exactly the user's own dim.
    static let lockScreenMinimumDim = 0.15

    var mode: Mode
    var activity: Activity

    init(mode: Mode = .desktop, activity: Activity = .active) {
        self.mode = mode
        self.activity = activity
    }

    /// From the host's enum case names; nil keeps the given default.
    init(modeName: String?, activityName: String?, default fallback: SystemWallpaperPresentation = .init()) {
        mode = modeName.map { Mode(rawValue: $0) ?? .unknown } ?? fallback.mode
        activity = activityName.map { Activity(rawValue: $0) ?? .unknown } ?? fallback.activity
    }

    /// The surface can be seen, so its video should decode.
    var wantsPlayback: Bool { activity != .suspended }

    /// The dim and vignette to draw for this presentation, starting from the user's settings.
    func overlay(dim: Double, vignette: Bool) -> (dim: Double, vignette: Bool) {
        switch mode {
        case .locked:
            return (max(dim, Self.lockScreenMinimumDim), vignette)
        case .desktop, .idle, .unknown:
            return (dim, vignette)
        }
    }
}

/// Decides whether one shared player (one decoder per unique clip) should run, given every
/// surface currently showing that clip.
nonisolated enum SystemWallpaperPlayback {
    struct Demand: Equatable, Sendable {
        /// System Settings' small preview tiles get the poster only, never a decoder.
        var isPreview: Bool
        var presentation: SystemWallpaperPresentation
    }

    /// Whether any surface showing the clip can be seen.
    static func shouldPlay(_ demands: [Demand]) -> Bool {
        demands.contains { !$0.isPreview && $0.presentation.wantsPlayback }
    }

    /// Whether the clip needs a player at all (previews alone don't).
    static func needsPlayer(_ demands: [Demand]) -> Bool {
        demands.contains { !$0.isPreview }
    }
}
