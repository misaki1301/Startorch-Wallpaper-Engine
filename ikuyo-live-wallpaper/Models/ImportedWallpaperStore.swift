import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ImportedWallpaperStore {
    private(set) var items: [WallpaperItem] = []

    @ObservationIgnored private let importDirectory: URL
    /// Moves a file to the Trash and returns where it ended up. Injectable so tests don't
    /// fill the real Trash.
    @ObservationIgnored private let trash: (URL) throws -> URL?

    static let defaultDirectory = URL.documentsDirectory.appending(path: "ImportedWallpapers", directoryHint: .isDirectory)

    init(
        directory: URL = ImportedWallpaperStore.defaultDirectory,
        trash: @escaping (URL) throws -> URL? = ImportedWallpaperStore.moveToSystemTrash
    ) {
        importDirectory = directory
        self.trash = trash
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scanDirectory()
    }

    /// Accepted extensions for an imported file. HEVC conversions are always `.mp4`; "Keep
    /// Original" can hand back the source's own container.
    static let importedExtensions: Set<String> = ["mp4", "mov", "m4v"]

    func addConvertedVideo(at tempURL: URL, name: String) {
        let ext = tempURL.pathExtension.isEmpty ? "mp4" : tempURL.pathExtension
        let destURL = importDirectory
            .appending(path: "\(UUID().uuidString)_\(name.sanitized)")
            .appendingPathExtension(ext)

        try? FileManager.default.moveItem(at: tempURL, to: destURL)
        scanDirectory()
    }

    /// Moves an imported video to the Trash. Undo puts it back; redo trashes it again.
    func moveToTrash(_ url: URL, undoManager: UndoManager?) throws {
        let trashedURL = try trash(url)
        items.removeAll { $0.url == url }
        guard let trashedURL else { return }

        undoManager?.registerUndo(withTarget: self) { store in
            try? store.restore(trashedURL, to: url, undoManager: undoManager)
        }
        undoManager?.setActionName("Move to Trash")
    }

    private func restore(_ trashedURL: URL, to url: URL, undoManager: UndoManager?) throws {
        try FileManager.default.moveItem(at: trashedURL, to: url)
        scanDirectory()

        undoManager?.registerUndo(withTarget: self) { store in
            try? store.moveToTrash(url, undoManager: undoManager)
        }
        undoManager?.setActionName("Move to Trash")
    }

    nonisolated static func moveToSystemTrash(_ url: URL) throws -> URL? {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    private func scanDirectory() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: importDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        items = contents
            .filter { Self.importedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { WallpaperItem(url: $0) }
    }
}

private extension String {
    var sanitized: String {
        components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }
}
