import Foundation

/// Picks a wallpaper from a collection, avoiding the item it picked last time (when there's more
/// than one to choose from). One instance can track several collections at once, keyed by id.
@MainActor
final class CollectionShuffler {
    private var lastPick: [WallpaperCollection.ID: URL] = [:]
    private let randomElement: ([URL]) -> URL?

    /// `randomElement` is injectable so tests can make the "random" pick deterministic.
    init(randomElement: @escaping ([URL]) -> URL? = { $0.randomElement() }) {
        self.randomElement = randomElement
    }

    /// The next URL for `collection`, or `nil` if it's empty. Never repeats the immediately
    /// previous pick for that collection unless the collection has only one item.
    func pick(from collection: WallpaperCollection) -> URL? {
        let urls = collection.itemURLs
        guard !urls.isEmpty else { return nil }
        let previous = lastPick[collection.id]
        let candidates = urls.count > 1 ? urls.filter { $0 != previous } : urls
        let choice = randomElement(candidates)
        lastPick[collection.id] = choice
        return choice
    }

    /// Clears the remembered last pick for a collection, e.g. after it's deleted.
    func forget(_ id: WallpaperCollection.ID) {
        lastPick.removeValue(forKey: id)
    }
}
