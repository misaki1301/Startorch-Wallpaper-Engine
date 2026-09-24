import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import StarTorch_Wallpaper_Engine

struct VideoConverterTests {
    @Test(arguments: [Float(0), -1, .nan, .infinity])
    func invalidFrameRatesFallBackToThirty(_ nominal: Float) {
        #expect(VideoConverter.effectiveFrameRate(nominal) == VideoConverter.fallbackFrameRate)
    }

    @Test func validFrameRatesArePreserved() {
        #expect(VideoConverter.effectiveFrameRate(23.976) == 23.976)
        #expect(VideoConverter.effectiveFrameRate(60) == 60)
    }

    @Test func identityTransformKeepsNaturalSize() {
        let geometry = VideoConverter.orientedGeometry(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: .identity
        )
        #expect(geometry.renderSize == CGSize(width: 1920, height: 1080))
        #expect(geometry.transform == .identity)
    }

    @Test func portraitVideoRendersUpright() {
        // How iPhones store portrait video: landscape pixels rotated 90° and shifted back on screen.
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let geometry = VideoConverter.orientedGeometry(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: rotation
        )
        #expect(geometry.renderSize == CGSize(width: 1080, height: 1920))
        let drawn = CGRect(x: 0, y: 0, width: 1920, height: 1080).applying(geometry.transform)
        #expect(drawn.minX.rounded() == 0 && drawn.minY.rounded() == 0)
    }

    @Test func rotationWithoutTranslationIsMovedIntoFrame() {
        let geometry = VideoConverter.orientedGeometry(
            naturalSize: CGSize(width: 1920, height: 1080),
            preferredTransform: CGAffineTransform(rotationAngle: .pi / 2)
        )
        #expect(geometry.renderSize == CGSize(width: 1080, height: 1920))
        let drawn = CGRect(x: 0, y: 0, width: 1920, height: 1080).applying(geometry.transform)
        #expect(abs(drawn.minX) < 0.001 && abs(drawn.minY) < 0.001)
    }
}

/// Writes a short H.264 clip of solid frames, tagged with `transform` like a phone would.
private func makeSampleVideo(
    size: CGSize,
    frames: Int,
    fps: Int32 = 30,
    transform: CGAffineTransform = .identity,
    brightness: (Int) -> Int = { $0 % 255 }
) async throws -> URL {
    let url = try makeTempDirectory().appending(path: "sample.mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: size.width,
        AVVideoHeightKey: size.height,
    ])
    input.transform = transform
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
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(brightness(frame)), CVPixelBufferGetDataSize(pixelBuffer))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
    return url
}

struct VideoConverterTranscodeTests {
    @Test func portraitSourceIsWrittenUpright() async throws {
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0)
        let source = try await makeSampleVideo(size: CGSize(width: 320, height: 240), frames: 15, transform: rotation)
        let output = try makeTempDirectory().appending(path: "out.mp4")

        try await VideoConverter.transcodeToHEVC(source: source, output: output) { _ in }

        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        #expect(size == CGSize(width: 240, height: 320))
        #expect(transform == .identity)
    }

    @Test func cancellingRemovesPartialOutput() async throws {
        let source = try await makeSampleVideo(size: CGSize(width: 1280, height: 720), frames: 600)
        let output = try makeTempDirectory().appending(path: "out.mp4")

        let task = Task {
            try await VideoConverter.transcodeToHEVC(source: source, output: output) { _ in }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
    }
}

/// The average gray level (0…255) of the frame of `url` at `seconds`.
private func brightness(of url: URL, at seconds: Double) async throws -> Double {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image

    let side = 8
    var pixels = [UInt8](repeating: 0, count: side * side)
    let context = try #require(CGContext(
        data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
}

private func videoDuration(_ url: URL) async throws -> Double {
    try await AVURLAsset(url: url).load(.duration).seconds
}

struct VideoConverterExportTests {
    @Test func trimKeepsOnlyTheTrimmedRange() async throws {
        // 2 s at 30 fps, each frame 4 levels brighter than the last.
        let source = try await makeSampleVideo(size: CGSize(width: 160, height: 120), frames: 60) { $0 * 4 }
        let output = try makeTempDirectory().appending(path: "trimmed.mp4")
        let edit = ImportEdit(
            trim: CMTimeRange(start: CMTime(value: 15, timescale: 30), end: CMTime(value: 45, timescale: 30))
        )

        try await VideoConverter.export(source: source, output: output, edit: edit) { _ in }

        #expect(abs(try await videoDuration(output) - 1.0) < 0.05)
        // The first frame is source frame 15 (level 60), not frame 0.
        #expect(abs(try await brightness(of: output, at: 0) - 60) < 12)
    }

    @Test func loopCrossfadeShortensTheClipAndHidesTheSeam() async throws {
        // 3 s ramp from black to bright: a plain loop jumps from bright straight back to black.
        let source = try await makeSampleVideo(size: CGSize(width: 160, height: 120), frames: 90) { $0 * 2 }
        let plain = try makeTempDirectory().appending(path: "plain.mp4")
        let looped = try makeTempDirectory().appending(path: "looped.mp4")

        try await VideoConverter.export(source: source, output: plain, edit: ImportEdit()) { _ in }
        try await VideoConverter.export(source: source, output: looped, edit: ImportEdit(crossfade: 0.5)) { _ in }

        let plainDuration = try await videoDuration(plain)
        let loopedDuration = try await videoDuration(looped)
        #expect(abs(plainDuration - 3.0) < 0.05)
        #expect(abs(loopedDuration - 2.5) < 0.05)

        let lastFrame = 1.0 / 30 + 0.005
        let plainJump = abs(try await brightness(of: plain, at: plainDuration - lastFrame) - (try await brightness(of: plain, at: 0)))
        let loopedJump = abs(try await brightness(of: looped, at: loopedDuration - lastFrame) - (try await brightness(of: looped, at: 0)))

        #expect(plainJump > 100)
        #expect(loopedJump < 20)
    }

    @Test func batterySaverDownscalesAndDropsTheFrameRate() async throws {
        let source = try await makeSampleVideo(size: CGSize(width: 2560, height: 1440), frames: 60, fps: 60)
        let output = try makeTempDirectory().appending(path: "battery.mp4")

        try await VideoConverter.export(source: source, output: output, edit: ImportEdit(preset: .batterySaver)) { _ in }

        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let (size, frameRate) = try await track.load(.naturalSize, .nominalFrameRate)
        #expect(size == CGSize(width: 1920, height: 1080))
        #expect(abs(frameRate - 24) < 1.5)
        #expect(abs(try await videoDuration(output) - 1.0) < 0.06)
    }

    @Test func cancellingALoopExportRemovesPartialOutput() async throws {
        let source = try await makeSampleVideo(size: CGSize(width: 1280, height: 720), frames: 600)
        let output = try makeTempDirectory().appending(path: "out.mp4")
        let edit = ImportEdit(
            trim: CMTimeRange(start: .zero, duration: CMTime(value: 590, timescale: 30)),
            crossfade: 1
        )

        let task = Task {
            try await VideoConverter.export(source: source, output: output, edit: edit) { _ in }
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
    }

    @Test func posterFrameIsWrittenUpright() async throws {
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0)
        let source = try await makeSampleVideo(size: CGSize(width: 320, height: 240), frames: 30, transform: rotation)
        let poster = try makeTempDirectory().appending(path: "poster.jpg")

        try await VideoConverter.writePosterFrame(of: source, at: 0.5, to: poster)

        let imageSource = try #require(CGImageSourceCreateWithURL(poster as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect(image.width == 240)
        #expect(image.height == 320)
    }

    @Test func compositionReportsTheOutputSettings() async throws {
        let source = try await makeSampleVideo(size: CGSize(width: 320, height: 240), frames: 30)
        let composition = try await VideoConverter.makeComposition(source: source, edit: ImportEdit(crossfade: 0.25))

        #expect(composition.plan.hasCrossfade)
        #expect(composition.videoComposition.renderSize == CGSize(width: 320, height: 240))
        #expect(composition.videoComposition.instructions.count == 2)
        let tracks = try await composition.asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 2)
    }
}
