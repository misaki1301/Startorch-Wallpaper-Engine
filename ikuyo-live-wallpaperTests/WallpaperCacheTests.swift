import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

struct CacheKeyTests {
    @Test func keyIsFixedLengthForVeryLongURLs() {
        let long = URL(string: "https://example.com/" + String(repeating: "a", count: 2_000) + ".mp4")!
        let key = WallpaperCacheManager.cacheKey(for: long)
        #expect(key.count == 64 + ".mp4".count)
        #expect(key.utf8.count < 255)
    }

    @Test func keyIsStableAndDistinct() {
        let a = URL(string: "https://example.com/a.mp4")!
        let b = URL(string: "https://example.com/b.mp4")!
        #expect(WallpaperCacheManager.cacheKey(for: a) == WallpaperCacheManager.cacheKey(for: a))
        #expect(WallpaperCacheManager.cacheKey(for: a) != WallpaperCacheManager.cacheKey(for: b))
    }

    @Test func keyIsLowercaseHexSHA256() {
        // printf 'https://example.com/a.mp4' | shasum -a 256
        let key = WallpaperCacheManager.cacheKey(for: URL(string: "https://example.com/a.mp4")!)
        #expect(key == "0e06dca0234da29358bb3b0f700b1473b459642abac60b6542eacee7feb1521f.mp4")
    }

    @Test func keepsShortExtensionsAndDefaultsToMP4() {
        #expect(WallpaperCacheManager.cacheKey(for: URL(string: "https://e.com/x.MOV")!).hasSuffix(".mov"))
        #expect(WallpaperCacheManager.cacheKey(for: URL(string: "https://e.com/stream")!).hasSuffix(".mp4"))
    }

    @Test func longURLCanBeWrittenToDisk() throws {
        let dir = try makeTempDirectory()
        let long = URL(string: "https://example.com/" + String(repeating: "b", count: 1_000) + ".mp4")!
        let local = WallpaperCacheManager.localURL(for: long, in: dir)
        try Data("video".utf8).write(to: local)
        #expect(WallpaperCacheManager.resolvedURL(for: long, in: dir) == local)
    }
}

@MainActor
struct WallpaperCacheMigrationTests {
    @Test func renamesLegacyHexFilesToHashedNames() throws {
        let dir = try makeTempDirectory()
        let url = URL(string: "https://example.com/rain.mp4")!
        let legacyName = Data(url.absoluteString.utf8).map { String(format: "%02x", $0) }.joined() + ".mp4"
        try Data("video".utf8).write(to: dir.appending(path: legacyName))

        let manager = WallpaperCacheManager(directory: dir)

        #expect(manager.cachedURL(for: url) == WallpaperCacheManager.localURL(for: url, in: dir))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: legacyName).path(percentEncoded: false)))
    }

    @Test func leavesHashedFilesAlone() throws {
        let dir = try makeTempDirectory()
        let url = URL(string: "https://example.com/rain.mp4")!
        let hashed = WallpaperCacheManager.localURL(for: url, in: dir)
        try Data("video".utf8).write(to: hashed)

        _ = WallpaperCacheManager(directory: dir)

        #expect(FileManager.default.fileExists(atPath: hashed.path(percentEncoded: false)))
    }
}

// MARK: - Download progress

/// Serves `StubURLProtocol.body` in several chunks with a Content-Length header.
private final class StubURLProtocol: URLProtocol {
    nonisolated static let body = Data(repeating: 7, count: 400_000)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(
            url: url,
            statusCode: url.path == "/missing.mp4" ? 404 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(Self.body.count)", "Content-Type": "video/mp4"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk = Self.body.count / 10
        for offset in stride(from: 0, to: Self.body.count, by: chunk) {
            client?.urlProtocol(self, didLoad: Self.body.subdata(in: offset..<min(offset + chunk, Self.body.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class FractionRecorder: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var values: [Double] = []
    func append(_ value: Double) { lock.withLock { values.append(value) } }
    var recorded: [Double] { lock.withLock { values } }
}

struct DownloadProgressTests {
    @Test func reporterSeesIntermediateProgress() async throws {
        let recorder = FractionRecorder()
        let reporter = DownloadProgressReporter { recorder.append($0) }

        let (file, _) = try await makeStubSession().download(
            from: URL(string: "https://stub.test/video.mp4")!,
            delegate: reporter
        )
        try? FileManager.default.removeItem(at: file)

        let fractions = recorder.recorded
        #expect(fractions.contains { $0 > 0 && $0 < 1 })
        #expect(fractions.last == 1)
        #expect(fractions == fractions.sorted())
    }
}

@MainActor
struct WallpaperCacheDownloadTests {
    private func waitUntilFinished(_ manager: WallpaperCacheManager, _ url: URL) async throws {
        for _ in 0..<200 {
            if case .downloading = manager.states[url] {
                try await Task.sleep(for: .milliseconds(10))
            } else {
                return
            }
        }
    }

    @Test func downloadStoresFileUnderHashedName() async throws {
        let dir = try makeTempDirectory()
        let manager = WallpaperCacheManager(directory: dir, session: makeStubSession())
        let url = URL(string: "https://stub.test/" + String(repeating: "x", count: 600) + ".mp4")!

        manager.startDownload(url)
        try await waitUntilFinished(manager, url)

        let local = WallpaperCacheManager.localURL(for: url, in: dir)
        #expect(manager.states[url] == .completed(localURL: local))
        #expect(try Data(contentsOf: local) == StubURLProtocol.body)
    }

    @Test func httpErrorsMarkTheDownloadFailed() async throws {
        let dir = try makeTempDirectory()
        let manager = WallpaperCacheManager(directory: dir, session: makeStubSession())
        let url = URL(string: "https://stub.test/missing.mp4")!

        manager.startDownload(url)
        try await waitUntilFinished(manager, url)

        #expect(manager.states[url] == .failed)
        #expect(manager.cachedURL(for: url) == nil)
    }
}
