import AVFoundation
import VideoToolbox

/// The shape of Apple's own Aerial clips, measured on macOS 27.0 (26A428) from the files in
/// `~/Library/Application Support/com.apple.wallpaper/aerials/videos` (see
/// docs/lockscreen-aerials.md, Q1). A clip handed to the Aerials extension should look the same,
/// because its player retimes samples on the assumption that they are 240 fps:
///
/// - QuickTime `.mov` (`qt  ` brand), one video track, no audio, no metadata tracks
/// - HEVC `hvc1`, Main 10, 4:2:0 10-bit, video range
/// - BT.709 primaries, transfer and matrix (SDR, no HDR metadata)
/// - 240 fps: every sample lasts 1000/240000 s, media time scale 240000, movie time scale 600
/// - a sync frame about every 5 s (1185–1200 frames), B-frames with reordering
/// - 3840×2160 or 4096×2160 at about 12 Mbit/s
///
/// Not reproduced: Apple's clips carry five HEVC temporal sub-layers (15/30/60/120/240 fps).
/// AVAssetWriter can't ask VideoToolbox for that, so this writes a single layer.
nonisolated struct AerialClipFormat: Equatable, Sendable {
    var frameRate: Int32 = 240
    var mediaTimeScale: CMTimeScale = 240_000
    var movieTimeScale: CMTimeScale = 600
    /// Largest picture, as (long side, short side). Smaller sources are never upscaled.
    var maximumLongSide: CGFloat = 3840
    var maximumShortSide: CGFloat = 2160
    var keyFrameInterval: Int = 1200
    /// Bitrate at 3840×2160, scaled by picture area for smaller output.
    var bitrateAtUHD: Int = 12_000_000
    var minimumBitrate: Int = 1_000_000

    static let macOS27 = AerialClipFormat()

    var frameDuration: CMTime { CMTime(value: CMTimeValue(mediaTimeScale / frameRate), timescale: mediaTimeScale) }

    func renderSize(forUpright size: CGSize) -> CGSize {
        ExportQualityPreset.fittedSize(size, within: (maximumLongSide, maximumShortSide))
    }

    func bitrate(for renderSize: CGSize) -> Int {
        let area = Double(renderSize.width * renderSize.height) / (3840 * 2160)
        return max(minimumBitrate, Int((Double(bitrateAtUHD) * area).rounded()))
    }

    static let colorProperties: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    func writerSettings(renderSize: CGSize) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: renderSize.width,
            AVVideoHeightKey: renderSize.height,
            AVVideoColorPropertiesKey: Self.colorProperties,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate(for: renderSize),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: keyFrameInterval,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            ] as [String: Any],
        ]
    }
}

/// Renders any clip StarTorch can read into `AerialClipFormat`. Slower sources are brought up
/// to 240 fps by repeating frames, which keeps the extension's timing assumptions true but makes
/// its slow-motion ramp on unlock step rather than glide.
nonisolated enum AerialClipExporter {
    static func export(
        source: URL,
        output: URL,
        format: AerialClipFormat = .macOS27,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
        do {
            try await performExport(source: source, output: output, format: format, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func performExport(
        source: URL,
        output: URL,
        format: AerialClipFormat,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoConverterError.noVideoTrack
        }
        let (naturalSize, preferredTransform, trackRange) = try await sourceTrack.load(
            .naturalSize, .preferredTransform, .timeRange
        )
        guard trackRange.duration > .zero else { throw VideoConverterError.emptyTimeRange }

        let (upright, orientation) = VideoConverter.orientedGeometry(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        )
        let renderSize = format.renderSize(forUpright: upright)
        let transform = orientation.concatenating(CGAffineTransform(
            scaleX: upright.width > 0 ? renderSize.width / upright.width : 1,
            y: upright.height > 0 ? renderSize.height / upright.height : 1
        ))

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw VideoConverterError.cannotBuildComposition }
        try track.insertTimeRange(trackRange, of: sourceTrack, at: .zero)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: trackRange.duration)
        instruction.layerInstructions = [layer]

        // The composition draws each source frame upright at the output size and in BT.709; it
        // still emits frames at the source's own times, `RetimingSession` spreads them on the grid.
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = format.frameDuration
        videoComposition.renderSize = renderSize
        videoComposition.instructions = [instruction]
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        try Task.checkCancellation()

        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        writer.movieTimeScale = format.movieTimeScale
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: format.writerSettings(renderSize: renderSize))
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = format.mediaTimeScale
        guard writer.canAdd(input) else { throw VideoConverterError.cannotAddInput }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)

        let reader = try AVAssetReader(asset: composition)
        let readerOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            ]
        )
        readerOutput.videoComposition = videoComposition.copy() as? AVVideoComposition ?? videoComposition
        guard reader.canAdd(readerOutput) else { throw VideoConverterError.cannotAddOutput }
        reader.add(readerOutput)

        guard reader.startReading() else { throw VideoConverterError.cannotRead(reader.error) }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw VideoConverterError.cannotWrite(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        let session = RetimingSession(
            reader: reader,
            readerOutput: readerOutput,
            writer: writer,
            adaptor: adaptor,
            frameDuration: format.frameDuration,
            duration: trackRange.duration,
            progress: progress
        )
        try await withTaskCancellationHandler {
            try await session.run()
        } onCancel: {
            session.cancel()
        }
    }
}

/// Reads composed frames at whatever times the source has them and writes one frame on every
/// tick of the output grid (1/240 s), each showing the latest source frame at or before that
/// tick. All mutable state is only touched from `queue`, the serial queue the writer input
/// calls back on, which is what makes `@unchecked Sendable` sound.
private nonisolated final class RetimingSession: @unchecked Sendable {
    private let reader: AVAssetReader
    private let readerOutput: AVAssetReaderOutput
    private let writer: AVAssetWriter
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let frameDuration: CMTime
    private let duration: CMTime
    private let progress: @MainActor @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "AerialClipExporter.retime", qos: .userInitiated)

    private var continuation: CheckedContinuation<Void, any Error>?
    private var isFinished = false
    private var isCancelled = false
    private var lastProgress: Double = 0
    /// The source frame being repeated, and the next source frame (which ends its run).
    private var current: CVPixelBuffer?
    private var next: (buffer: CVPixelBuffer, time: CMTime)?
    private var sourceExhausted = false
    private var tick: Int64 = 0

    init(
        reader: AVAssetReader,
        readerOutput: AVAssetReaderOutput,
        writer: AVAssetWriter,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        frameDuration: CMTime,
        duration: CMTime,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) {
        self.reader = reader
        self.readerOutput = readerOutput
        self.writer = writer
        self.adaptor = adaptor
        self.frameDuration = frameDuration
        self.duration = duration
        self.progress = progress
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                self.continuation = continuation
                if isCancelled {
                    abort(with: CancellationError())
                    return
                }
                adaptor.assetWriterInput.requestMediaDataWhenReady(on: queue) { [self] in
                    pump()
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            isCancelled = true
            guard !isFinished else { return }
            abort(with: CancellationError())
        }
    }

    private var tickTime: CMTime { CMTimeMultiply(frameDuration, multiplier: Int32(clamping: tick)) }

    /// Pulls source frames until the frame that covers `tickTime` is `current`.
    private func advanceSource() {
        while !sourceExhausted {
            if next == nil {
                guard let sample = readerOutput.copyNextSampleBuffer() else {
                    sourceExhausted = true
                    return
                }
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                next = (buffer, CMSampleBufferGetPresentationTimeStamp(sample))
            }
            guard let pending = next, current == nil || pending.time <= tickTime else { return }
            current = pending.buffer
            next = nil
        }
    }

    private func pump() {
        guard !isFinished else { return }
        let input = adaptor.assetWriterInput
        while input.isReadyForMoreMediaData {
            let time = tickTime
            guard time < duration else {
                finish()
                return
            }
            advanceSource()
            if sourceExhausted, reader.status == .failed {
                abort(with: VideoConverterError.transcodingFailed(reader.error))
                return
            }
            guard let frame = current else {
                // The source had no frames at all.
                abort(with: VideoConverterError.emptyTimeRange)
                return
            }
            guard adaptor.append(frame, withPresentationTime: time) else {
                abort(with: VideoConverterError.transcodingFailed(writer.error))
                return
            }
            tick += 1

            let pct = duration.seconds > 0 ? min(max(time.seconds / duration.seconds, 0), 1) : 0
            if pct - lastProgress >= 0.05 {
                lastProgress = pct
                let progress = progress
                Task { @MainActor in progress(pct) }
            }
        }
    }

    private func finish() {
        isFinished = true
        reader.cancelReading()
        adaptor.assetWriterInput.markAsFinished()
        writer.finishWriting { [self] in
            queue.async { [self] in
                if isCancelled {
                    resume(with: .failure(CancellationError()))
                } else if writer.status == .completed {
                    resume(with: .success(()))
                } else {
                    resume(with: .failure(VideoConverterError.transcodingFailed(writer.error)))
                }
            }
        }
    }

    private func abort(with error: any Error) {
        isFinished = true
        reader.cancelReading()
        if writer.status == .writing {
            writer.cancelWriting()
        }
        resume(with: .failure(error))
    }

    private func resume(with result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
