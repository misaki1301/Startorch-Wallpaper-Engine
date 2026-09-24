import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

@MainActor
struct ImportedWallpaperStoreTests {
    private let importDirectory: URL
    private let trashDirectory: URL
    private let store: ImportedWallpaperStore
    private let undoManager: UndoManager

    init() throws {
        importDirectory = try makeTempDirectory()
        trashDirectory = try makeTempDirectory()
        let trashDirectory = trashDirectory
        // Stands in for the Finder Trash so tests never touch the real one.
        store = ImportedWallpaperStore(directory: importDirectory) { url in
            let destination = trashDirectory.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        undoManager = UndoManager()
        undoManager.groupsByEvent = false
    }

    private func importVideo(named name: String) throws -> URL {
        let temp = try makeTempDirectory().appending(path: "\(name).mp4")
        try Data("video".utf8).write(to: temp)
        store.addConvertedVideo(at: temp, name: name)
        return try #require(store.items.first { $0.url.lastPathComponent.hasSuffix("_\(name).mp4") }?.url)
    }

    private func trash(_ url: URL) throws {
        undoManager.beginUndoGrouping()
        try store.moveToTrash(url, undoManager: undoManager)
        undoManager.endUndoGrouping()
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func movesTheFileToTheTrashInsteadOfDeletingIt() throws {
        let video = try importVideo(named: "Rain")
        try trash(video)

        #expect(store.items.isEmpty)
        #expect(!exists(video))
        #expect(exists(trashDirectory.appending(path: video.lastPathComponent)))
    }

    @Test func undoRestoresTheFile() throws {
        let video = try importVideo(named: "Rain")
        try trash(video)

        #expect(undoManager.canUndo)
        #expect(undoManager.undoActionName == "Move to Trash")
        undoManager.undo()

        #expect(exists(video))
        #expect(store.items.map(\.url) == [video])
    }

    @Test func redoTrashesItAgain() throws {
        let video = try importVideo(named: "Rain")
        try trash(video)
        undoManager.undo()

        #expect(undoManager.canRedo)
        undoManager.redo()

        #expect(!exists(video))
        #expect(store.items.isEmpty)
        #expect(undoManager.canUndo)
    }

    @Test func onlyTheTrashedItemIsRemoved() throws {
        let keep = try importVideo(named: "Keep")
        let remove = try importVideo(named: "Remove")
        try trash(remove)

        #expect(store.items.map(\.url) == [keep])
    }
}
