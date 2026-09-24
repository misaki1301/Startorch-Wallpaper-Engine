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
        }

        MenuBarExtra("StarTorch", systemImage: "photo.on.rectangle.angled") {
            MenuBarContent(stats: statsService)
                .environment(wallpaperManager)
                .environment(settings)
        }
    }
}

enum MainWindow {
    static let id = "main"
}

struct MenuBarContent: View {
    let stats: SystemStatsService
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(WallpaperManager.self) private var manager

    var body: some View {
        StatsMenuView(stats: stats)

        Divider()

        PlaybackControls()
        // Explain automatic pauses; a pause by the user already shows as "Resume".
        if let reason = manager.pauseReason, reason != .user {
            Text("Paused: \(reason.label)")
        }

        Divider()

        Button("Open StarTorch…") {
            NSApplication.shared.activate()
            openWindow(id: MainWindow.id)
        }
        Button("Settings…") {
            NSApplication.shared.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
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
        // The menu bar extra's content view stays alive even while the menu is closed, so without
        // this the 2-second poll would run for the app's entire lifetime for no reason.
        .onAppear { stats.start() }
        .onDisappear { stats.stop() }
    }
}
