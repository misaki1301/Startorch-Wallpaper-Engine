import AppIntents

/// The Shortcuts phrases Siri and the Shortcuts app expose for StarTorch, plus what shows up
/// under the app's name in Spotlight/Shortcuts search.
struct StarTorchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetWallpaperIntent(),
            phrases: [
                "Set a wallpaper in \(.applicationName)",
                "Change my wallpaper with \(.applicationName)",
            ],
            shortTitle: "Set Wallpaper",
            systemImageName: "photo.on.rectangle.angled"
        )
        AppShortcut(
            intent: PauseWallpaperIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Pause my wallpaper in \(.applicationName)",
            ],
            shortTitle: "Pause Wallpaper",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeWallpaperIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Resume my wallpaper in \(.applicationName)",
            ],
            shortTitle: "Resume Wallpaper",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: StopWallpaperIntent(),
            phrases: [
                "Stop \(.applicationName)",
                "Stop my wallpaper in \(.applicationName)",
            ],
            shortTitle: "Stop Wallpaper",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: NextFavoriteWallpaperIntent(),
            phrases: [
                "Next favorite wallpaper in \(.applicationName)",
                "Set my next favorite in \(.applicationName)",
            ],
            shortTitle: "Next Favorite",
            systemImageName: "heart.fill"
        )
    }
}
