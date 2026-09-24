import AppIntents
import Foundation

/// A wallpaper Shortcuts can refer to — a gallery item or an imported local file, both drawn
/// from `WallpaperIntentBridge`. Its `id` is `WallpaperItem.id` (the URL string), so it round
/// trips with the library and the imported store without a separate identifier scheme.
struct WallpaperEntity: AppEntity {
    let id: String
    let name: String
    let url: URL

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Wallpaper"
    static let defaultQuery = WallpaperEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(item: WallpaperItem) {
        id = item.id
        name = item.name
        url = item.url
    }
}

struct WallpaperEntityQuery: EntityStringQuery {
    func entities(for identifiers: [WallpaperEntity.ID]) async throws -> [WallpaperEntity] {
        let items = await Self.allItems()
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return identifiers.compactMap { byID[$0] }.map(WallpaperEntity.init)
    }

    func entities(matching string: String) async throws -> [WallpaperEntity] {
        await Self.allItems()
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(WallpaperEntity.init)
    }

    func suggestedEntities() async throws -> [WallpaperEntity] {
        await Self.allItems().map(WallpaperEntity.init)
    }

    @MainActor
    private static func allItems() -> [WallpaperItem] {
        let catalog = WallpaperIntentBridge.library?.catalog ?? []
        let imported = WallpaperIntentBridge.importedStore?.items ?? []
        return catalog + imported
    }
}
