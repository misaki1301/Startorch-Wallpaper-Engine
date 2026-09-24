import Foundation

/// Bridges App Intents, `AppShortcutsProvider` phrases and the Focus filter — all instantiated
/// fresh by the system, with no SwiftUI environment to read from — to the single
/// `WallpaperManager`/`WallpaperLibrary`/`ImportedWallpaperStore` instances `StarTorchApp` creates
/// once at launch and hands to every view.
///
/// `StarTorchApp.init()` sets these right after creating that trio, but never under the test
/// host, so a unit test never reads or writes this shared, process-wide state; tests that need
/// intent behavior set it themselves for the duration of the test.
@MainActor
enum WallpaperIntentBridge {
    static var manager: WallpaperManager?
    static var library: WallpaperLibrary?
    static var importedStore: ImportedWallpaperStore?
    static var settings: AppSettings?
}
