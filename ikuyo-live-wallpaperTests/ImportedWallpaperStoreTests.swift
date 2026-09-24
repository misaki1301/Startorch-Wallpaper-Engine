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

    // MARK: Import studio sidecars

    private func importVideoWithStudioData(named name: String, metadata: ImportStudioMetadata) throws -> URL {
        let temp = try makeTempDirectory().appending(path: "\(name).mp4")
        try Data("video".utf8).write(to: temp)
        try ImportStudioSidecar.writePendingMetadata(metadata, for: temp)
        try Data("jpeg".utf8).write(to: ImportStudioSidecar.pendingPosterURL(for: temp))
        store.addConvertedVideo(at: temp, name: name)

        #expect(!exists(ImportStudioSidecar.pendingMetadataURL(for: temp)))
        #expect(!exists(ImportStudioSidecar.pendingPosterURL(for: temp)))
        return try #require(store.items.first { $0.url.lastPathComponent.hasSuffix("_\(name).mp4") }?.url)
    }

    @Test func studioDataMovesInWithTheVideo() throws {
        let metadata = ImportStudioMetadata(
            focalPoint: FocalPoint(x: 0.2, y: 0.7),
            posterTime: 1.5,
            preset: .batterySaver,
            trimStart: 1,
            trimEnd: 4,
            crossfade: 0.5
        )
        let video = try importVideoWithStudioData(named: "Waves", metadata: metadata)
        let item = try #require(store.items.first)

        #expect(store.items.count == 1)
        #expect(item.focalPoint == FocalPoint(x: 0.2, y: 0.7))
        let poster = try #require(item.posterURL)
        #expect(exists(poster))
        #expect(store.posterURL(for: video) == poster)
        #expect(store.studioMetadata(for: video) == metadata)
    }

    @Test func importsWithoutStudioDataHaveNoPosterOrFocalPoint() throws {
        let video = try importVideo(named: "Plain")
        let item = try #require(store.items.first)

        #expect(item.posterURL == nil)
        #expect(item.focalPoint == nil)
        #expect(store.studioMetadata(for: video) == nil)
    }

    @Test func undoingATrashBringsTheStudioDataBack() throws {
        let video = try importVideoWithStudioData(
            named: "Rain",
            metadata: ImportStudioMetadata(focalPoint: FocalPoint(x: 1, y: 0))
        )
        try trash(video)
        undoManager.undo()

        let item = try #require(store.items.first)
        #expect(item.focalPoint == FocalPoint(x: 1, y: 0))
        #expect(item.posterURL != nil)
    }

    @Test func existingStoreLoadsStudioDataOnLaunch() throws {
        _ = try importVideoWithStudioData(named: "Snow", metadata: ImportStudioMetadata(focalPoint: .center))
        let relaunched = ImportedWallpaperStore(directory: importDirectory) { _ in nil }

        #expect(relaunched.items.count == 1)
        #expect(relaunched.items.first?.focalPoint == .center)
        #expect(relaunched.items.first?.posterURL != nil)
    }
}
