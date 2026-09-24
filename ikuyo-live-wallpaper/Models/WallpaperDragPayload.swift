import CoreTransferable
import Foundation

/// A wallpaper being dragged onto a display.
///
/// Travels as prefixed plain text rather than a URL, so the window's "drop a video to import"
/// handler never mistakes a wallpaper drag for an import (which would re-import an imported
/// file), and without declaring a custom type in Info.plist.
nonisolated struct WallpaperDragPayload: Transferable, Hashable, Sendable {
    let url: URL

    static let prefix = "startorch-wallpaper:"

    var text: String { Self.prefix + url.absoluteString }

    init(url: URL) {
        self.url = url
    }

    /// Nil for any text that isn't a wallpaper drag.
    init?(text: String) {
        guard text.hasPrefix(Self.prefix),
              let url = URL(string: String(text.dropFirst(Self.prefix.count))),
              url.scheme != nil else { return nil }
        self.url = url
    }

    struct NotAWallpaper: Error {}

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.text) { (text: String) in
            guard let payload = WallpaperDragPayload(text: text) else { throw NotAWallpaper() }
            return payload
        }
    }
}
