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

    /// Moves a finished import into the library. Import studio data the sheet left next to
    /// `tempURL` (see `ImportStudioSidecar`) moves in with it.
    func addConvertedVideo(at tempURL: URL, name: String) {
        let ext = tempURL.pathExtension.isEmpty ? "mp4" : tempURL.pathExtension
        let destURL = importDirectory
            .appending(path: "\(UUID().uuidString)_\(name.sanitized)")
            .appendingPathExtension(ext)

        if (try? FileManager.default.moveItem(at: tempURL, to: destURL)) != nil {
            adoptSidecars(from: tempURL, for: destURL)
        }
        scanDirectory()
    }

    // MARK: Import studio

    /// Where the studio data of the imported video at `url` lives. The directory starts with
    /// a dot, so it never shows up as an import itself.
    private var studioDirectory: URL {
        importDirectory.appending(path: ImportStudioSidecar.directoryName, directoryHint: .isDirectory)
    }

    private func studioMetadataURL(for video: URL) -> URL {
        studioDirectory.appending(path: video.lastPathComponent + ".json")
    }

    private func studioPosterURL(for video: URL) -> URL {
        studioDirectory.appending(path: video.lastPathComponent + ".poster.jpg")
    }

    /// The trim/loop/preset/focal point choices saved with an imported video, if it went
    /// through the studio.
    func studioMetadata(for video: URL) -> ImportStudioMetadata? {
        guard let data = try? Data(contentsOf: studioMetadataURL(for: video)) else { return nil }
        return try? JSONDecoder().decode(ImportStudioMetadata.self, from: data)
    }

    /// The poster chosen for an imported video, if any.
    func posterURL(for video: URL) -> URL? {
        let url = studioPosterURL(for: video)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    private func adoptSidecars(from tempURL: URL, for video: URL) {
        let fm = FileManager.default
        let moves = [
            (ImportStudioSidecar.pendingMetadataURL(for: tempURL), studioMetadataURL(for: video)),
            (ImportStudioSidecar.pendingPosterURL(for: tempURL), studioPosterURL(for: video)),
        ]
        for (pending, destination) in moves where fm.fileExists(atPath: pending.path(percentEncoded: false)) {
            try? fm.createDirectory(at: studioDirectory, withIntermediateDirectories: true)
            if (try? fm.moveItem(at: pending, to: destination)) == nil {
                try? fm.removeItem(at: pending)
            }
        }
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
            .map { url in
                WallpaperItem(
                    url: url,
                    posterURL: posterURL(for: url),
                    focalPoint: studioMetadata(for: url)?.focalPoint
                )
            }
    }
}

/// What the import studio saved about an imported video. Everything is optional so older
/// imports (and future fields) decode fine.
nonisolated struct ImportStudioMetadata: Codable, Equatable, Sendable {
    var focalPoint: FocalPoint?
    /// Source time, in seconds, the poster was taken from.
    var posterTime: Double?
    var preset: ExportQualityPreset?
    /// The source range kept, in seconds.
    var trimStart: Double?
    var trimEnd: Double?
    /// The loop crossfade actually rendered, in seconds.
    var crossfade: Double?

    var isEmpty: Bool { self == ImportStudioMetadata() }
}

/// The hand-off between the import sheet and `ImportedWallpaperStore`: the sheet writes the
/// studio data next to its temporary output, and `addConvertedVideo(at:name:)` moves it in with
/// the video. That keeps the sheet's `onComplete(url, name)` contract unchanged.
///
/// Trashing an import leaves its studio files in place, so Undo (or Finder's Put Back, which
/// restores the same file name) brings the poster and focal point back with it.
nonisolated enum ImportStudioSidecar {
    static let directoryName = ".studio"

    static func pendingMetadataURL(for video: URL) -> URL {
        video.appendingPathExtension("studio.json")
    }

    static func pendingPosterURL(for video: URL) -> URL {
        video.appendingPathExtension("poster.jpg")
    }

    static func writePendingMetadata(_ metadata: ImportStudioMetadata, for video: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: pendingMetadataURL(for: video), options: .atomic)
    }
}

private extension String {
    var sanitized: String {
        components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }
}
