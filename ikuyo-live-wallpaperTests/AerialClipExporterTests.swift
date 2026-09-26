import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

struct AerialClipFormatTests {
    @Test func defaultsMatchTheMeasuredAerials() {
        let format = AerialClipFormat.macOS27
        #expect(format.frameRate == 240)
        #expect(format.mediaTimeScale == 240_000)
        #expect(format.frameDuration == CMTime(value: 1000, timescale: 240_000))
        #expect(format.movieTimeScale == 600)
        #expect(format.keyFrameInterval == 1200)
        #expect(format.renderSize(forUpright: CGSize(width: 7680, height: 4320)) == CGSize(width: 3840, height: 2160))
        #expect(format.renderSize(forUpright: CGSize(width: 1920, height: 1080)) == CGSize(width: 1920, height: 1080))
        #expect(format.bitrate(for: CGSize(width: 3840, height: 2160)) == 12_000_000)
        #expect(format.bitrate(for: CGSize(width: 64, height: 64)) == format.minimumBitrate)
    }
}

struct AerialClipExporterTests {
    /// The first eight bytes after the size field of the file: "ftypqt  " for QuickTime.
    private func brand(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try #require(try handle.read(upToCount: 12))
        return String(decoding: header.dropFirst(4), as: UTF8.self)
    }

    @Test func exportMatchesTheAerialFormat() async throws {
        // 1 s at 30 fps, larger than the (test-sized) limit so it gets scaled down.
        let source = try await makeTinyTestVideo(
            at: try makeTempDirectory().appending(path: "source.mov"),
            size: CGSize(width: 320, height: 180),
            frames: 30
        )
        var format = AerialClipFormat.macOS27
        format.maximumLongSide = 256
        format.maximumShortSide = 144
        format.keyFrameInterval = 60
        let output = try makeTempDirectory().appending(path: "aerial.mov")

        try await AerialClipExporter.export(source: source, output: output, format: format)

        #expect(try brand(of: output) == "ftypqt  ")
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await asset.loadTracks(withMediaType: .metadata).isEmpty)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
        let track = try #require(tracks.first)
        let (size, frameRate, minFrameDuration, timeScale, descriptions, range) = try await track.load(
            .naturalSize, .nominalFrameRate, .minFrameDuration, .naturalTimeScale, .formatDescriptions, .timeRange
        )
        #expect(size == CGSize(width: 256, height: 144))
        #expect(abs(frameRate - 240) < 0.5)
        #expect(minFrameDuration == CMTime(value: 1000, timescale: 240_000))
        #expect(timeScale == 240_000)
        #expect(abs(range.duration.seconds - 1) < 0.02)

        let description = try #require(descriptions.first)
        #expect(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_HEVC)
        #expect(CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_FormatName)
            as? String == "HEVC")
        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
        #expect(extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int == 10)
        #expect(extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
            == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
        #expect(extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
        #expect(extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
            == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
        #expect(extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool != true)

        // Every sample is one 240 fps frame, and sync frames come at least every 60 frames.
        let reader = try AVAssetReader(asset: asset)
        let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(samples)
        #expect(reader.startReading())
        var count = 0
        var syncIndices: [Int] = []
        while let buffer = samples.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(buffer) > 0 else { continue }
            #expect(CMSampleBufferGetDuration(buffer) == CMTime(value: 1000, timescale: 240_000))
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[CFString: Any]]
            if attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true { syncIndices.append(count) }
            count += 1
        }
        #expect(abs(count - 240) <= 1)
        #expect(syncIndices.first == 0)
        let gaps = zip(syncIndices.dropFirst(), syncIndices).map { $0 - $1 }
        #expect(gaps.allSatisfy { $0 <= format.keyFrameInterval })
        #expect(syncIndices.count >= count / format.keyFrameInterval)
    }

    @Test func failedExportLeavesNoOutput() async throws {
        let notAVideo = try makeTempDirectory().appending(path: "not-a-video.mov")
        try Data("nope".utf8).write(to: notAVideo)
        let output = try makeTempDirectory().appending(path: "aerial.mov")

        await #expect(throws: (any Error).self) {
            try await AerialClipExporter.export(source: notAVideo, output: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
    }
}
