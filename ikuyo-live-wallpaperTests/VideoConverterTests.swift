import AVFoundation
import CoreGraphics
import Foundation
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
    transform: CGAffineTransform = .identity
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
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), Int32(frame % 255), CVPixelBufferGetDataSize(pixelBuffer))
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
