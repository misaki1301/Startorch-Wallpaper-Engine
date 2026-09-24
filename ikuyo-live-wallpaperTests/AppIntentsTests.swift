import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

private let twoItemCatalogJSON = Data("""
{
  "version": 1,
  "wallpapers": [
    {"id": "rain", "title": "Rain", "creator": "A", "license": "CC0", "url": "https://example.com/rain.mp4"},
    {"id": "snow", "title": "Snow", "creator": "A", "license": "CC0", "url": "https://example.com/snow.mp4"}
  ]
}
""".utf8)

@MainActor
private func makeManager(presenter: FakePresenter = FakePresenter(), signals: FakeSignals = FakeSignals()) -> WallpaperManager {
    WallpaperManager(
        restorer: DesktopRestorer(desktop: InertDesktop(), directory: .temporaryDirectory),
        presenter: presenter,
        signals: signals,
        makeEngine: { FakeEngine(url: $0) }
    )
}

@MainActor
private func makeLibraryWithTwoFavorites() throws -> WallpaperLibrary {
    let dir = try makeTempDirectory()
    try twoItemCatalogJSON.write(to: dir.appending(path: "bundled.json"))
    let service = CatalogService(cacheURL: dir.appending(path: "missing.json"), bundledURL: dir.appending(path: "bundled.json"))
    let library = WallpaperLibrary(directory: dir, defaults: makeDefaults(), catalogService: service)
    library.setFavorite(true, for: URL(string: "https://example.com/rain.mp4")!)
    library.setFavorite(true, for: URL(string: "https://example.com/snow.mp4")!)
    return library
}

/// Bridges the intents under test to fakes, and restores whatever was there before — the bridge
/// is process-wide static state, so tests must never leak into each other or into the app.
@MainActor
private func withBridgedManager<T>(
    manager: WallpaperManager?,
    library: WallpaperLibrary? = nil,
    settings: AppSettings? = nil,
    _ body: () async throws -> T
) async rethrows -> T {
    let savedManager = WallpaperIntentBridge.manager
    let savedLibrary = WallpaperIntentBridge.library
    let savedSettings = WallpaperIntentBridge.settings
    WallpaperIntentBridge.manager = manager
    WallpaperIntentBridge.library = library
    WallpaperIntentBridge.settings = settings
    defer {
        WallpaperIntentBridge.manager = savedManager
        WallpaperIntentBridge.library = savedLibrary
        WallpaperIntentBridge.settings = savedSettings
    }
    return try await body()
}

@MainActor
struct AppIntentsTests {
    let video = URL(filePath: "/tmp/imported/rain.mp4")

    @Test func setWallpaperIntentStartsTheGivenWallpaper() async throws {
        let manager = makeManager()
        try await withBridgedManager(manager: manager) {
            let intent = SetWallpaperIntent()
            intent.wallpaper = WallpaperEntity(item: WallpaperItem(url: video, name: "Rain"))
            _ = try await intent.perform()
            #expect(manager.currentURL == video)
            #expect(manager.isPlaying)
        }
    }

    @Test func pauseAndResumeIntentsControlTheRunningWallpaper() async throws {
        let manager = makeManager()
        manager.start(with: video)
        try await withBridgedManager(manager: manager) {
            _ = try await PauseWallpaperIntent().perform()
            #expect(manager.isPaused)

            _ = try await ResumeWallpaperIntent().perform()
            #expect(!manager.isPaused)
            #expect(manager.isPlaying)
        }
    }

    @Test func stopIntentStopsAndRestoresTheDesktop() async throws {
        let presenter = FakePresenter()
        let manager = makeManager(presenter: presenter)
        manager.start(with: video)
        try await withBridgedManager(manager: manager) {
            _ = try await StopWallpaperIntent().perform()
            #expect(!manager.isActive)
            #expect(presenter.restoreCount == 1)
        }
    }

    @Test func intentsThrowBeforeTheAppIsReady() async {
        _ = await withBridgedManager(manager: nil) {
            await #expect(throws: WallpaperIntentError.self) {
                _ = try await PauseWallpaperIntent().perform()
            }
        }
    }

    @Test func nextFavoriteStartsTheFirstFavoriteWhenNothingIsPlaying() async throws {
        let manager = makeManager()
        let library = try makeLibraryWithTwoFavorites()
        try await withBridgedManager(manager: manager, library: library) {
            _ = try await NextFavoriteWallpaperIntent().perform()
            #expect(manager.currentURL != nil)
            #expect(library.favoriteCatalogItems.map(\.url).contains(manager.currentURL!))
        }
    }

    @Test func nextFavoriteWrapsAroundToTheFirstAfterTheLast() async throws {
        let manager = makeManager()
        let library = try makeLibraryWithTwoFavorites()
        let favorites = library.favoriteCatalogItems
        manager.start(with: favorites[1].url)
        try await withBridgedManager(manager: manager, library: library) {
            _ = try await NextFavoriteWallpaperIntent().perform()
            #expect(manager.currentURL == favorites[0].url)
        }
    }

    @Test func nextFavoriteWithNoFavoritesLeavesPlaybackAlone() async throws {
        let manager = makeManager()
        let library = try makeLibraryWithTwoFavorites()
        library.setFavorite(false, for: URL(string: "https://example.com/rain.mp4")!)
        library.setFavorite(false, for: URL(string: "https://example.com/snow.mp4")!)
        try await withBridgedManager(manager: manager, library: library) {
            _ = try await NextFavoriteWallpaperIntent().perform()
            #expect(manager.currentURL == nil)
        }
    }
}

@MainActor
struct WallpaperFocusCoordinatorTests {
    let video = URL(filePath: "/tmp/imported/rain.mp4")

    @Test func activatingTheFilterPausesARunningWallpaper() async {
        let manager = makeManager()
        let coordinator = WallpaperFocusCoordinator()
        manager.start(with: video)
        await withBridgedManager(manager: manager) {
            coordinator.setFilterActive(true)
            #expect(manager.isPaused)
        }
    }

    @Test func deactivatingResumesOnlyWhatTheFilterItselfPaused() async {
        let manager = makeManager()
        let coordinator = WallpaperFocusCoordinator()
        manager.start(with: video)
        await withBridgedManager(manager: manager) {
            coordinator.setFilterActive(true)
            coordinator.setFilterActive(false)
            #expect(!manager.isPaused)
        }
    }

    @Test func aPauseTheUserSetBeforeTheFocusIsLeftAloneWhenTheFocusEnds() async {
        let manager = makeManager()
        let coordinator = WallpaperFocusCoordinator()
        manager.start(with: video)
        manager.pause()
        await withBridgedManager(manager: manager) {
            // The filter finds the wallpaper already paused, so it claims no credit for it…
            coordinator.setFilterActive(true)
            #expect(manager.isPaused)
            // …and deactivating must not resume a pause it didn't cause.
            coordinator.setFilterActive(false)
            #expect(manager.isPaused)
        }
    }
}
