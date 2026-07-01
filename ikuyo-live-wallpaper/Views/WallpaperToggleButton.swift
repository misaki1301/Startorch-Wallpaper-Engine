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
    WallpaperToggleButton(videoURL: URL(string: "https://cdn.donmai.us/original/44/2a/442a58406a379375c3ff4c8d676b8c19.mp4")!)
        .environment(WallpaperManager())
}
