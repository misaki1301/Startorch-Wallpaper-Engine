import SwiftUI
import SwiftData

@main
struct StarTorchApp: App {
    @State private var wallpaperManager: WallpaperManager
    @State private var cacheManager: WallpaperCacheManager
    @State private var library: WallpaperLibrary
    @State private var importedStore = ImportedWallpaperStore()
    @State private var settings: AppSettings
    @State private var showSplash = true
    private let statsService = SystemStatsService()

    init() {
        let settings = AppSettings()
        let cacheManager = WallpaperCacheManager()
        // A test run must never read or change the real desktop picture.
        let desktop: any DesktopImageSetting = AppEnvironment.isHostingTests ? InertDesktop() : SystemDesktop()
        let wallpaperManager = WallpaperManager(restorer: DesktopRestorer(desktop: desktop))
        _wallpaperManager = State(initialValue: wallpaperManager)
        _settings = State(initialValue: settings)
        _cacheManager = State(initialValue: cacheManager)
        let library = WallpaperLibrary(cacheManager: cacheManager)
        _library = State(initialValue: library)
        // Refresh once per launch, independent of any window's lifetime.
        Task { await library.refreshCatalog() }
        NSApplication.shared.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)

        if !AppEnvironment.isHostingTests {
            Task {
                // If the last run crashed or was killed, its desktop pictures were never restored.
                wallpaperManager.recoverDesktopFromPreviousSession()
            }
        }
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
                            statsService.start()
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
                }
            }
        }
        .defaultSize(width: 900, height: 600)

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
