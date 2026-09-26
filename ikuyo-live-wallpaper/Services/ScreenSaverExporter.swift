import AVFoundation
import Foundation
import os

/// Whether the screen saver's copy of the wallpaper matches what the app would export now.
nonisolated enum ScreenSaverExportStatus: Equatable, Sendable {
    case neverExported
    case upToDate(Date)
    /// Exported, but the wallpaper (or its dim/vignette) has changed since.
    case stale
    case failed(String)
}

/// Exports the current wallpaper for StarTorch.saver: an HEVC clip (Balanced preset, at most 4K
/// and 30 fps), a poster JPEG and the manifest, into the handoff folder the saver reads (see
/// `ScreenSaverHandoff`).
///
/// Every file is written into a staging folder first and renamed into place, the manifest last,
/// so a running saver only ever sees a complete export. Clips from earlier exports are deleted
/// afterwards; a saver still playing one keeps its open file until it lets go.
///
/// Exports only happen on request (`exportCurrentWallpaper()` / `startExport()`); a wallpaper
/// change only marks the export stale.
@Observable
final class ScreenSaverExporter {
    private(set) var status: ScreenSaverExportStatus = .neverExported
    private(set) var isExporting = false

    /// The handoff folder this exporter writes to.
    @ObservationIgnored let directory: URL
    @ObservationIgnored private let settings: AppSettings?
    @ObservationIgnored private let currentWallpaper: () -> URL?
    @ObservationIgnored private let playbackURL: (URL) -> URL
    @ObservationIgnored private let transcode: Transcoder
    @ObservationIgnored private let now: () -> Date
    /// The manifest on disk, cached so status checks don't read the file every time.
    @ObservationIgnored private var manifest: ScreenSaverManifest?
    @ObservationIgnored private var exportTask: Task<Void, any Error>?

    /// Renders `source` to an HEVC `.mp4` at `output`.
    typealias Transcoder = @Sendable (_ source: URL, _ output: URL) async throws -> Void

    private static let log = Logger(subsystem: "com.shibuyaxpress.ikuyo-live-wallpaper", category: "ScreenSaverExporter")

    /// The saver's container, spelled out from the user's real home directory.
    nonisolated static var defaultDirectory: URL {
        ScreenSaverHandoff.directory(inHome: ScreenSaverHandoff.realHomeDirectory)
    }

    /// The quality the saver's clip is encoded at: up to 4K at 30 fps.
    nonisolated static let preset = ExportQualityPreset.balanced

    nonisolated static let defaultTranscoder: Transcoder = { source, output in
        try await VideoConverter.export(source: source, output: output, edit: ImportEdit(preset: preset)) { _ in }
    }

    /// - Parameters:
    ///   - directory: The handoff folder. Tests pass a temporary folder; the real one is only
    ///     ever used by the running app.
    ///   - currentWallpaper: The wallpaper on screen, if any; `settings.lastWallpaperURL` is the
    ///     fallback.
    ///   - playbackURL: The local file behind a wallpaper URL (the download cache for catalog
    ///     wallpapers).
    init(
        directory: URL,
        settings: AppSettings?,
        currentWallpaper: @escaping () -> URL?,
        playbackURL: @escaping (URL) -> URL = { WallpaperCacheManager.resolvedURL(for: $0) },
        transcode: @escaping Transcoder = ScreenSaverExporter.defaultTranscoder,
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.settings = settings
        self.currentWallpaper = currentWallpaper
        self.playbackURL = playbackURL
        self.transcode = transcode
        self.now = now
        manifest = ScreenSaverManifest.read(in: directory)
        refreshStatus()
    }

    /// An exporter for the app: follows `manager`'s current wallpaper and marks the export stale
    /// when it (or its dim/vignette) changes.
    convenience init(manager: WallpaperManager, settings: AppSettings, directory: URL) {
        self.init(directory: directory, settings: settings, currentWallpaper: { [weak manager] in manager?.currentURL })
        follow(manager)
        followReadability(settings)
    }

    // MARK: - Status

    /// The wallpaper an export would use now: the one on screen, else the last one started.
    var sourceURL: URL? {
        currentWallpaper() ?? settings?.availableLastWallpaperURL()
    }

    /// Re-evaluates `status` against the current wallpaper. Keeps a failure until the next
    /// export unless the wallpaper has changed since.
    func refreshStatus() {
        let source = sourceURL
        let fresh = Self.status(
            manifest: manifest,
            source: source,
            readability: source.map { readability(for: $0) } ?? ReadabilitySettings(),
            fingerprint: source.flatMap { Self.fingerprint(of: playbackURL($0)) }
        )
        if case .failed = status, case .upToDate = fresh { return }
        if status != fresh { status = fresh }
    }

    /// The export is out of date, e.g. because the wallpaper changed. No-op before the first
    /// export.
    func markStale() {
        guard manifest != nil, status != .stale else { return }
        status = .stale
    }

    /// Compares an export's manifest with what would be exported now.
    nonisolated static func status(
        manifest: ScreenSaverManifest?,
        source: URL?,
        readability: ReadabilitySettings,
        fingerprint: String?
    ) -> ScreenSaverExportStatus {
        guard let manifest, manifest.videoFileName != nil else { return .neverExported }
        guard let source,
              manifest.source == source.absoluteString,
              manifest.dim == readability.dim,
              manifest.vignette == readability.vignette,
              fingerprint == nil || manifest.sourceFingerprint == nil || manifest.sourceFingerprint == fingerprint
        else { return .stale }
        return .upToDate(manifest.updatedAt)
    }

    /// Size and modification date of a local file, or nil for remote URLs and missing files.
    nonisolated static func fingerprint(of url: URL) -> String? {
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attributes[.size] as? UInt64,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return "\(size)-\(Int64(modified.timeIntervalSince1970 * 1000))"
    }

    private func readability(for url: URL) -> ReadabilitySettings {
        settings?.readability(for: url) ?? ReadabilitySettings()
    }

    private func follow(_ manager: WallpaperManager) {
        _ = withObservationTracking {
            manager.currentURL
        } onChange: { [weak self, weak manager] in
            // Called before the new value is stored; read it on the next turn.
            Task { @MainActor in
                guard let self, let manager else { return }
                self.refreshStatus()
                self.follow(manager)
            }
        }
    }

    private func followReadability(_ settings: AppSettings) {
        _ = withObservationTracking {
            settings.readabilityByWallpaper
        } onChange: { [weak self, weak settings] in
            Task { @MainActor in
                guard let self, let settings else { return }
                self.refreshStatus()
                self.followReadability(settings)
            }
        }
    }

    // MARK: - Export

    /// Starts an export in the background (for Phase B's button and automation); the outcome
    /// lands in `status`. Does nothing while one is running.
    func startExport() {
        guard !isExporting else { return }
        Task { try? await exportCurrentWallpaper() }
    }

    /// Cancels a running export; the previous export stays in place.
    func cancelExport() {
        exportTask?.cancel()
    }

    /// Exports the current wallpaper (or the last one started) to the handoff folder, replacing
    /// the previous export. If an export is already running, waits for it instead.
    func exportCurrentWallpaper() async throws {
        if let exportTask {
            try await exportTask.value
            return
        }
        let task = Task { try await performExport() }
        exportTask = task
        isExporting = true
        defer {
            exportTask = nil
            isExporting = false
        }
        try await task.value
    }

    private func performExport() async throws {
        do {
            guard let source = sourceURL else { throw ScreenSaverExportError.noWallpaper }
            let file = playbackURL(source)
            guard file.isFileURL else { throw ScreenSaverExportError.notDownloaded }
            let readability = readability(for: source)
            let written = try await Self.export(
                file: file,
                source: source,
                readability: readability,
                to: directory,
                date: now(),
                transcode: transcode
            )
            manifest = written
            status = .upToDate(written.updatedAt)
            Self.log.info("exported \(source.lastPathComponent, privacy: .public) as \(written.videoFileName ?? "-", privacy: .public)")
        } catch is CancellationError {
            refreshStatus()
            throw CancellationError()
        } catch {
            status = .failed(error.localizedDescription)
            Self.log.error("export failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Writes the clip, poster and manifest for `file` into `directory` and removes older
    /// exports. On failure the previous export is left untouched.
    @concurrent
    nonisolated static func export(
        file: URL,
        source: URL,
        readability: ReadabilitySettings,
        to directory: URL,
        date: Date,
        transcode: Transcoder
    ) async throws -> ScreenSaverManifest {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let token = UUID().uuidString.prefix(8).lowercased()
        let staging = directory.appending(path: "\(ScreenSaverHandoff.stagingPrefix)\(token)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        // 1. The clip: copied when it already fits, otherwise re-encoded.
        let metadata = try await VideoConverter.metadata(for: file)
        let copyAsIs = !needsReencode(metadata, fileExtension: file.pathExtension)
        let videoName = "\(ScreenSaverHandoff.clipPrefix)\(token).\(copyAsIs ? file.pathExtension.lowercased() : "mp4")"
        let stagedVideo = staging.appending(path: videoName)
        if copyAsIs {
            try fileManager.copyItem(at: file, to: stagedVideo)
        } else {
            try await transcode(file, stagedVideo)
        }
        try Task.checkCancellation()

        // 2. The poster. Not having one only costs the preview its picture.
        let posterName = "\(ScreenSaverHandoff.posterPrefix)\(token).jpg"
        let stagedPoster = staging.appending(path: posterName)
        let seconds = metadata.duration.seconds
        let posterTime = seconds.isFinite && seconds > 0 ? min(1, seconds / 2) : 0
        let hasPoster = (try? await VideoConverter.writePosterFrame(of: stagedVideo, at: posterTime, to: stagedPoster)) != nil
        try Task.checkCancellation()

        // 3. Move the media into place under new names, then swap the manifest atomically.
        let manifest = ScreenSaverManifest(
            videoFileName: videoName,
            posterFileName: hasPoster ? posterName : nil,
            dim: readability.dim,
            vignette: readability.vignette,
            // Whole seconds, as the ISO 8601 manifest stores it.
            updatedAt: Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)),
            source: source.absoluteString,
            sourceFingerprint: fingerprint(of: file)
        )
        let stagedManifest = staging.appending(path: ScreenSaverManifest.fileName)
        try manifest.encoded().write(to: stagedManifest)

        try fileManager.moveItem(at: stagedVideo, to: directory.appending(path: videoName))
        if hasPoster {
            try fileManager.moveItem(at: stagedPoster, to: directory.appending(path: posterName))
        }
        try replaceAtomically(directory.appending(path: ScreenSaverManifest.fileName), with: stagedManifest)

        // 4. Only now drop the previous export.
        removeOldExports(in: directory, keeping: [videoName, posterName, ScreenSaverManifest.fileName, staging.lastPathComponent])
        return manifest
    }

    /// Whether `metadata` has to be re-encoded for the saver: anything that isn't HEVC in an
    /// MP4/MOV container, bigger than 4K (in its own orientation) or faster than 30 fps. An
    /// unknown frame rate is re-encoded to be safe.
    nonisolated static func needsReencode(_ metadata: VideoMetadata, fileExtension: String) -> Bool {
        guard ["mp4", "mov", "m4v"].contains(fileExtension.lowercased()) else { return true }
        guard ["hvc1", "hev1"].contains(metadata.codec.lowercased()) else { return true }
        let size = metadata.displaySize == .zero ? metadata.resolution : metadata.displaySize
        guard size.width > 0, size.height > 0 else { return true }
        if let box = preset.maximumDimensions {
            if max(size.width, size.height) > box.long || min(size.width, size.height) > box.short { return true }
        }
        guard metadata.frameRate.isFinite, metadata.frameRate > 0 else { return true }
        if let maximum = preset.maximumFrameRate, metadata.frameRate > maximum + 0.01 { return true }
        return false
    }

    /// `rename(2)`: replaces `destination` in one step, so readers see the old or the new file.
    private nonisolated static func replaceAtomically(_ destination: URL, with source: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return EINVAL }
                return rename(from, to) == 0 ? 0 : errno
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
    }

    /// Deletes clips, posters and staging folders from earlier exports. Other files are left
    /// alone.
    private nonisolated static func removeOldExports(in directory: URL, keeping kept: Set<String>) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return }
        let prefixes = [ScreenSaverHandoff.clipPrefix, ScreenSaverHandoff.posterPrefix, ScreenSaverHandoff.stagingPrefix]
        for name in names where !kept.contains(name) && prefixes.contains(where: name.hasPrefix) {
            try? fileManager.removeItem(at: directory.appending(path: name))
        }
    }
}

nonisolated enum ScreenSaverExportError: LocalizedError {
    case noWallpaper
    case notDownloaded

    var errorDescription: String? {
        switch self {
        case .noWallpaper: String(localized: "Choose a wallpaper before exporting it to the screen saver.")
        case .notDownloaded: String(localized: "Download the wallpaper before exporting it to the screen saver.")
        }
    }
}
