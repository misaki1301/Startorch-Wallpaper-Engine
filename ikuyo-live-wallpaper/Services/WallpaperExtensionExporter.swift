import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum WallpaperExtensionExportError: LocalizedError, Equatable {
    /// The wallpaper is a remote catalog video that hasn't been downloaded.
    case notDownloaded
    /// This build can't reach the shared App Group container (e.g. it isn't signed).
    case containerUnavailable

    var errorDescription: String? {
        switch self {
        case .notDownloaded:
            String(localized: "Download this wallpaper first, then export it.")
        case .containerUnavailable:
            String(localized: "This copy of StarTorch can't reach the shared wallpaper folder. Use a build signed by the StarTorch team.")
        }
    }
}

/// Hands the current wallpaper to the StarTorch system wallpaper extension (Route A) by writing
/// it into the App Group container both are entitled to (see `SystemWallpaperStore`):
///
/// 1. the clip is copied under a content-derived name (skipped if already there),
/// 2. its first frame is saved as the poster,
/// 3. `manifest.json` is replaced atomically — the extension, which watches the folder, only
///    ever sees a manifest whose files already exist,
/// 4. clips and posters no longer named by the manifest are removed.
///
/// The container is resolved lazily, so creating an exporter (e.g. in a test host) never touches
/// it; tests inject their own directory.
@Observable
final class WallpaperExtensionExporter {
    enum Status: Equatable {
        /// No container: unsigned build or missing entitlement.
        case unavailable
        case notExported
        case exported(SystemWallpaperManifest)
    }

    typealias PosterWriter = @Sendable (_ video: URL, _ destination: URL) async -> Bool

    private(set) var status: Status = .notExported
    private(set) var isExporting = false
    private(set) var lastError: String?

    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let writePoster: PosterWriter
    @ObservationIgnored private var resolvedStore: SystemWallpaperStore??

    /// `directory` replaces the App Group container (tests).
    init(directory: URL? = nil, writePoster: @escaping PosterWriter = { await WallpaperExtensionExporter.writeFirstFrame(of: $0, to: $1) }) {
        self.directory = directory
        self.writePoster = writePoster
    }

    private var store: SystemWallpaperStore? {
        if let resolvedStore { return resolvedStore }
        let store = directory.map(SystemWallpaperStore.init(root:)) ?? SystemWallpaperStore.shared()
        resolvedStore = .some(store)
        return store
    }

    /// Reads what was exported last.
    func refreshStatus() {
        guard let store else {
            status = .unavailable
            return
        }
        status = store.readManifest().map(Status.exported) ?? .notExported
    }

    /// Exports `sourceURL` (played from `playbackURL`, its local copy) with its readability
    /// settings. Returns whether it worked; `lastError` says why not.
    @discardableResult
    func export(sourceURL: URL, playbackURL: URL, title: String, readability: ReadabilitySettings) async -> Bool {
        guard !isExporting else { return false }
        guard let store else {
            status = .unavailable
            lastError = WallpaperExtensionExportError.containerUnavailable.localizedDescription
            return false
        }
        isExporting = true
        defer { isExporting = false }
        do {
            let manifest = try await Self.performExport(
                sourceURL: sourceURL,
                playbackURL: playbackURL,
                title: title,
                readability: readability,
                store: store,
                writePoster: writePoster
            )
            status = .exported(manifest)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Export steps (off the main actor)

    @concurrent
    nonisolated static func performExport(
        sourceURL: URL,
        playbackURL: URL,
        title: String,
        readability: ReadabilitySettings,
        store: SystemWallpaperStore,
        writePoster: PosterWriter,
        now: Date = Date()
    ) async throws -> SystemWallpaperManifest {
        let fileManager = FileManager.default
        let playbackPath = playbackURL.path(percentEncoded: false)
        guard playbackURL.isFileURL, fileManager.fileExists(atPath: playbackPath) else {
            throw WallpaperExtensionExportError.notDownloaded
        }
        try fileManager.createDirectory(at: store.clipsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: store.postersDirectory, withIntermediateDirectories: true)

        // 1. The clip, named after its source and file identity, so re-exporting is a no-op.
        let attributes = try fileManager.attributesOfItem(atPath: playbackPath)
        let base = clipBaseName(
            source: sourceURL,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            modified: attributes[.modificationDate] as? Date
        )
        let ext = clipExtension(for: playbackURL)
        let clipName = "\(base).\(ext)"
        let clipURL = store.clipsDirectory.appending(path: clipName)
        if !fileManager.fileExists(atPath: clipURL.path(percentEncoded: false)) {
            let partial = store.clipsDirectory.appending(path: ".\(UUID().uuidString).partial")
            try fileManager.copyItem(at: playbackURL, to: partial)
            try fileManager.moveItem(at: partial, to: clipURL)
        }

        // 2. The poster (non-fatal: the extension shows black until the video's first frame).
        let posterName = "\(base).jpg"
        let posterURL = store.postersDirectory.appending(path: posterName)
        var hasPoster = fileManager.fileExists(atPath: posterURL.path(percentEncoded: false))
        if !hasPoster {
            let partial = store.postersDirectory.appending(path: ".\(UUID().uuidString).partial")
            if await writePoster(clipURL, partial) {
                hasPoster = (try? fileManager.moveItem(at: partial, to: posterURL)) != nil
            }
            try? fileManager.removeItem(at: partial)
        }

        // 3. The manifest, atomically, last.
        let manifest = SystemWallpaperManifest(
            title: title,
            clipFileName: clipName,
            posterFileName: hasPoster ? posterName : nil,
            sourceURL: sourceURL.absoluteString,
            dim: readability.dim,
            vignette: readability.vignette,
            speed: readability.speed,
            exportedAt: now
        )
        try store.writeManifest(manifest)

        // 4. Everything the manifest no longer names.
        removeEverything(in: store.clipsDirectory, except: clipName)
        removeEverything(in: store.postersDirectory, except: hasPoster ? posterName : nil)
        return manifest
    }

    nonisolated static func clipBaseName(source: URL, size: Int64, modified: Date?) -> String {
        let identity = "\(source.absoluteString)|\(size)|\(modified?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func clipExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["mov", "mp4", "m4v"].contains(ext) ? ext : "mp4"
    }

    private nonisolated static func removeEverything(in directory: URL, except keep: String?) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return }
        for name in names where name != keep {
            try? fileManager.removeItem(at: directory.appending(path: name))
        }
    }

    /// Writes the clip's first frame (at most 1920 px on its long side) as a JPEG.
    @concurrent
    nonisolated static func writeFirstFrame(of video: URL, to destination: URL) async -> Bool {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        guard let image = try? await generator.image(at: .zero).image,
              let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(output)
    }
}
