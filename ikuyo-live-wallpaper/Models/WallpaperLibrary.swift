import Foundation

/// Single source of truth for the gallery catalog and the user's favorites.
@Observable
final class WallpaperLibrary {
    private(set) var catalog: [WallpaperItem]
    private(set) var favorites: Set<String>
    /// User-created collections. Order is creation order (append/remove), not sorted, so the
    /// sidebar shows collections in the order the user made them.
    private(set) var collections: [WallpaperCollection]

    @ObservationIgnored private let storageURL: URL
    @ObservationIgnored private let catalogService: CatalogService
    @ObservationIgnored private let cacheManager: WallpaperCacheManager?

    private struct Stored: Codable {
        var favorites: [String]
        // Absent from a library.json written before Phase 5D; decodes to `nil` and defaults to
        // no collections, so an older file still loads.
        var collections: [WallpaperCollection]?
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
            collections = stored.collections ?? []
        } else {
            // One-time migration from the UserDefaults key the views used to share.
            favorites = Set(defaults.stringArray(forKey: Self.legacyFavoritesKey) ?? [])
            collections = []
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

    // MARK: - Collections

    @discardableResult
    func createCollection(name: String) -> WallpaperCollection {
        let collection = WallpaperCollection(name: name)
        collections.append(collection)
        save()
        return collection
    }

    func collection(_ id: WallpaperCollection.ID) -> WallpaperCollection? {
        collections.first { $0.id == id }
    }

    func renameCollection(_ id: WallpaperCollection.ID, to name: String) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].name = name
        save()
    }

    /// Deletes a collection. Cheap to undo, since the whole value is small — `undoManager`
    /// registers putting it straight back (at the end, not its old index; collections aren't
    /// reordered today).
    func deleteCollection(_ id: WallpaperCollection.ID, undoManager: UndoManager? = nil) {
        guard let removed = collection(id) else { return }
        collections.removeAll { $0.id == id }
        save()
        undoManager?.registerUndo(withTarget: self) { library in
            library.restoreCollection(removed, undoManager: undoManager)
        }
        undoManager?.setActionName("Delete Collection")
    }

    private func restoreCollection(_ collection: WallpaperCollection, undoManager: UndoManager?) {
        collections.append(collection)
        save()
        undoManager?.registerUndo(withTarget: self) { library in
            library.deleteCollection(collection.id, undoManager: undoManager)
        }
        undoManager?.setActionName("Delete Collection")
    }

    func addItem(_ url: URL, to id: WallpaperCollection.ID) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        guard !collections[index].itemURLs.contains(url) else { return }
        collections[index].itemURLs.append(url)
        save()
    }

    func removeItem(_ url: URL, from id: WallpaperCollection.ID) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].itemURLs.removeAll { $0 == url }
        save()
    }

    func setShuffle(_ shuffle: ShuffleSettings?, for id: WallpaperCollection.ID) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].shuffle = shuffle
        save()
    }

    /// A collection's URLs resolved to display items, drawn from the catalog and from
    /// `importedItems` (the caller's `ImportedWallpaperStore.items` — the library doesn't own
    /// imported files). A URL that matches neither is skipped, e.g. a since-trashed import.
    func resolvedItems(for collection: WallpaperCollection, importedItems: [WallpaperItem]) -> [WallpaperItem] {
        let byURL = Dictionary(catalog.map { ($0.url, $0) } + importedItems.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        return collection.itemURLs.compactMap { byURL[$0] }
    }

    // MARK: - Persistence

    private func save() {
        let stored = Stored(favorites: favorites.sorted(), collections: collections)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
