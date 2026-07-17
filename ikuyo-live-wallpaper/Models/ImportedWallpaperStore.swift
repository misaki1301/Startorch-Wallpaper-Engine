import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ImportedWallpaperStore {
    private(set) var items: [WallpaperItem] = []

    private var importDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appending(path: "ImportedWallpapers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        scanDirectory()
    }

    func addConvertedVideo(at tempURL: URL, name: String) {
        let destURL = importDirectory
            .appending(path: "\(UUID().uuidString)_\(name.sanitized)")
            .appendingPathExtension("mp4")

        try? FileManager.default.moveItem(at: tempURL, to: destURL)
        scanDirectory()
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        items.removeAll { $0.url == url }
    }

    private func scanDirectory() {
        let fm = FileManager.default
        let dir = importDirectory
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }

        items = contents
            .filter { $0.pathExtension.lowercased() == "mp4" }
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
