import AppIntents

/// The Focus filter offered in System Settings › Focus › (a Focus) › Add Filter: "Pause Wallpaper
/// while this Focus is on."
///
/// `SetFocusFilterIntent.perform()` is called by the system on both edges of the Focus, not just
/// activation: when the Focus turns on, it's called with `isPauseEnabled` set to whatever the
/// user configured for that Focus; when the Focus turns off, it's called again on a fresh
/// instance whose `@Parameter` is back at its declared default (`false`). That's why the default
/// is `false` rather than `true` — it's what "off" means here, and there's no separate
/// "did deactivate" callback to hook into.
struct PauseWhileFocusIntent: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Pause Wallpaper"
    static let description = IntentDescription(
        "Pauses StarTorch's wallpaper while this Focus is on, and resumes it when the Focus turns off — unless you paused it yourself, in which case turning the Focus off leaves your pause alone."
    )

    @Parameter(title: "Pause Wallpaper", default: false)
    var isPauseEnabled: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: isPauseEnabled ? "Pause Wallpaper" : "Don't Pause Wallpaper")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        WallpaperFocusCoordinator.shared.setFilterActive(isPauseEnabled)
        return .result()
    }
}
