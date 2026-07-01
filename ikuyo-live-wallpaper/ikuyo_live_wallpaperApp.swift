import SwiftUI
import SwiftData

@main
struct ikuyo_live_wallpaperApp: App {
    @State private var wallpaperManager = WallpaperManager()
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                if showSplash {
                    SplashAnimationView()
                        .environment(wallpaperManager)
                        .onAppear {
                            hideTitleBar(true)
                            applyDockPreference()
                            resizeWindowForContent()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                withAnimation(.easeInOut(duration: 0.5)) {
                                    showSplash = false
                                }
                            }
                        }
                } else {
                    ContentView()
                        .environment(wallpaperManager)
                        .onAppear {
                            hideTitleBar(false)
                            resizeWindowForContent()
                        }
                }
            }
        }

        MenuBarExtra("Ikuyo Live Wallpaper", systemImage: "photo.on.rectangle.angled") {
            Button(wallpaperManager.isActive ? "Stop Wallpaper" : "Start Wallpaper") {
                if wallpaperManager.isActive {
                    wallpaperManager.stop()
                } else {
                    let url = UserDefaults.standard.url(forKey: "wallpaperURL")
                        ?? Bundle.main.url(forResource: "test", withExtension: "mp4")
                        ?? URL(string: "about:blank")!
                    wallpaperManager.start(with: url)
                }
            }
            if wallpaperManager.isActive {
                Button("Pause") {
                    wallpaperManager.pause()
                }
            }

            Divider()

            Button("Quit") {
                wallpaperManager.stop()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
private func hideTitleBar(_ hide: Bool) {
    if let window = NSApplication.shared.windows.first {
        if hide {
            window.styleMask.remove(.titled)
        } else {
            window.styleMask.insert(.titled)
        }
    }
}

private func applyDockPreference() {
    let showInDock = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
    if !showInDock {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
}

private func resizeWindowForContent() {
    if let window = NSApplication.shared.windows.first {
        window.setContentSize(NSSize(width: 900, height: 600))
        window.center()
    }
}

