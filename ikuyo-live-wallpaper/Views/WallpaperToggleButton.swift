import SwiftUI

struct WallpaperToggleButton: View {
    let videoURL: URL
    @Environment(WallpaperManager.self) private var manager

    var body: some View {
        Button(manager.isActive ? "Stop Wallpaper" : "Set as Wallpaper") {
            if manager.isActive {
                manager.stop()
            } else {
                manager.start(with: videoURL)
            }
        }
        if manager.isActive {
            Button("Pause Wallpaper") {
                manager.pause()
            }
        }

    }
}

#Preview {
    WallpaperToggleButton(videoURL: URL(string: "https://example.com/sample.mp4")!)
        .environment(WallpaperManager())
}
