import Foundation

// Compiled into BOTH the app and the StarTorchWallpaperExtension target: the app writes the
// system wallpaper hand-off with it, the extension reads it. Public API only.

/// What the app hands to the wallpaper extension: one clip, an optional poster frame and the
/// readability settings to draw on top. Written atomically as `manifest.json` *after* the files
/// it names are in place, so the extension never sees a manifest pointing at a half-copied clip.
nonisolated struct SystemWallpaperManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    /// A new value for every export, so the extension can tell a re-export from a no-op.
    var revision: String
    /// Shown in the app's Settings; the extension doesn't need it.
    var title: String
    /// A bare file name inside `clips/`.
    var clipFileName: String
    /// A bare file name inside `posters/`; nil when the first frame couldn't be extracted.
    var posterFileName: String?
    /// The wallpaper the clip was exported from (a catalog URL or a local file URL).
    var sourceURL: String
    var dim: Double
    var vignette: Bool
    /// Playback rate, 0.5–1.
    var speed: Double
    var exportedAt: Date

    init(
        revision: String = UUID().uuidString,
        title: String,
        clipFileName: String,
        posterFileName: String?,
        sourceURL: String,
        dim: Double,
        vignette: Bool,
        speed: Double,
        exportedAt: Date = Date()
    ) {
        self.version = Self.currentVersion
        self.revision = revision
        self.title = title
        self.clipFileName = clipFileName
        self.posterFileName = posterFileName
        self.sourceURL = sourceURL
        self.dim = min(max(dim, 0), 0.6)
        self.vignette = vignette
        self.speed = min(max(speed, 0.5), 1)
        // Whole seconds, the precision the ISO 8601 file format keeps, so a manifest read back
        // equals the one written.
        self.exportedAt = Date(timeIntervalSince1970: exportedAt.timeIntervalSince1970.rounded(.down))
    }

    /// A manifest the extension can safely act on: a version it understands and file names that
    /// can't escape their folder.
    var isUsable: Bool {
        version == Self.currentVersion
            && SystemWallpaperStore.isPlainFileName(clipFileName)
            && (posterFileName.map(SystemWallpaperStore.isPlainFileName) ?? true)
    }
}

/// The on-disk layout of the hand-off, rooted in the shared App Group container:
///
///     <root>/manifest.json
///     <root>/clips/<name>.<ext>
///     <root>/posters/<name>.jpg
///
/// `root` is injectable so tests (and previews) never touch the real container.
nonisolated struct SystemWallpaperStore: Sendable {
    /// Team-prefixed, so macOS 15+ grants the app and its extension access without a prompt when
    /// both are signed by team B97JTSGWZ2. Must match both targets' entitlements.
    static let appGroupIdentifier = "B97JTSGWZ2.com.shibuyaxpress.ikuyo-live-wallpaper"
    static let folderName = "SystemWallpaper"

    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// The store inside the shared App Group container, or nil when this process isn't entitled
    /// to the group (e.g. an unsigned build).
    static func shared(fileManager: FileManager = .default) -> SystemWallpaperStore? {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        return SystemWallpaperStore(
            root: container
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
                .appending(path: folderName, directoryHint: .isDirectory)
        )
    }

    var manifestURL: URL { root.appending(path: "manifest.json") }
    var clipsDirectory: URL { root.appending(path: "clips", directoryHint: .isDirectory) }
    var postersDirectory: URL { root.appending(path: "posters", directoryHint: .isDirectory) }

    func clipURL(for manifest: SystemWallpaperManifest) -> URL {
        clipsDirectory.appending(path: manifest.clipFileName)
    }

    func posterURL(for manifest: SystemWallpaperManifest) -> URL? {
        manifest.posterFileName.map { postersDirectory.appending(path: $0) }
    }

    /// The current manifest, or nil when nothing was exported yet or it can't be used.
    func readManifest() -> SystemWallpaperManifest? {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? Self.decoder.decode(SystemWallpaperManifest.self, from: data),
              manifest.isUsable else { return nil }
        return manifest
    }

    /// Replaces the manifest in one step (write to a temporary file, then rename over it).
    func writeManifest(_ manifest: SystemWallpaperManifest) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    /// A single path component that can't point outside its folder.
    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.hasPrefix(".")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
