import CoreGraphics
import Foundation
import ImageIO
import os

private let contentLog = Logger(subsystem: "com.shibuyaxpress.ikuyo-live-wallpaper.WallpaperExtension", category: "content")

/// What the app exported, read from the shared App Group container (see `SystemWallpaperStore`),
/// and kept current: the folder is watched with a kqueue vnode source (no timers), and the
/// manifest is re-read when something in it changes. `onChange` fires only when the export's
/// revision actually changed.
@MainActor
final class WallpaperContentSource {
    struct Content: Equatable {
        let manifest: SystemWallpaperManifest
        let clipURL: URL
        let posterURL: URL?
    }

    private(set) var content: Content?
    private(set) var poster: CGImage?
    var onChange: (() -> Void)?

    private let store: SystemWallpaperStore?
    private var watcher: (any DispatchSourceFileSystemObject)?

    init(store: SystemWallpaperStore? = SystemWallpaperStore.shared()) {
        self.store = store
        if store == nil {
            contentLog.error("No App Group container; is the extension signed with the application-groups entitlement?")
        }
        reload()
        startWatching()
    }

    /// Re-reads the manifest. Returns whether the content changed.
    @discardableResult
    func reload() -> Bool {
        guard let store else { return false }
        var next: Content?
        if let manifest = store.readManifest() {
            let clipURL = store.clipURL(for: manifest)
            if FileManager.default.fileExists(atPath: clipURL.path(percentEncoded: false)) {
                next = Content(manifest: manifest, clipURL: clipURL, posterURL: store.posterURL(for: manifest))
            } else {
                contentLog.error("Manifest names a missing clip: \(manifest.clipFileName, privacy: .public)")
            }
        }
        guard next != content else { return false }
        content = next
        poster = next?.posterURL.flatMap(Self.loadImage)
        contentLog.info("Content is now \(next?.manifest.title ?? "nothing", privacy: .public) (revision \(next?.manifest.revision ?? "-", privacy: .public))")
        return true
    }

    private func startWatching() {
        guard let store else { return }
        do {
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        } catch {
            contentLog.error("Cannot create \(store.root.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        let descriptor = open(store.root.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return }
        // The atomic manifest write renames a temporary file into the folder: a `.write` on it.
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.reload() else { return }
                self.onChange?()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
