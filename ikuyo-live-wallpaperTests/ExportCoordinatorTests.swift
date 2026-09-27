import CoreGraphics
import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

/// Serves a fixed body over HTTPS, for the "remote wallpaper" tests below. Distinct from
/// `WallpaperCacheTests`'s stub so the two test files don't share mutable static state.
private final class DownloadStubProtocol: URLProtocol {
    nonisolated static let body = Data(repeating: 9, count: 4_096)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(Self.body.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private func makeStubCacheManager(directory: URL) -> WallpaperCacheManager {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DownloadStubProtocol.self]
    return WallpaperCacheManager(directory: directory, session: URLSession(configuration: configuration))
}

// Serialized: these tests coordinate real (if short) debounce timers and polling loops on the
// main actor, and share one stub URLSession (see `sharedStubSession`) for the download tests.
@Suite(.serialized)
@MainActor
struct ExportCoordinatorTests {
    /// Everything one test needs: a manager whose `currentURL` the coordinator can follow, both
    /// exporters pointed at their own temp directories, and the coordinator itself with a short
    /// debounce (real `Task.sleep`, just a lot shorter than the app's ~1.5s) so tests don't wait
    /// on a near-real clock.
    struct Harness {
        let manager: WallpaperManager
        let settings: AppSettings
        let cacheManager: WallpaperCacheManager
        let systemExporter: WallpaperExtensionExporter
        let screenSaverExporter: ScreenSaverExporter
        let coordinator: ExportCoordinator
        let systemRoot: URL
        let screenSaverRoot: URL
        let cacheRoot: URL
    }

    private func makeHarness(
        debounce: Duration = .milliseconds(40),
        screenSaverInstalled: @escaping () -> Bool = { true },
        writePoster: WallpaperExtensionExporter.PosterWriter? = nil
    ) throws -> Harness {
        let settings = AppSettings(defaults: makeDefaults())
        let manager = WallpaperManager(
            restorer: DesktopRestorer(desktop: InertDesktop(), directory: .temporaryDirectory),
            settings: settings,
            presenter: FakePresenter(),
            signals: FakeSignals(),
            makeEngine: { FakeEngine(url: $0) }
        )
        let cacheRoot = try makeTempDirectory()
        let cacheManager = makeStubCacheManager(directory: cacheRoot)
        let systemRoot = try makeTempDirectory()
        let systemExporter = writePoster.map { WallpaperExtensionExporter(directory: systemRoot, writePoster: $0) }
            ?? WallpaperExtensionExporter(directory: systemRoot)
        let screenSaverRoot = try makeTempDirectory().appending(path: "StarTorch", directoryHint: .isDirectory)
        let screenSaverExporter = ScreenSaverExporter(manager: manager, settings: settings, directory: screenSaverRoot)
        let coordinator = ExportCoordinator(
            manager: manager,
            settings: settings,
            cacheManager: cacheManager,
            systemWallpaperExporter: systemExporter,
            screenSaverExporter: screenSaverExporter,
            titleForWallpaper: { $0.deletingPathExtension().lastPathComponent },
            screenSaverInstalled: screenSaverInstalled,
            debounce: debounce
        )
        coordinator.start()
        return Harness(
            manager: manager, settings: settings, cacheManager: cacheManager,
            systemExporter: systemExporter, screenSaverExporter: screenSaverExporter,
            coordinator: coordinator, systemRoot: systemRoot, screenSaverRoot: screenSaverRoot, cacheRoot: cacheRoot
        )
    }

    /// Polls `condition` for up to ~5s (well past the short debounce these tests use, and the
    /// ~2s download-watch fallback timer `ExportCoordinator` uses as a backstop).
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    @Test func applyCausesExactlyOneExportAfterDebounce() async throws {
        let harness = try makeHarness(screenSaverInstalled: { false })
        let video = try await makeTinyTestVideo(at: try makeTempDirectory().appending(path: "a.mp4"))

        harness.manager.start(with: video)
        try await waitUntil { harness.coordinator.systemWallpaperExportCount == 1 }

        let manifest = try #require(SystemWallpaperStore(root: harness.systemRoot).readManifest())
        #expect(manifest.sourceURL == video.absoluteString)
        // Give any spurious extra pass a chance to happen before asserting it didn't.
        try await Task.sleep(for: .milliseconds(150))
        #expect(harness.coordinator.systemWallpaperExportCount == 1)
    }

    @Test func rapidChangesCauseOneExportOfTheLastTarget() async throws {
        let harness = try makeHarness(debounce: .milliseconds(120), screenSaverInstalled: { false })
        let a = try await makeTinyTestVideo(at: try makeTempDirectory().appending(path: "a.mp4"))
        let b = try await makeTinyTestVideo(at: try makeTempDirectory().appending(path: "b.mp4"))
        let c = try await makeTinyTestVideo(at: try makeTempDirectory().appending(path: "c.mp4"))

        harness.manager.start(with: a)
        try await Task.sleep(for: .milliseconds(20))
        harness.manager.start(with: b)
        try await Task.sleep(for: .milliseconds(20))
        harness.manager.start(with: c)

        try await waitUntil { harness.coordinator.systemWallpaperExportCount >= 1 }
        try await Task.sleep(for: .milliseconds(150))

        #expect(harness.coordinator.systemWallpaperExportCount == 1)
        let manifest = try #require(SystemWallpaperStore(root: harness.systemRoot).readManifest())
        #expect(manifest.sourceURL == c.absoluteString)
    }

    @Test func readabilityChangeCausesReExport() async throws {
        let harness = try makeHarness(screenSaverInstalled: { false })
        let video = try await makeTinyTestVideo(at: try makeTempDirectory().appending(path: "a.mp4"))

        harness.manager.start(with: video)
        try await waitUntil { harness.coordinator.systemWallpaperExportCount == 1 }

        harness.settings.setReadability(ReadabilitySettings(dim: 0.3), for: video)
        try await waitUntil { harness.coordinator.systemWallpaperExportCount == 2 }

        let manifest = try #require(SystemWallpaperStore(root: harness.systemRoot).readManifest())
        #expect(manifest.dim == 0.3)
    }

    @Test func unchangedCausesNoExport() async throws {
        let harness = try makeHarness(debounce: .milliseconds(120), screenSaverInstalled: { false })
        let a = try await makeTinyTestVideo(at: try makeTempDirectory().appending(path: "a.mp4"))
        let b = try await makeTinyTestVideo(at: try makeTempDirectory().appending(path: "b.mp4"))

        harness.manager.start(with: a)
        try await waitUntil { harness.coordinator.systemWallpaperExportCount == 1 }
        let firstRevision = try #require(SystemWallpaperStore(root: harness.systemRoot).readManifest()).revision

        // Switch away and back to `a` within one debounce window: the pass that actually runs
        // targets `a` again, which already matches what's exported.
        harness.manager.start(with: b)
        try await Task.sleep(for: .milliseconds(30))
        harness.manager.start(with: a)

        try await Task.sleep(for: .milliseconds(250))
        #expect(harness.coordinator.systemWallpaperExportCount == 1)
        let manifest = try #require(SystemWallpaperStore(root: harness.systemRoot).readManifest())
        #expect(manifest.revision == firstRevision)
    }

    @Test func remoteNotDownloadedWaitsThenExportsOnCompletion() async throws {
        let harness = try makeHarness(screenSaverInstalled: { false })
        let remote = try #require(URL(string: "https://example.com/\(UUID().uuidString).mp4"))

        harness.manager.start(with: remote)
        try await waitUntil { harness.coordinator.isWaitingForSystemWallpaperDownload }
        #expect(harness.coordinator.systemWallpaperSyncPhase == .waitingForDownload)
        #expect(harness.coordinator.systemWallpaperExportCount == 0)

        harness.cacheManager.startDownload(remote)
        try await waitUntil { harness.coordinator.systemWallpaperExportCount == 1 }
        try await waitUntil { !harness.coordinator.isWaitingForSystemWallpaperDownload }

        let manifest = try #require(SystemWallpaperStore(root: harness.systemRoot).readManifest())
        #expect(manifest.sourceURL == remote.absoluteString)
    }

    @Test func selectionChangeDuringWaitSkipsTheStaleDownload() async throws {
        let harness = try makeHarness(screenSaverInstalled: { false })
        let remote = try #require(URL(string: "https://example.com/\(UUID().uuidString).mp4"))
        let local = try await makeTinyTestVideo(at: try makeTempDirectory().appending(path: "local.mp4"))

        harness.manager.start(with: remote)
        try await waitUntil { harness.coordinator.isWaitingForSystemWallpaperDownload }

        // The user picks a different (already-available) wallpaper before the download finishes.
        harness.manager.start(with: local)
        try await waitUntil { harness.coordinator.systemWallpaperExportCount == 1 }

        // The stale download completing afterwards must not export the wallpaper nobody picked.
        harness.cacheManager.startDownload(remote)
        // Wait for the download itself to actually settle (not just a fixed delay), so no
        // in-flight network Task from this test outlives it into the next one.
        for _ in 0..<300 {
            if case .completed = harness.cacheManager.states[remote] { break }
            if case .failed = harness.cacheManager.states[remote] { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(harness.coordinator.systemWallpaperExportCount == 1)
        let manifest = try #require(SystemWallpaperStore(root: harness.systemRoot).readManifest())
        #expect(manifest.sourceURL == local.absoluteString)
    }

    @Test func toggleOffMeansNoAutoExportButManualStillWorks() async throws {
        let harness = try makeHarness(screenSaverInstalled: { false })
        harness.settings.autoSyncSystemWallpaper = false
        let video = try await makeTinyTestVideo(at: try makeTempDirectory().appending(path: "a.mp4"))

        harness.manager.start(with: video)
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.coordinator.systemWallpaperExportCount == 0)
        #expect(SystemWallpaperStore(root: harness.systemRoot).readManifest() == nil)

        // The manual path (what Settings' "Sync Lock Screen Now" button calls) is untouched.
        let ok = await harness.systemExporter.export(
            sourceURL: video, playbackURL: video, title: "A", readability: ReadabilitySettings()
        )
        #expect(ok)
        #expect(SystemWallpaperStore(root: harness.systemRoot).readManifest() != nil)
    }

    @Test func screenSaverSyncsWhenInstalledAndSkipsOtherwise() async throws {
        let video = try await makeTinyTestVideo(at: try makeTempDirectory().appending(path: "a.mov"), size: CGSize(width: 32, height: 32))

        // Not installed and never exported before: the toggle being on isn't enough by itself.
        let notInstalled = try makeHarness(screenSaverInstalled: { false })
        notInstalled.manager.start(with: video)
        try await waitUntil { notInstalled.coordinator.systemWallpaperExportCount == 1 } // system sync still ran
        try await Task.sleep(for: .milliseconds(200))
        #expect(notInstalled.coordinator.screenSaverExportCount == 0)
        #expect(notInstalled.screenSaverExporter.status == .neverExported)

        // Installed: auto-sync exports it.
        let installed = try makeHarness(screenSaverInstalled: { true })
        installed.manager.start(with: video)
        try await waitUntilAsync { installed.coordinator.screenSaverExportCount >= 1 }
        // A real transcode runs here, so this gets a much longer budget than the other waits.
        for _ in 0..<1000 {
            if case .upToDate = installed.screenSaverExporter.status { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .upToDate = installed.screenSaverExporter.status else {
            Issue.record("screen saver never finished syncing: \(installed.screenSaverExporter.status)")
            return
        }
    }

    @Test func cancellationKeepsThePreviousManifestIntact() async throws {
        // A poster writer that can be held open until the test is ready to let it proceed, so an
        // export can be reliably caught mid-flight instead of racing a fixed delay.
        let posterGate = AsyncGate()
        let harness = try makeHarness(screenSaverInstalled: { false }) { _, destination in
            await posterGate.wait()
            return (try? Data([0xFF, 0xD8]).write(to: destination)) != nil
        }
        let a = try await makeTinyTestVideo(at: try makeTempDirectory().appending(path: "a.mp4"))
        let b = try await makeTinyTestVideo(at: try makeTempDirectory().appending(path: "b.mp4"), frames: 5)
        let c = try await makeTinyTestVideo(at: try makeTempDirectory().appending(path: "c.mp4"), frames: 8)

        // `a` exports fully first (gate open throughout), so there's a real "previous manifest"
        // to protect.
        harness.manager.start(with: a)
        try await waitUntil { harness.coordinator.systemWallpaperExportCount == 1 }
        let aManifest = try #require(SystemWallpaperStore(root: harness.systemRoot).readManifest())
        #expect(aManifest.sourceURL == a.absoluteString)

        // `b` starts exporting and blocks at the poster step (gate closed). Once it's provably
        // stuck there, `c` arrives; the coordinator must cancel `b` — which only unblocks once
        // the gate reopens — before starting `c`, and `b` must never reach the manifest write.
        await posterGate.close()
        harness.manager.start(with: b)
        try await waitUntilAsync { await posterGate.isBlocking }

        harness.manager.start(with: c)
        // Give the coordinator's debounce + `cancelExport()` time to fire while `b` is still
        // parked at the gate, proving the cancellation (not the gate) is what stops `b`.
        try await Task.sleep(for: .milliseconds(150))
        #expect(SystemWallpaperStore(root: harness.systemRoot).readManifest() == aManifest)

        await posterGate.open()
        try await waitUntil {
            SystemWallpaperStore(root: harness.systemRoot).readManifest()?.sourceURL == c.absoluteString
        }
        let finalManifest = try #require(SystemWallpaperStore(root: harness.systemRoot).readManifest())
        // `b` never got as far as writing a manifest, so the store went straight from `a` to `c`.
        #expect(finalManifest.sourceURL != b.absoluteString)
    }

    /// Like `waitUntil`, but for an `async` condition (an actor's state).
    private func waitUntilAsync(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 where !(await condition()) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }
}

/// Lets a test hold an async closure open until it's ready to let it proceed, and reopen it for
/// the next call. Used to make an export's poster step block until the test says so, instead of
/// racing a fixed delay.
private actor AsyncGate {
    private var isOpen = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Whether some call is currently parked in `wait()` — proof the gate is actually closed and
    /// something is blocked on it, not just that `close()` was called.
    private(set) var isBlocking = false

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func close() {
        isOpen = false
    }

    func wait() async {
        if isOpen { return }
        isBlocking = true
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        isBlocking = false
    }
}
