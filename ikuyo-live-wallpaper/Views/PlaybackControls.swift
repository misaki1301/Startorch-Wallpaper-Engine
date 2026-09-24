import SwiftUI

/// Play/Pause and Stop for the running wallpaper, shared by the main window toolbar
/// and the menu bar. Play starts the last wallpaper when nothing is running.
struct PlaybackControls: View {
    @Environment(WallpaperManager.self) private var manager
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if manager.isActive && !manager.isPaused {
            Button("Pause Wallpaper", systemImage: "pause.fill") {
                manager.pause()
            }
            .help("Pause the wallpaper")
        } else {
            Button(manager.isActive ? "Resume Wallpaper" : "Start Wallpaper", systemImage: "play.fill") {
                manager.play(orStart: settings.availableLastWallpaperURL())
            }
            .help(manager.isActive ? "Resume the wallpaper" : "Start the last wallpaper")
            .disabled(!manager.isActive && settings.availableLastWallpaperURL() == nil)
        }

        Button("Stop Wallpaper", systemImage: "stop.fill") {
            manager.stop()
        }
        .help("Stop the wallpaper and restore your desktop picture")
        .disabled(!manager.isActive)
    }
}
