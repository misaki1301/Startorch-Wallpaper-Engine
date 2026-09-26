import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

/// Writes a short clip of solid frames with `codec`.
private func makeClip(
    codec: AVVideoCodecType,
    size: CGSize = CGSize(width: 320, height: 240),
    frames: Int = 15,
    fps: Int32 = 30,
    name: String = "source.mov"
) async throws -> URL {
    let url = try makeTempDirectory().appending(path: name)
    let writer = try AVAssetWriter(outputURL: url, fileType: name.hasSuffix(".mp4") ? .mp4 : .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codec,
        AVVideoWidthKey: size.width,
        AVVideoHeightKey: size.height,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(40 + frame * 10 % 200), CVPixelBufferGetDataSize(pixelBuffer))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
    return url
}

/// Counts transcoder calls and delegates to the real one (or fails on request).
private final class TranscodeSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var shouldFail = false
    var calls: Int { lock.withLock { _calls } }

    var transcoder: ScreenSaverExporter.Transcoder {
        { [self] source, output in
            let fail = lock.withLock { () -> Bool in
                _calls += 1
                return shouldFail
            }
            if fail { throw CocoaError(.fileWriteUnknown) }
            try await ScreenSaverExporter.defaultTranscoder(source, output)
        }
    }
}

@MainActor
struct ScreenSaverExporterTests {
    private let spy = TranscodeSpy()

    private func makeExporter(
        directory: URL,
        current: @escaping () -> URL?,
        settings: AppSettings? = nil
    ) -> ScreenSaverExporter {
        ScreenSaverExporter(
            directory: directory,
            settings: settings,
            currentWallpaper: current,
            playbackURL: { $0 },
            transcode: spy.transcoder,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
    }

    @Test func startsNeverExported() throws {
        let exporter = makeExporter(directory: try makeTempDirectory(), current: { nil })
        #expect(exporter.status == .neverExported)
        #expect(!exporter.isExporting)
    }

    @Test func exportsAnHEVCClipPosterAndManifest() async throws {
        let source = try await makeClip(codec: .h264)
        let dir = try makeTempDirectory().appending(path: "StarTorch", directoryHint: .isDirectory)
        let settings = AppSettings(defaults: makeDefaults())
        settings.setReadability(ReadabilitySettings(dim: 0.25, vignette: true), for: source)
        let exporter = makeExporter(directory: dir, current: { source }, settings: settings)

        try await exporter.exportCurrentWallpaper()

        #expect(spy.calls == 1)
        let manifest = try #require(ScreenSaverManifest.read(in: dir))
        let video = try #require(manifest.videoFileName)
        let poster = try #require(manifest.posterFileName)
        #expect(video.hasPrefix("clip-") && video.hasSuffix(".mp4"))
        #expect(poster.hasPrefix("poster-") && poster.hasSuffix(".jpg"))
        #expect(manifest.dim == 0.25)
        #expect(manifest.vignette)
        #expect(manifest.source == source.absoluteString)
        #expect(manifest.sourceFingerprint == ScreenSaverExporter.fingerprint(of: source))
        // Nothing half-written is left behind.
        #expect(try contents(of: dir) == [video, ScreenSaverManifest.fileName, poster].sorted())

        let metadata = try await VideoConverter.metadata(for: dir.appending(path: video))
        #expect(["hvc1", "hev1"].contains(metadata.codec))
        #expect(exporter.status == .upToDate(Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(!exporter.isExporting)

        // The saver would pick exactly these files.
        let (content, _) = ScreenSaverContent.load(from: [dir], isPreview: false)
        #expect(content == .video(dir.appending(path: video), poster: dir.appending(path: poster)))
    }

    @Test func sourceThatAlreadyFitsIsCopiedNotReencoded() async throws {
        let source = try await makeClip(codec: .hevc, name: "already.mp4")
        let dir = try makeTempDirectory()
        let exporter = makeExporter(directory: dir, current: { source })

        try await exporter.exportCurrentWallpaper()

        #expect(spy.calls == 0)
        let manifest = try #require(ScreenSaverManifest.read(in: dir))
        let video = try #require(manifest.videoFileName)
        #expect(video.hasSuffix(".mp4"))
        #expect(try Data(contentsOf: dir.appending(path: video)) == Data(contentsOf: source))
    }

    @Test func reexportReplacesAndCleansUpTheOldClip() async throws {
        let first = try await makeClip(codec: .hevc, name: "first.mov")
        let second = try await makeClip(codec: .hevc, name: "second.mov")
        let dir = try makeTempDirectory()
        var current = first
        let exporter = makeExporter(directory: dir, current: { current })

        try await exporter.exportCurrentWallpaper()
        let old = try #require(ScreenSaverManifest.read(in: dir))
        // Something else in the folder isn't ours to delete.
        try Data("keep".utf8).write(to: dir.appending(path: "notes.txt"))

        current = second
        try await exporter.exportCurrentWallpaper()
        let new = try #require(ScreenSaverManifest.read(in: dir))

        #expect(new.videoFileName != old.videoFileName)
        #expect(new.source == second.absoluteString)
        let files = try contents(of: dir)
        #expect(files.filter { $0.hasPrefix("clip-") } == [new.videoFileName].compactMap(\.self))
        #expect(files.filter { $0.hasPrefix("poster-") } == [new.posterFileName].compactMap(\.self))
        #expect(files.contains("notes.txt"))
        #expect(!files.contains { $0.hasPrefix(".staging-") })
    }

    @Test func failedExportLeavesThePreviousOneInPlace() async throws {
        let good = try await makeClip(codec: .hevc, name: "good.mov")
        let bad = try await makeClip(codec: .h264, name: "bad.mov")
        let dir = try makeTempDirectory()
        var current = good
        let exporter = makeExporter(directory: dir, current: { current })
        try await exporter.exportCurrentWallpaper()
        let before = try contents(of: dir)
        let manifest = try Data(contentsOf: dir.appending(path: ScreenSaverManifest.fileName))

        current = bad
        spy.shouldFail = true
        await #expect(throws: CocoaError.self) { try await exporter.exportCurrentWallpaper() }

        #expect(try contents(of: dir) == before)
        #expect(try Data(contentsOf: dir.appending(path: ScreenSaverManifest.fileName)) == manifest)
        guard case .failed = exporter.status else {
            Issue.record("expected .failed, got \(exporter.status)")
            return
        }
    }

    @Test func noWallpaperFails() async throws {
        let exporter = makeExporter(directory: try makeTempDirectory(), current: { nil })
        await #expect(throws: ScreenSaverExportError.self) { try await exporter.exportCurrentWallpaper() }
        #expect(exporter.status == .failed(ScreenSaverExportError.noWallpaper.localizedDescription))
    }

    @Test func fallsBackToTheLastWallpaper() async throws {
        let source = try await makeClip(codec: .hevc, name: "last.mov")
        let settings = AppSettings(defaults: makeDefaults())
        settings.lastWallpaperURL = source
        let dir = try makeTempDirectory()
        let exporter = makeExporter(directory: dir, current: { nil }, settings: settings)

        try await exporter.exportCurrentWallpaper()
        #expect(ScreenSaverManifest.read(in: dir)?.source == source.absoluteString)
    }

    @Test func changingTheWallpaperMakesTheExportStale() async throws {
        let first = try await makeClip(codec: .hevc, name: "a.mov")
        let second = try await makeClip(codec: .hevc, name: "b.mov")
        let settings = AppSettings(defaults: makeDefaults())
        let dir = try makeTempDirectory()
        var current: URL? = first
        let exporter = makeExporter(directory: dir, current: { current }, settings: settings)
        try await exporter.exportCurrentWallpaper()
        let exported = exporter.status

        current = second
        exporter.refreshStatus()
        #expect(exporter.status == .stale)

        current = first
        exporter.refreshStatus()
        #expect(exporter.status == exported)

        settings.setReadability(ReadabilitySettings(dim: 0.4), for: first)
        exporter.refreshStatus()
        #expect(exporter.status == .stale)
    }

    @Test func aNewExporterPicksUpTheExportOnDisk() async throws {
        let source = try await makeClip(codec: .hevc, name: "disk.mov")
        let dir = try makeTempDirectory()
        try await makeExporter(directory: dir, current: { source }).exportCurrentWallpaper()

        #expect(makeExporter(directory: dir, current: { source }).status == .upToDate(Date(timeIntervalSince1970: 1_800_000_000)))
        let other = URL(filePath: "/tmp/elsewhere.mp4")
        #expect(makeExporter(directory: dir, current: { other }).status == .stale)
    }

    @Test func markStaleOnlyAfterAnExport() async throws {
        let exporter = makeExporter(directory: try makeTempDirectory(), current: { nil })
        exporter.markStale()
        #expect(exporter.status == .neverExported)
    }

    @Test func followsTheManagersCurrentWallpaper() async throws {
        let first = try await makeClip(codec: .hevc, name: "shown.mov")
        let second = URL(filePath: "/tmp/other-wallpaper.mp4")
        let settings = AppSettings(defaults: makeDefaults())
        let manager = WallpaperManager(
            restorer: DesktopRestorer(desktop: InertDesktop(), directory: .temporaryDirectory),
            settings: settings,
            presenter: FakePresenter(),
            signals: FakeSignals(),
            makeEngine: { FakeEngine(url: $0) }
        )
        manager.start(with: first)
        let dir = try makeTempDirectory()
        try await makeExporter(directory: dir, current: { first }).exportCurrentWallpaper()

        let exporter = ScreenSaverExporter(manager: manager, settings: settings, directory: dir)
        #expect(exporter.status == .upToDate(Date(timeIntervalSince1970: 1_800_000_000)))

        manager.start(with: second)
        // The change is picked up on the next main-actor turn.
        for _ in 0..<20 where exporter.status != .stale {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(exporter.status == .stale)
    }
}

struct ScreenSaverReencodeDecisionTests {
    private func metadata(codec: String = "hvc1", size: CGSize = CGSize(width: 3840, height: 2160), fps: Float = 30) -> VideoMetadata {
        VideoMetadata(
            codec: codec, resolution: size, fileSize: 1, duration: CMTime(seconds: 10, preferredTimescale: 600),
            bitrate: 1, estimatedHEVCSize: 1, displaySize: size, frameRate: fps
        )
    }

    @Test func hevcUpTo4K30IsKept() {
        #expect(!ScreenSaverExporter.needsReencode(metadata(), fileExtension: "mp4"))
        #expect(!ScreenSaverExporter.needsReencode(metadata(fps: 29.97), fileExtension: "MOV"))
        #expect(!ScreenSaverExporter.needsReencode(metadata(codec: "hev1", size: CGSize(width: 1920, height: 1080), fps: 24), fileExtension: "m4v"))
        // Portrait clips are measured in their own orientation.
        #expect(!ScreenSaverExporter.needsReencode(metadata(size: CGSize(width: 2160, height: 3840)), fileExtension: "mp4"))
    }

    @Test func otherCodecsAreReencoded() {
        #expect(ScreenSaverExporter.needsReencode(metadata(codec: "avc1"), fileExtension: "mp4"))
        #expect(ScreenSaverExporter.needsReencode(metadata(codec: "ap4h"), fileExtension: "mov"))
    }

    @Test func tooBigOrTooFastIsReencoded() {
        #expect(ScreenSaverExporter.needsReencode(metadata(size: CGSize(width: 5120, height: 2880)), fileExtension: "mp4"))
        #expect(ScreenSaverExporter.needsReencode(metadata(size: CGSize(width: 3840, height: 2400)), fileExtension: "mp4"))
        #expect(ScreenSaverExporter.needsReencode(metadata(fps: 60), fileExtension: "mp4"))
        #expect(ScreenSaverExporter.needsReencode(metadata(fps: 0), fileExtension: "mp4"))
    }

    @Test func unknownContainersAreReencoded() {
        #expect(ScreenSaverExporter.needsReencode(metadata(), fileExtension: "mkv"))
        #expect(ScreenSaverExporter.needsReencode(metadata(), fileExtension: ""))
    }

    @Test func balancedIsTheSaverPreset() {
        #expect(ScreenSaverExporter.preset == .balanced)
        #expect(ScreenSaverExporter.preset.maximumFrameRate == 30)
        #expect(ScreenSaverExporter.preset.maximumDimensions?.long == 3840)
    }
}

struct ScreenSaverStatusTests {
    let source = URL(filePath: "/tmp/rain.mp4")
    var manifest: ScreenSaverManifest {
        ScreenSaverManifest(
            videoFileName: "clip-1.mp4", posterFileName: nil, dim: 0.2, vignette: false,
            updatedAt: Date(timeIntervalSince1970: 5), source: source.absoluteString, sourceFingerprint: "10-20"
        )
    }

    @Test func matchingManifestIsUpToDate() {
        let status = ScreenSaverExporter.status(
            manifest: manifest, source: source, readability: ReadabilitySettings(dim: 0.2), fingerprint: "10-20"
        )
        #expect(status == .upToDate(Date(timeIntervalSince1970: 5)))
    }

    @Test func differencesAreStale() {
        let other = URL(filePath: "/tmp/snow.mp4")
        #expect(ScreenSaverExporter.status(manifest: manifest, source: other, readability: ReadabilitySettings(dim: 0.2), fingerprint: nil) == .stale)
        #expect(ScreenSaverExporter.status(manifest: manifest, source: nil, readability: ReadabilitySettings(), fingerprint: nil) == .stale)
        #expect(ScreenSaverExporter.status(manifest: manifest, source: source, readability: ReadabilitySettings(dim: 0.3), fingerprint: "10-20") == .stale)
        #expect(ScreenSaverExporter.status(manifest: manifest, source: source, readability: ReadabilitySettings(dim: 0.2, vignette: true), fingerprint: "10-20") == .stale)
        // The file behind the same URL was replaced.
        #expect(ScreenSaverExporter.status(manifest: manifest, source: source, readability: ReadabilitySettings(dim: 0.2), fingerprint: "11-20") == .stale)
    }

    @Test func blurAndSpeedDontMatter() {
        let status = ScreenSaverExporter.status(
            manifest: manifest, source: source, readability: ReadabilitySettings(dim: 0.2, blur: 10, speed: 0.5), fingerprint: "10-20"
        )
        #expect(status == .upToDate(Date(timeIntervalSince1970: 5)))
    }

    @Test func noManifestOrNoClipIsNeverExported() {
        #expect(ScreenSaverExporter.status(manifest: nil, source: source, readability: ReadabilitySettings(), fingerprint: nil) == .neverExported)
        var empty = manifest
        empty.videoFileName = nil
        #expect(ScreenSaverExporter.status(manifest: empty, source: source, readability: ReadabilitySettings(), fingerprint: nil) == .neverExported)
    }
}
