import Foundation

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
    private var tasks: [URL: Task<Void, Never>] = [:]

    private var cacheDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appending(path: "WallpaperCache", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cachedURL(for url: URL) -> URL? {
        let local = localURL(for: url)
        guard FileManager.default.fileExists(atPath: local.path(percentEncoded: false)) else { return nil }
        return local
    }

    func startDownload(_ url: URL) {
        guard tasks[url] == nil else { return }

        if url.isFileURL {
            states[url] = .completed(localURL: url)
            return
        }

        states[url] = .downloading(progress: 0)

        tasks[url] = Task { [weak self] in
            defer { self?.tasks[url] = nil }
            do {
                let local = self?.localURL(for: url) ?? Self.defaultLocalURL(for: url)
                if FileManager.default.fileExists(atPath: local.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: local)
                }

                let (tempURL, _) = try await URLSession.shared.download(from: url)
                try FileManager.default.moveItem(at: tempURL, to: local)

                self?.states[url] = .completed(localURL: local)
            } catch {
                self?.states[url] = .failed
            }
        }
    }

    func removeCache(for url: URL) {
        tasks[url]?.cancel()
        tasks[url] = nil
        let local = localURL(for: url)
        try? FileManager.default.removeItem(at: local)
        states[url] = .notStarted
    }

    private func localURL(for url: URL) -> URL {
        Self.defaultLocalURL(for: url)
    }

    static func resolvedURL(for url: URL) -> URL {
        let local = defaultLocalURL(for: url)
        if FileManager.default.fileExists(atPath: local.path(percentEncoded: false)) {
            return local
        }
        return url
    }

    static var cacheDirectoryURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appending(path: "WallpaperCache", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cacheSize() -> UInt64 {
        let fm = FileManager.default
        let dir = Self.cacheDirectoryURL
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
                  let size = attrs[.size] as? UInt64
            else { continue }
            total += size
        }
        return total
    }

    func clearCache() {
        let dir = Self.cacheDirectoryURL
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            try? fm.removeItem(at: url)
        }
        for key in states.keys {
            states[key] = .notStarted
        }
    }

    private static func defaultLocalURL(for url: URL) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appending(path: "WallpaperCache", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hash = url.absoluteString.data(using: .utf8)!.map { String(format: "%02x", $0) }.joined()
        return dir.appending(path: "\(hash).mp4")
    }
}
