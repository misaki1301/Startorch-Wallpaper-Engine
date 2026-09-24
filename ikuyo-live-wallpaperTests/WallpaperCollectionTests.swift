import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

@MainActor
private func makeLibrary(directory: URL, defaults: UserDefaults = makeDefaults()) -> WallpaperLibrary {
    let service = CatalogService(cacheURL: directory.appending(path: "none.json"), bundledURL: nil)
    return WallpaperLibrary(directory: directory, defaults: defaults, catalogService: service)
}

@MainActor
struct WallpaperCollectionLibraryTests {
    let a = URL(string: "https://example.com/a.mp4")!
    let b = URL(string: "https://example.com/b.mp4")!

    @Test func createAddRemoveAndDeleteRoundTrip() throws {
        let library = makeLibrary(directory: try makeTempDirectory())

        let collection = library.createCollection(name: "Cozy")
        #expect(library.collections.map(\.id) == [collection.id])

        library.addItem(a, to: collection.id)
        library.addItem(b, to: collection.id)
        library.addItem(a, to: collection.id) // duplicate, ignored
        #expect(library.collection(collection.id)?.itemURLs == [a, b])

        library.removeItem(a, from: collection.id)
        #expect(library.collection(collection.id)?.itemURLs == [b])

        library.renameCollection(collection.id, to: "Renamed")
        #expect(library.collection(collection.id)?.name == "Renamed")

        library.deleteCollection(collection.id)
        #expect(library.collections.isEmpty)
    }

    @Test func deletingIsUndoable() throws {
        let library = makeLibrary(directory: try makeTempDirectory())
        let undoManager = UndoManager()
        let collection = library.createCollection(name: "Cozy")
        library.addItem(a, to: collection.id)

        library.deleteCollection(collection.id, undoManager: undoManager)
        #expect(library.collections.isEmpty)

        undoManager.undo()
        #expect(library.collection(collection.id)?.name == "Cozy")
        #expect(library.collection(collection.id)?.itemURLs == [a])

        undoManager.redo()
        #expect(library.collections.isEmpty)
    }

    @Test func collectionsPersistAcrossInstances() throws {
        let dir = try makeTempDirectory()
        let defaults = makeDefaults()
        let id: WallpaperCollection.ID
        do {
            let library = makeLibrary(directory: dir, defaults: defaults)
            let collection = library.createCollection(name: "Cozy")
            library.addItem(a, to: collection.id)
            id = collection.id
        }
        let reloaded = makeLibrary(directory: dir, defaults: defaults)
        #expect(reloaded.collection(id)?.name == "Cozy")
        #expect(reloaded.collection(id)?.itemURLs == [a])
    }

    @Test("An older library.json with no \"collections\" key still loads, with no collections")
    func migrationSafeAgainstAnOlderLibraryFile() throws {
        let dir = try makeTempDirectory()
        // What Phase 3's WallpaperLibrary wrote: favorites only, no "collections" key at all.
        let legacyJSON = Data(#"{"favorites":["https://example.com/a.mp4"]}"#.utf8)
        try legacyJSON.write(to: dir.appending(path: "library.json"))

        let library = makeLibrary(directory: dir)
        #expect(library.isFavorite(a))
        #expect(library.collections.isEmpty)

        // And it can create collections from there on, saving both back out together.
        library.createCollection(name: "New")
        let reloaded = makeLibrary(directory: dir)
        #expect(reloaded.isFavorite(a))
        #expect(reloaded.collections.map(\.name) == ["New"])
    }

    @Test func setShuffleStoresAndClearsSettings() throws {
        let library = makeLibrary(directory: try makeTempDirectory())
        let collection = library.createCollection(name: "Cozy")

        library.setShuffle(ShuffleSettings(interval: .minutes(30), isEnabled: true), for: collection.id)
        #expect(library.collection(collection.id)?.shuffle?.interval == .minutes(30))

        library.setShuffle(nil, for: collection.id)
        #expect(library.collection(collection.id)?.shuffle == nil)
    }

    @Test func resolvedItemsCombinesCatalogAndImportedAndSkipsMissingURLs() throws {
        let dir = try makeTempDirectory()
        let catalogJSON = Data("""
        {"version":1,"wallpapers":[{"id":"rain","title":"Rain","creator":"A","license":"CC0","url":"https://example.com/a.mp4"}]}
        """.utf8)
        try catalogJSON.write(to: dir.appending(path: "bundled.json"))
        let service = CatalogService(cacheURL: dir.appending(path: "missing.json"), bundledURL: dir.appending(path: "bundled.json"))
        let library = WallpaperLibrary(directory: dir, defaults: makeDefaults(), catalogService: service)

        let imported = WallpaperItem(url: URL(filePath: "/tmp/imported/local.mp4"), name: "Local")
        let missing = URL(string: "https://example.com/gone.mp4")!
        let collection = library.createCollection(name: "Mixed")
        library.addItem(a, to: collection.id) // matches catalog
        library.addItem(imported.url, to: collection.id)
        library.addItem(missing, to: collection.id)

        let resolved = library.resolvedItems(for: library.collection(collection.id)!, importedItems: [imported])
        #expect(resolved.map(\.url) == [a, imported.url])
    }
}

@MainActor
struct CollectionShufflerTests {
    let a = URL(string: "https://example.com/a.mp4")!
    let b = URL(string: "https://example.com/b.mp4")!
    let c = URL(string: "https://example.com/c.mp4")!

    @Test func neverRepeatsTheImmediatelyPreviousPickWhenThereAreOtherChoices() {
        var queue = [b, a, b, a] // "random" answers the shuffler will be fed, in order
        let shuffler = CollectionShuffler(randomElement: { candidates in
            let next = queue.removeFirst()
            #expect(candidates.contains(next))
            return next
        })
        let collection = WallpaperCollection(name: "Test", itemURLs: [a, b])

        var previous: URL?
        for _ in 0..<4 {
            let pick = shuffler.pick(from: collection)
            if let previous {
                #expect(pick != previous)
            }
            previous = pick
        }
    }

    @Test func excludesOnlyThePreviousPickFromCandidates() {
        var capturedCandidates: [URL] = []
        let shuffler = CollectionShuffler(randomElement: { candidates in
            capturedCandidates = candidates
            return candidates.first
        })
        let collection = WallpaperCollection(name: "Test", itemURLs: [a, b, c])

        let first = shuffler.pick(from: collection)
        _ = shuffler.pick(from: collection)
        #expect(!capturedCandidates.contains(first!))
        #expect(capturedCandidates.count == 2)
    }

    @Test func singleItemCollectionAlwaysReturnsIt() {
        let shuffler = CollectionShuffler(randomElement: { $0.first })
        let collection = WallpaperCollection(name: "Solo", itemURLs: [a])
        #expect(shuffler.pick(from: collection) == a)
        #expect(shuffler.pick(from: collection) == a)
    }

    @Test func emptyCollectionReturnsNil() {
        let shuffler = CollectionShuffler(randomElement: { $0.first })
        let collection = WallpaperCollection(name: "Empty", itemURLs: [])
        #expect(shuffler.pick(from: collection) == nil)
    }
}
