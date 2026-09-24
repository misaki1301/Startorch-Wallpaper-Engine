import CryptoKit
import Foundation
import os

enum DownloadState: Equatable {
    case notStarted
    case downloading(progress: Double)
    case completed(localURL: URL)
    case failed
}

@MainActor
@Observable
final class WallpaperCacheManager {
    private(set) var states: [URL: DownloadState] = [:]
    @ObservationIgnored private var tasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let session: URLSession

    /// `Caches/WallpaperCache`, created on first use.
    nonisolated static let defaultDirectory = URL.cachesDirectory.appending(path: "WallpaperCache", directoryHint: .isDirectory)

    init(directory: URL = WallpaperCacheManager.defaultDirectory, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
        Self.migrateLegacyFilenames(in: directory)
    }

    // MARK: - Paths

    /// A fixed-length, filesystem-safe name for `url`: the SHA-256 of the URL plus its extension.
    /// Long URLs used to be hex-encoded in full, which overflowed the 255-byte filename limit.
    nonisolated static func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.lowercased()
        return "\(hex).\(ext.isEmpty || ext.count > 8 ? "mp4" : ext)"
    }

    nonisolated static func localURL(for url: URL, in directory: URL = defaultDirectory) -> URL {
        directory.appending(path: cacheKey(for: url))
    }

    /// The cached file for `url` if it has been downloaded, otherwise `url` itself.
    nonisolated static func resolvedURL(for url: URL, in directory: URL = defaultDirectory) -> URL {
        let local = localURL(for: url, in: directory)
        return FileManager.default.fileExists(atPath: local.path(percentEncoded: false)) ? local : url
    }

    func cachedURL(for url: URL) -> URL? {
        let local = Self.localURL(for: url, in: directory)
        guard FileManager.default.fileExists(atPath: local.path(percentEncoded: false)) else { return nil }
        return local
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Downloads

    func startDownload(_ url: URL) {
        guard tasks[url] == nil else { return }

        if url.isFileURL {
            states[url] = .completed(localURL: url)
            return
        }

        states[url] = .downloading(progress: 0)
        let local = Self.localURL(for: url, in: directory)
        let session = session

        tasks[url] = Task { [weak self] in
            let reporter = DownloadProgressReporter { fraction in
                Task { @MainActor in self?.updateProgress(fraction, for: url) }
            }
            do {
                try self?.ensureDirectory()
                let (tempURL, response) = try await session.download(from: url, delegate: reporter)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    try? FileManager.default.removeItem(at: tempURL)
                    throw URLError(.badServerResponse)
                }
                if FileManager.default.fileExists(atPath: local.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: local)
                }
                try FileManager.default.moveItem(at: tempURL, to: local)
                self?.finishDownload(url, state: .completed(localURL: local))
            } catch {
                self?.finishDownload(url, state: Task.isCancelled ? .notStarted : .failed)
            }
        }
    }

    private func updateProgress(_ fraction: Double, for url: URL) {
        // Late updates must not overwrite a finished or cancelled download.
        guard case .downloading = states[url] else { return }
        states[url] = .downloading(progress: fraction)
    }

    private func finishDownload(_ url: URL, state: DownloadState) {
        tasks[url] = nil
        // `removeCache` already reset the state of a cancelled download.
        if case .downloading = states[url] {
            states[url] = state
        }
    }

    // MARK: - Maintenance

    func removeCache(for url: URL) {
        tasks[url]?.cancel()
        tasks[url] = nil
        try? FileManager.default.removeItem(at: Self.localURL(for: url, in: directory))
        states[url] = .notStarted
    }

    func cacheSize() -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            total += UInt64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func clearCache() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            try? fm.removeItem(at: url)
        }
        for key in states.keys {
            states[key] = .notStarted
        }
    }

    /// Renames files cached under the old scheme (the URL's UTF-8 bytes hex-encoded, plus
    /// `.mp4`) to their hashed name, so favorites stay available offline after updating.
    nonisolated static func migrateLegacyFilenames(in directory: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in contents where file.pathExtension == "mp4" {
            let stem = file.deletingPathExtension().lastPathComponent
            // Hashed names never decode to a valid URL, so only legacy files match.
            guard let url = legacyURL(fromHexName: stem) else { continue }
            let destination = localURL(for: url, in: directory)
            if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
                try? fm.removeItem(at: file)
            } else {
                try? fm.moveItem(at: file, to: destination)
            }
        }
    }

    nonisolated static func legacyURL(fromHexName name: String) -> URL? {
        guard name.count.isMultiple(of: 2), !name.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(name.count / 2)
        var index = name.startIndex
        while index < name.endIndex {
            let next = name.index(index, offsetBy: 2)
            guard let byte = UInt8(name[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard let string = String(bytes: bytes, encoding: .utf8),
              let url = URL(string: string), url.scheme != nil else { return nil }
        return url
    }
}

/// Forwards a download task's `fractionCompleted` to `onProgress`, in steps of at least 1%.
nonisolated final class DownloadProgressReporter: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: @Sendable (Double) -> Void
    // NSKeyValueObservation isn't Sendable, but it is only stored here to keep it alive.
    private let state = OSAllocatedUnfairLock<(observation: NSKeyValueObservation?, lastReported: Double)>(
        uncheckedState: (nil, 0)
    )

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            self?.report(progress.fractionCompleted)
        }
        state.withLock { $0.observation = observation }
    }

    private func report(_ fraction: Double) {
        let shouldReport = state.withLock { state in
            guard fraction - state.lastReported >= 0.01 || fraction >= 1 else { return false }
            state.lastReported = fraction
            return true
        }
        if shouldReport { onProgress(fraction) }
    }
}
