import SwiftUI
import SwiftData

@main
struct StarTorchApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var wallpaperManager: WallpaperManager
    @State private var cacheManager: WallpaperCacheManager
    @State private var library: WallpaperLibrary
    @State private var importedStore = ImportedWallpaperStore()
    @State private var settings: AppSettings
    private let statsService = SystemStatsService()

    init() {
        let settings = AppSettings()
        let cacheManager = WallpaperCacheManager()
        // A test run must never read or change the real desktop picture.
        let desktop: any DesktopImageSetting = AppEnvironment.isHostingTests ? InertDesktop() : SystemDesktop()
        let wallpaperManager = WallpaperManager(restorer: DesktopRestorer(desktop: desktop), settings: settings)
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
                if let url = settings.wallpaperToResume() {
                    wallpaperManager.start(with: url)
                }
            }
        }
    }

    var body: some Scene {
        // A single window, so "Open StarTorch…" brings it back instead of stacking copies. The
        // system restores its frame; there's no forced size or splash on top of that.
        Window("StarTorch", id: MainWindow.id) {
            ContentView()
                .environment(wallpaperManager)
                .environment(cacheManager)
                .environment(importedStore)
                .environment(settings)
                .environment(library)
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About StarTorch") {
                    AboutPanel.show()
                }
            }
        }

        Settings {
            SettingsView()
                .environment(cacheManager)
                .environment(settings)
                .environment(wallpaperManager)
        }

        MenuBarExtra("StarTorch", systemImage: "photo.on.rectangle.angled") {
            MenuBarPanelView(stats: statsService)
                .environment(wallpaperManager)
                .environment(settings)
                .environment(library)
        }
        .menuBarExtraStyle(.window)
    }
}

enum MainWindow {
    static let id = "main"
}
