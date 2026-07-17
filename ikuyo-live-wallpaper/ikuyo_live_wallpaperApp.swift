import SwiftUI
import SwiftData

@main
struct ikuyo_live_wallpaperApp: App {
    @State private var wallpaperManager = WallpaperManager()
    @State private var cacheManager = WallpaperCacheManager()
    @State private var importedStore = ImportedWallpaperStore()
    @State private var showSplash = true
    private let statsService = SystemStatsService()

    init() {
        let showInDock = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
        NSApplication.shared.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if showSplash {
                    SplashAnimationView()
                        .environment(wallpaperManager)
                        .environment(cacheManager)
                        .environment(importedStore)
                        .onAppear {
                            hideTitleBar(true)
                            statsService.start()
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
                        .environment(cacheManager)
                        .environment(importedStore)
                        .onAppear {
                            hideTitleBar(false)
                            resizeWindowForContent()
                        }
                }
            }
        }

        MenuBarExtra("Ikuyo Live Wallpaper", systemImage: "photo.on.rectangle.angled") {
            StatsMenuView(stats: statsService)

            Divider()

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
                if wallpaperManager.isPaused {
                    Button("Resume") {
                        wallpaperManager.resume()
                    }
                } else {
                    Button("Pause") {
                        wallpaperManager.pause()
                    }
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
struct StatsMenuView: View {
    @ObservedObject var stats: SystemStatsService

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("CPU:")
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f%%", stats.cpuUsage))
                    .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 12)

            HStack {
                Text("RAM:")
                    .foregroundStyle(.secondary)
                Text("\(stats.memoryUsedFormatted) / \(stats.memoryTotalFormatted)")
                    .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 4)
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

private func resizeWindowForContent() {
    if let window = NSApplication.shared.windows.first {
        window.setContentSize(NSSize(width: 900, height: 600))
        window.center()
    }
}

