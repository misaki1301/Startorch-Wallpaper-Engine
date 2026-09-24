import AppIntents
import Foundation

/// A collection Shortcuts can refer to, drawn from `WallpaperIntentBridge.library`. Its `id` is
/// the collection's own `UUID` string.
struct WallpaperCollectionEntity: AppEntity {
    let id: String
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Wallpaper Collection"
    static let defaultQuery = WallpaperCollectionEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(collection: WallpaperCollection) {
        id = collection.id.uuidString
        name = collection.name
    }
}

struct WallpaperCollectionEntityQuery: EntityStringQuery {
    func entities(for identifiers: [WallpaperCollectionEntity.ID]) async throws -> [WallpaperCollectionEntity] {
        let collections = await Self.allCollections()
        let byID = Dictionary(uniqueKeysWithValues: collections.map { ($0.id.uuidString, $0) })
        return identifiers.compactMap { byID[$0] }.map(WallpaperCollectionEntity.init)
    }

    func entities(matching string: String) async throws -> [WallpaperCollectionEntity] {
        await Self.allCollections()
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(WallpaperCollectionEntity.init)
    }

    func suggestedEntities() async throws -> [WallpaperCollectionEntity] {
        await Self.allCollections().map(WallpaperCollectionEntity.init)
    }

    @MainActor
    private static func allCollections() -> [WallpaperCollection] {
        WallpaperIntentBridge.library?.collections ?? []
    }
}
