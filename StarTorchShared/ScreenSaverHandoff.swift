import Foundation

// Compiled into both the app and StarTorch.saver, so the two sides agree on where the clip lives,
// what the manifest looks like and what the saver shows when something is missing. Everything
// here is pure Foundation and `nonisolated`, so it builds under either target's isolation
// settings and is unit-tested through the app's test target.

/// Where the app leaves the screen saver's clip, and how the saver finds it.
///
/// Since macOS 14, third-party `.saver` bundles run inside Apple's sandboxed `legacyScreenSaver`
/// host, whose container is the saver's home directory. The app writes into that container's
/// `Application Support/StarTorch` folder (allowed by a home-relative temporary-exception
/// entitlement on the app); the saver reads its own container, which its sandbox always allows.
nonisolated enum ScreenSaverHandoff {
    static let hostBundleIdentifier = "com.apple.ScreenSaver.Engine.legacyScreenSaver"
    static let folderName = "StarTorch"

    /// The handoff folder relative to the user's real home directory. The app's
    /// `com.apple.security.temporary-exception.files.home-relative-path.read-write` entitlement
    /// names exactly this path (with a leading and trailing slash).
    static let homeRelativePath =
        "Library/Containers/\(hostBundleIdentifier)/Data/Library/Application Support/\(folderName)"

    /// The handoff folder for a user whose real home directory is `home`.
    static func directory(inHome home: URL) -> URL {
        home.appending(path: homeRelativePath, directoryHint: .isDirectory)
    }

    /// The user's real home directory. Inside a sandbox `NSHomeDirectory()` is the container, and
    /// home-relative entitlements are relative to this one instead.
    static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(filePath: String(cString: dir), directoryHint: .isDirectory)
        }
        return URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
    }

    /// Where the saver looks, in order: its own `Application Support/StarTorch` (the host's
    /// container when sandboxed, which is the normal case), then the container path spelled out
    /// from the real home, in case the saver ever runs outside that sandbox.
    static func saverCandidateDirectories(applicationSupport: URL, realHome: URL) -> [URL] {
        let candidates = [
            applicationSupport.appending(path: folderName, directoryHint: .isDirectory),
            directory(inHome: realHome),
        ]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path(percentEncoded: false)).inserted }
    }

    /// File name prefixes the exporter owns inside the handoff folder; anything else is left alone.
    static let clipPrefix = "clip-"
    static let posterPrefix = "poster-"
    static let stagingPrefix = ".staging-"
}

/// The small JSON file next to the clip that tells the saver what to play and how to tone it.
/// Written last and atomically by the app, so a saver never sees a manifest whose files are
/// missing (old clips are only deleted after the new manifest is in place).
nonisolated struct ScreenSaverManifest: Codable, Equatable, Sendable {
    /// Bumped on changes an older saver can't read. Unknown keys are ignored, so additive changes
    /// keep the version.
    static let currentVersion = 1
    static let fileName = "manifest.json"

    /// The vignette's look, mirrored from `ReadabilitySettings` (the saver can't link the app's
    /// model); a unit test keeps them equal.
    static let vignetteOpacity = 0.55
    static let vignetteInnerRadius = 0.55

    var version: Int
    /// The clip's file name inside the handoff folder; nil when there is no clip.
    var videoFileName: String?
    /// A still of the clip (JPEG) for previews and while the video loads.
    var posterFileName: String?
    /// Black overlay opacity, 0–0.6.
    var dim: Double
    var vignette: Bool
    var updatedAt: Date
    /// The wallpaper this was exported from (`URL.absoluteString`), for the app's stale check.
    var source: String?
    /// Size and modification date of the file that was exported, so replacing the file behind
    /// the same URL also counts as a change.
    var sourceFingerprint: String?

    init(
        version: Int = ScreenSaverManifest.currentVersion,
        videoFileName: String?,
        posterFileName: String?,
        dim: Double,
        vignette: Bool,
        updatedAt: Date,
        source: String? = nil,
        sourceFingerprint: String? = nil
    ) {
        self.version = version
        self.videoFileName = videoFileName
        self.posterFileName = posterFileName
        self.dim = min(max(dim, 0), 0.6)
        self.vignette = vignette
        self.updatedAt = updatedAt
        self.source = source
        self.sourceFingerprint = sourceFingerprint
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version <= Self.currentVersion else {
            throw ScreenSaverManifestError.unsupportedVersion(version)
        }
        let video = try container.decodeIfPresent(String.self, forKey: .videoFileName)
        let poster = try container.decodeIfPresent(String.self, forKey: .posterFileName)
        for name in [video, poster].compactMap(\.self) where !Self.isPlainFileName(name) {
            throw ScreenSaverManifestError.unsafeFileName(name)
        }
        self.init(
            version: version,
            videoFileName: video,
            posterFileName: poster,
            dim: try container.decodeIfPresent(Double.self, forKey: .dim) ?? 0,
            vignette: try container.decodeIfPresent(Bool.self, forKey: .vignette) ?? false,
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast,
            source: try container.decodeIfPresent(String.self, forKey: .source),
            sourceFingerprint: try container.decodeIfPresent(String.self, forKey: .sourceFingerprint)
        )
    }

    /// A single path component: no folders, no `..`, nothing hidden.
    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".") && name.utf8.count <= 255
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> ScreenSaverManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScreenSaverManifest.self, from: data)
    }

    /// The manifest in `directory`, or nil when there is none or it can't be read.
    static func read(in directory: URL) -> ScreenSaverManifest? {
        guard let data = try? Data(contentsOf: directory.appending(path: fileName)) else { return nil }
        return try? decode(data)
    }
}

nonisolated enum ScreenSaverManifestError: Error, Equatable {
    case unsupportedVersion(Int)
    case unsafeFileName(String)
}

/// What a saver instance shows, best first: the looping clip, else its poster, else a plain dark
/// gradient.
nonisolated enum ScreenSaverContent: Equatable, Sendable {
    case video(URL, poster: URL?)
    case poster(URL)
    case gradient

    /// Picks what to show from `manifest` in `directory`. Previews (the small System Settings
    /// thumbnail) get the still, never a decoder of their own.
    static func resolve(
        manifest: ScreenSaverManifest?,
        in directory: URL,
        isPreview: Bool,
        fileExists: (URL) -> Bool
    ) -> ScreenSaverContent {
        guard let manifest else { return .gradient }
        let poster = manifest.posterFileName
            .map { directory.appending(path: $0) }
            .flatMap { fileExists($0) ? $0 : nil }
        let video = manifest.videoFileName
            .map { directory.appending(path: $0) }
            .flatMap { fileExists($0) ? $0 : nil }

        if !isPreview, let video { return .video(video, poster: poster) }
        if let poster { return .poster(poster) }
        return .gradient
    }

    /// Reads the first readable manifest among `directories` and resolves it; `.gradient` and a
    /// nil manifest when none has one.
    static func load(
        from directories: [URL],
        isPreview: Bool,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    ) -> (content: ScreenSaverContent, manifest: ScreenSaverManifest?) {
        for directory in directories {
            guard let manifest = ScreenSaverManifest.read(in: directory) else { continue }
            return (resolve(manifest: manifest, in: directory, isPreview: isPreview, fileExists: fileExists), manifest)
        }
        return (.gradient, nil)
    }
}
