import Foundation

/// Single source of truth for the gallery catalog and the user's favorites.
@Observable
final class WallpaperLibrary {
    private(set) var catalog: [WallpaperItem]
    private(set) var favorites: Set<String>

    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private let catalogService: CatalogService
    @ObservationIgnored private let cacheManager: WallpaperCacheManager?

    private struct Stored: Codable {
        var favorites: [String]
    }

    static let legacyFavoritesKey = "favoriteWallpapers"

    init(
        directory: URL = URL.applicationSupportDirectory.appending(path: "StarTorch", directoryHint: .isDirectory),
        defaults: UserDefaults = .standard,
        catalogService: CatalogService = CatalogService(),
        cacheManager: WallpaperCacheManager? = nil
    ) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storageURL = directory.appending(path: "library.json")
        self.catalogService = catalogService
        self.cacheManager = cacheManager
        catalog = catalogService.load().items

        if let data = try? Data(contentsOf: storageURL),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            favorites = Set(stored.favorites)
        } else {
            // One-time migration from the UserDefaults key the views used to share.
            favorites = Set(defaults.stringArray(forKey: Self.legacyFavoritesKey) ?? [])
            save()
            defaults.removeObject(forKey: Self.legacyFavoritesKey)
        }
    }

    // MARK: - Favorites

    var favoriteCatalogItems: [WallpaperItem] {
        catalog.filter { isFavorite($0.url) }.sorted { $0.name < $1.name }
    }

    func isFavorite(_ url: URL) -> Bool {
        favorites.contains(url.absoluteString)
    }

    /// Favorites are kept available offline, so this also downloads or evicts the cached file.
    func setFavorite(_ isFavorite: Bool, for url: URL) {
        guard isFavorite != self.isFavorite(url) else { return }
        if isFavorite {
            favorites.insert(url.absoluteString)
            cacheManager?.startDownload(url)
        } else {
            favorites.remove(url.absoluteString)
            cacheManager?.removeCache(for: url)
        }
        save()
    }

    func toggleFavorite(_ url: URL) {
        setFavorite(!isFavorite(url), for: url)
    }

    // MARK: - Catalog

    func refreshCatalog() async {
        guard let fresh = try? await catalogService.refresh() else { return }
        catalog = fresh.items
    }

    // MARK: - Persistence

    private func save() {
        let stored = Stored(favorites: favorites.sorted())
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
