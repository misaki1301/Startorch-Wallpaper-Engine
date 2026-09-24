import SwiftUI
import SwiftData

@main
struct StarTorchApp: App {
    @State private var wallpaperManager = WallpaperManager()
    @State private var cacheManager: WallpaperCacheManager
    @State private var library: WallpaperLibrary
    @State private var importedStore = ImportedWallpaperStore()
    @State private var settings: AppSettings
    @State private var showSplash = true
    private let statsService = SystemStatsService()

    init() {
        let settings = AppSettings()
        let cacheManager = WallpaperCacheManager()
        _settings = State(initialValue: settings)
        _cacheManager = State(initialValue: cacheManager)
        _library = State(initialValue: WallpaperLibrary(cacheManager: cacheManager))
        NSApplication.shared.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if showSplash {
                    SplashAnimationView()
                        .environment(wallpaperManager)
                        .environment(cacheManager)
                        .environment(importedStore)
                        .environment(settings)
                        .environment(library)
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
                        .environment(settings)
                        .environment(library)
                        .onAppear {
                            hideTitleBar(false)
                            resizeWindowForContent()
                        }
                }
            }
            .task { await library.refreshCatalog() }
        }

        MenuBarExtra("StarTorch", systemImage: "photo.on.rectangle.angled") {
            StatsMenuView(stats: statsService)

            Divider()

            Button(wallpaperManager.isActive ? "Stop Wallpaper" : "Start Wallpaper") {
                if wallpaperManager.isActive {
                    wallpaperManager.stop()
                } else {
                    let url = settings.lastWallpaperURL
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

