import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "StarTorchTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func makeDefaults() -> UserDefaults {
    let suite = "StarTorchTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private let sampleCatalogJSON = Data("""
{
  "version": 1,
  "wallpapers": [
    {
      "id": "rain",
      "title": "Rainy Window",
      "creator": "Jane Doe",
      "license": "CC BY 4.0",
      "url": "https://example.com/rain.mp4",
      "fps": 30
    }
  ]
}
""".utf8)

@MainActor
struct CatalogTests {
    @Test func decodesRequiredAndOptionalFields() throws {
        let catalog = try CatalogService.decode(sampleCatalogJSON)
        #expect(catalog.version == 1)
        let entry = try #require(catalog.wallpapers.first)
        #expect(entry.title == "Rainy Window")
        #expect(entry.fps == 30)
        #expect(entry.width == nil)
    }

    @Test func mapsEntriesToItemsWithCredits() throws {
        let item = try #require(try CatalogService.decode(sampleCatalogJSON).items.first)
        #expect(item.name == "Rainy Window")
        #expect(item.creator == "Jane Doe")
        #expect(item.license == "CC BY 4.0")
        #expect(item.id == "https://example.com/rain.mp4")
    }

    @Test func rejectsEntriesMissingALicense() {
        let json = Data(#"{"version":1,"wallpapers":[{"id":"x","title":"X","creator":"Y","url":"https://e.com/x.mp4"}]}"#.utf8)
        #expect(throws: DecodingError.self) { try CatalogService.decode(json) }
    }

    @Test func loadPrefersCacheOverBundle() throws {
        let dir = try makeTempDirectory()
        let cache = dir.appending(path: "cache.json")
        let bundled = dir.appending(path: "bundled.json")
        try sampleCatalogJSON.write(to: cache)
        try JSONEncoder().encode(Catalog.empty).write(to: bundled)

        let service = CatalogService(cacheURL: cache, bundledURL: bundled)
        #expect(service.load().wallpapers.count == 1)
    }

    @Test func loadFallsBackToBundleWhenCacheIsCorrupt() throws {
        let dir = try makeTempDirectory()
        let cache = dir.appending(path: "cache.json")
        let bundled = dir.appending(path: "bundled.json")
        try Data("not json".utf8).write(to: cache)
        try sampleCatalogJSON.write(to: bundled)

        let service = CatalogService(cacheURL: cache, bundledURL: bundled)
        #expect(service.load().wallpapers.count == 1)
    }

    @Test func loadReturnsEmptyWhenNothingIsAvailable() throws {
        let dir = try makeTempDirectory()
        let service = CatalogService(cacheURL: dir.appending(path: "missing.json"), bundledURL: nil)
        #expect(service.load() == .empty)
    }
}

@MainActor
struct WallpaperLibraryTests {
    private func makeLibrary(directory: URL, defaults: UserDefaults) -> WallpaperLibrary {
        let service = CatalogService(cacheURL: directory.appending(path: "none.json"), bundledURL: nil)
        return WallpaperLibrary(directory: directory, defaults: defaults, catalogService: service)
    }

    @Test func migratesLegacyFavoritesFromUserDefaults() throws {
        let dir = try makeTempDirectory()
        let defaults = makeDefaults()
        defaults.set(["https://example.com/a.mp4"], forKey: WallpaperLibrary.legacyFavoritesKey)

        let library = makeLibrary(directory: dir, defaults: defaults)

        #expect(library.isFavorite(URL(string: "https://example.com/a.mp4")!))
        #expect(defaults.object(forKey: WallpaperLibrary.legacyFavoritesKey) == nil)
    }

    @Test func favoritesPersistAcrossInstances() throws {
        let dir = try makeTempDirectory()
        let url = URL(string: "https://example.com/b.mp4")!

        makeLibrary(directory: dir, defaults: makeDefaults()).setFavorite(true, for: url)
        let reloaded = makeLibrary(directory: dir, defaults: makeDefaults())

        #expect(reloaded.isFavorite(url))
    }

    @Test func toggleFlipsFavoriteState() throws {
        let library = makeLibrary(directory: try makeTempDirectory(), defaults: makeDefaults())
        let url = URL(string: "https://example.com/c.mp4")!

        library.toggleFavorite(url)
        #expect(library.isFavorite(url))
        library.toggleFavorite(url)
        #expect(!library.isFavorite(url))
    }
}

@MainActor
struct AppSettingsTests {
    @Test func defaultsToShowingDockIcon() {
        #expect(AppSettings(defaults: makeDefaults()).showDockIcon)
    }

    @Test func persistsValues() {
        let defaults = makeDefaults()
        let url = URL(string: "https://example.com/last.mp4")!
        let settings = AppSettings(defaults: defaults)
        settings.showDockIcon = false
        settings.lastWallpaperURL = url

        let reloaded = AppSettings(defaults: defaults)
        #expect(!reloaded.showDockIcon)
        #expect(reloaded.lastWallpaperURL == url)
    }
}

@MainActor
struct WallpaperItemTests {
    @Test func derivesReadableNameFromFilename() {
        let item = WallpaperItem(url: URL(filePath: "/tmp/rainy_night-city.mp4"))
        #expect(item.name == "Rainy Night City")
    }

    @Test func uncachedRemoteURLResolvesToItself() {
        let url = URL(string: "https://example.com/\(UUID().uuidString).mp4")!
        #expect(WallpaperCacheManager.resolvedURL(for: url) == url)
    }
}
