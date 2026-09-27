import SwiftUI
import SwiftData

@main
struct StarTorchApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var wallpaperManager: WallpaperManager
    @State private var cacheManager: WallpaperCacheManager
    @State private var library: WallpaperLibrary
    @State private var importedStore: ImportedWallpaperStore
    @State private var settings: AppSettings
    @State private var scheduleService: ScheduleService
    @State private var screenSaverExporter: ScreenSaverExporter
    @State private var systemWallpaperExporter: WallpaperExtensionExporter
    @State private var exportCoordinator: ExportCoordinator
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
        let importedStore = ImportedWallpaperStore()
        _importedStore = State(initialValue: importedStore)
        // A test run must never touch the desktop appearance/wake/clock notification centers.
        let scheduleService = ScheduleService(
            manager: wallpaperManager,
            library: library,
            settings: settings,
            observeSystemEvents: !AppEnvironment.isHostingTests
        )
        _scheduleService = State(initialValue: scheduleService)
        // A test run must never read or write the real screen saver handoff folder.
        let screenSaverExporter = ScreenSaverExporter(
            manager: wallpaperManager,
            settings: settings,
            directory: AppEnvironment.isHostingTests
                ? .temporaryDirectory.appending(path: "screensaver-handoff-\(UUID().uuidString)", directoryHint: .isDirectory)
                : ScreenSaverExporter.defaultDirectory
        )
        _screenSaverExporter = State(initialValue: screenSaverExporter)

        let systemWallpaperExporter = WallpaperExtensionExporter()
        _systemWallpaperExporter = State(initialValue: systemWallpaperExporter)
        systemWallpaperExporter.refreshStatus()

        // Keeps the system wallpaper extension and the screen saver following whatever
        // StarTorch is playing, with no manual export click. A test run must never start this
        // against real directories or the real App Group container.
        let exportCoordinator = ExportCoordinator(
            manager: wallpaperManager,
            settings: settings,
            cacheManager: cacheManager,
            systemWallpaperExporter: systemWallpaperExporter,
            screenSaverExporter: screenSaverExporter,
            titleForWallpaper: { url in
                (library.catalog + importedStore.items).first { $0.url == url }?.name
                    ?? url.deletingPathExtension().lastPathComponent
            }
        )
        _exportCoordinator = State(initialValue: exportCoordinator)
        if !AppEnvironment.isHostingTests {
            exportCoordinator.start()
        }

        // Refresh once per launch, independent of any window's lifetime.
        Task { await library.refreshCatalog() }
        NSApplication.shared.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)

        if !AppEnvironment.isHostingTests {
            // App Intents, Shortcuts and the Focus filter are instantiated by the system, not by
            // SwiftUI, so they have no environment to read from — they go through this bridge to
            // reach the very instances the UI uses. Never wired under the test host, so a unit
            // test never touches a shared, process-wide static.
            WallpaperIntentBridge.manager = wallpaperManager
            WallpaperIntentBridge.library = library
            WallpaperIntentBridge.importedStore = importedStore
            WallpaperIntentBridge.settings = settings

            Task {
                // If the last run crashed or was killed, its desktop pictures were never restored.
                wallpaperManager.recoverDesktopFromPreviousSession()
                if let url = settings.wallpaperToResume() {
                    // Brings back each display's own wallpaper; `url` covers older installs.
                    wallpaperManager.resumeLastSession(fallback: url)
                }
            }
        }
    }

    var body: some Scene {
        // A single window, so "Open StarTorch…" brings it back instead of stacking copies. The
        // system restores its frame; there's no forced size or splash on top of that.
        Window("StarTorch", id: MainWindow.id) {
            AppRootView()
                .environment(wallpaperManager)
                .environment(cacheManager)
                .environment(importedStore)
                .environment(settings)
                .environment(library)
                .environment(scheduleService)
                .environment(screenSaverExporter)
                .environment(systemWallpaperExporter)
                .environment(exportCoordinator)
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
                .environment(library)
                .environment(importedStore)
                .environment(scheduleService)
                .environment(screenSaverExporter)
                .environment(systemWallpaperExporter)
                .environment(exportCoordinator)
        }

        MenuBarExtra("StarTorch", systemImage: "photo.on.rectangle.angled") {
            MenuBarPanelView(stats: statsService)
                .environment(wallpaperManager)
                .environment(settings)
                .environment(library)
                .environment(exportCoordinator)
        }
        .menuBarExtraStyle(.window)
    }
}

enum MainWindow {
    static let id = "main"
}
