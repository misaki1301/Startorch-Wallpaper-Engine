import AVFoundation
import UniformTypeIdentifiers

nonisolated struct VideoMetadata: Sendable {
    let codec: String
    let resolution: CGSize
    let fileSize: UInt64
    let duration: CMTime
    let bitrate: Float
    let estimatedHEVCSize: UInt64
}

nonisolated enum VideoConverter {
    static func metadata(for url: URL) async throws -> VideoMetadata {
        let asset = AVURLAsset(url: url)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 ?? 0
        let duration = try await asset.load(.duration)
        var codec = "Unknown"
        var resolution = CGSize.zero
        var bitrate: Float = 0

        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first {
            let (descs, naturalSize, dataRate) = try await videoTrack.load(
                .formatDescriptions, .naturalSize, .estimatedDataRate
            )
            if let first = descs.first {
                codec = fourCCToString(CMFormatDescriptionGetMediaSubType(first))
            }
            resolution = naturalSize
            bitrate = dataRate
        }

        let estimatedHEVCSize: UInt64
        if bitrate > .zero {
            let hevcBitrate = Double(bitrate) * 0.5
            estimatedHEVCSize = UInt64(hevcBitrate / 8 * duration.seconds)
        } else {
            estimatedHEVCSize = UInt64(Double(fileSize) * 0.5)
        }

        return VideoMetadata(
            codec: codec,
            resolution: resolution,
            fileSize: fileSize,
            duration: duration,
            bitrate: bitrate,
            estimatedHEVCSize: estimatedHEVCSize
        )
    }

    static func transcodeToHEVC(
        source: URL,
        output: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            throw VideoConverterError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let (naturalSize, dataRate, frameRate) = try await videoTrack.load(
            .naturalSize, .estimatedDataRate, .nominalFrameRate
        )

        let sourceBitrate = dataRate > 0 ? dataRate : 5_000_000
        let hevcBitrate = Double(sourceBitrate) * 0.5

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: naturalSize.width,
            AVVideoHeightKey: naturalSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(hevcBitrate),
                AVVideoExpectedSourceFrameRateKey: frameRate,
            ] as [String: Any],
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw VideoConverterError.cannotAddInput }
        writer.add(writerInput)

        let reader = try AVAssetReader(asset: asset)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: Int32(frameRate))
        videoComposition.renderSize = naturalSize

        let passThroughInstruction = AVMutableVideoCompositionInstruction()
        passThroughInstruction.timeRange = CMTimeRange(start: .zero, duration: duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        passThroughInstruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [passThroughInstruction]

        let readerOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        readerOutput.videoComposition = videoComposition
        guard reader.canAdd(readerOutput) else { throw VideoConverterError.cannotAddOutput }
        reader.add(readerOutput)

        guard reader.startReading() else {
            throw VideoConverterError.cannotRead(reader.error)
        }
        guard writer.startWriting() else {
            throw VideoConverterError.cannotWrite(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        let session = TranscodeSession(
            reader: reader,
            readerOutput: readerOutput,
            writer: writer,
            writerInput: writerInput,
            totalSeconds: duration.seconds,
            progress: progress
        )
        try await session.run()
    }

    private static func fourCCToString(_ fourCC: FourCharCode) -> String {
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((fourCC >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

/// Pumps samples from the reader to the writer. All mutable state is only touched from
/// `queue`, the serial queue AVAssetWriterInput delivers `requestMediaDataWhenReady` on,
/// which is what makes the `@unchecked Sendable` conformance sound.
private nonisolated final class TranscodeSession: @unchecked Sendable {
    private let reader: AVAssetReader
    private let readerOutput: AVAssetReaderOutput
    private let writer: AVAssetWriter
    private let writerInput: AVAssetWriterInput
    private let totalSeconds: Double
    private let progress: @MainActor @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "VideoConverter.transcode", qos: .userInitiated)

    private var isFinished = false
    private var lastProgress: Double = 0

    init(
        reader: AVAssetReader,
        readerOutput: AVAssetReaderOutput,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput,
        totalSeconds: Double,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) {
        self.reader = reader
        self.readerOutput = readerOutput
        self.writer = writer
        self.writerInput = writerInput
        self.totalSeconds = totalSeconds
        self.progress = progress
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writerInput.requestMediaDataWhenReady(on: queue) { [self] in
                pump(continuation)
            }
        }
    }

    private func pump(_ continuation: CheckedContinuation<Void, any Error>) {
        guard !isFinished else { return }
        while writerInput.isReadyForMoreMediaData {
            guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                writerInput.markAsFinished()
                isFinished = true
                writer.finishWriting { [self] in
                    if reader.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: VideoConverterError.transcodingFailed(reader.error))
                    }
                }
                return
            }

            writerInput.append(sampleBuffer)

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let pct = min(pts.seconds / totalSeconds, 1)
            if pct - lastProgress >= 0.05 {
                lastProgress = pct
                let progress = progress
                Task { @MainActor in progress(pct) }
            }
        }
    }
}

nonisolated enum VideoConverterError: LocalizedError {
    case noVideoTrack
    case cannotAddInput
    case cannotAddOutput
    case cannotRead(Error?)
    case cannotWrite(Error?)
    case transcodingFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The selected file has no video track."
        case .cannotAddInput: return "Failed to configure video encoder."
        case .cannotAddOutput: return "Failed to read source video."
        case .cannotRead(let error): return error?.localizedDescription ?? "Cannot read source video."
        case .cannotWrite(let error): return error?.localizedDescription ?? "Cannot start encoding."
        case .transcodingFailed(let error): return error?.localizedDescription ?? "Transcoding failed."
        }
    }
}
