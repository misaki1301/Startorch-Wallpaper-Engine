import AVFoundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct VideoMetadata: Sendable {
    let codec: String
    /// The stored pixel size. Rotated sources (portrait phone video) report landscape here;
    /// see `displaySize` for what's actually seen.
    let resolution: CGSize
    let fileSize: UInt64
    let duration: CMTime
    let bitrate: Float
    let estimatedHEVCSize: UInt64
    /// The upright size, after the track's `preferredTransform`.
    var displaySize: CGSize = .zero
    /// `nominalFrameRate`, 0 when the file doesn't say.
    var frameRate: Float = 0
}

/// What the import studio asks for. The default is a plain re-encode of the whole clip.
nonisolated struct ImportEdit: Equatable, Sendable {
    /// Source time range to keep; `nil` keeps everything.
    var trim: CMTimeRange?
    /// Requested loop-seam crossfade in seconds; 0 for none. Clamped by `LoopCompositionPlan`.
    var crossfade: Double = 0
    var preset: ExportQualityPreset = .default
}

/// A trimmed/looped composition of a source video, ready to play in a preview or to export.
/// Built once and never mutated afterwards, which is what makes sending it across isolation
/// domains sound.
nonisolated struct StudioComposition: @unchecked Sendable {
    let asset: AVComposition
    let videoComposition: AVVideoComposition
    let plan: LoopCompositionPlan
    let settings: ExportOutputSettings
}

nonisolated enum VideoConverter {
    static func metadata(for url: URL) async throws -> VideoMetadata {
        let asset = AVURLAsset(url: url)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 ?? 0
        let duration = try await asset.load(.duration)
        var codec = "Unknown"
        var resolution = CGSize.zero
        var displaySize = CGSize.zero
        var bitrate: Float = 0
        var frameRate: Float = 0

        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first {
            let (descs, naturalSize, dataRate, transform, nominalFrameRate) = try await videoTrack.load(
                .formatDescriptions, .naturalSize, .estimatedDataRate, .preferredTransform, .nominalFrameRate
            )
            if let first = descs.first {
                codec = fourCCToString(CMFormatDescriptionGetMediaSubType(first))
            }
            resolution = naturalSize
            displaySize = orientedGeometry(naturalSize: naturalSize, preferredTransform: transform).renderSize
            bitrate = dataRate
            frameRate = nominalFrameRate
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
            estimatedHEVCSize: estimatedHEVCSize,
            displaySize: displaySize,
            frameRate: frameRate
        )
    }

    /// Frame rate used when a track reports none (`nominalFrameRate` is 0 for some
    /// variable-frame-rate files), which would otherwise produce an invalid `CMTime`.
    static let fallbackFrameRate: Float = 30

    static func effectiveFrameRate(_ nominalFrameRate: Float) -> Float {
        nominalFrameRate.isFinite && nominalFrameRate > 0 ? nominalFrameRate : fallbackFrameRate
    }

    /// The upright size of a track and the transform that draws it there. Rotated sources
    /// (e.g. portrait phone video) store landscape pixels plus a rotation in `preferredTransform`.
    static func orientedGeometry(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> (renderSize: CGSize, transform: CGAffineTransform) {
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let transform = preferredTransform.concatenating(
            CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        )
        let renderSize = CGSize(width: bounds.width.rounded(), height: bounds.height.rounded())
        return (renderSize, transform)
    }

    /// Transcodes the whole of `source` to HEVC at `output` with the default preset.
    /// Cancelling the calling task stops the reader and writer; on any failure or cancellation
    /// the partial `output` is deleted.
    static func transcodeToHEVC(
        source: URL,
        output: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        try await export(source: source, output: output, edit: ImportEdit(), progress: progress)
    }

    /// Renders `source` with `edit` (trim, loop crossfade, quality preset) to an HEVC `.mp4`
    /// at `output`. Progress runs 0…1 over the output's duration. Cancelling the calling task
    /// stops the reader and writer; on any failure or cancellation the partial `output` is
    /// deleted.
    static func export(
        source: URL,
        output: URL,
        edit: ImportEdit,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        do {
            try await performExport(source: source, output: output, edit: edit, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Builds the composition `edit` describes: the trimmed range on track A, and for a loop
    /// crossfade the clip's head on track B under A's fading tail (see `LoopCompositionPlan`).
    /// The video composition draws the source upright and scaled to the preset's size, at the
    /// preset's frame rate.
    static func makeComposition(source: URL, edit: ImportEdit) async throws -> StudioComposition {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoConverterError.noVideoTrack
        }
        let (naturalSize, preferredTransform, dataRate, nominalFrameRate, trackRange) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .estimatedDataRate, .nominalFrameRate, .timeRange
        )

        let plan = LoopCompositionPlan(sourceDuration: trackRange.end, trim: edit.trim, crossfade: edit.crossfade)
        guard plan.outputDuration > .zero else { throw VideoConverterError.emptyTimeRange }

        let (uprightSize, orientation) = orientedGeometry(
            naturalSize: naturalSize,
            preferredTransform: preferredTransform
        )
        let settings = edit.preset.outputSettings(
            sourceSize: uprightSize,
            sourceFrameRate: nominalFrameRate,
            sourceBitrate: dataRate
        )
        let transform = orientation.concatenating(CGAffineTransform(
            scaleX: uprightSize.width > 0 ? settings.renderSize.width / uprightSize.width : 1,
            y: uprightSize.height > 0 ? settings.renderSize.height / uprightSize.height : 1
        ))

        let composition = AVMutableComposition()
        guard let mainTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw VideoConverterError.cannotBuildComposition }
        try mainTrack.insertTimeRange(plan.main.source, of: videoTrack, at: plan.main.outputStart)

        func layer(_ track: AVAssetTrack) -> AVMutableVideoCompositionLayerInstruction {
            let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            instruction.setTransform(transform, at: .zero)
            return instruction
        }

        let passthrough = AVMutableVideoCompositionInstruction()
        passthrough.timeRange = plan.passthroughRange
        passthrough.layerInstructions = [layer(mainTrack)]
        var instructions = [passthrough]

        if let seam = plan.seam, let fadeRange = plan.crossfadeRange {
            guard let seamTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw VideoConverterError.cannotBuildComposition }
            try seamTrack.insertTimeRange(seam.source, of: videoTrack, at: seam.outputStart)

            // Layer instructions are listed top first: the tail fades out over the head.
            let fadingTail = layer(mainTrack)
            fadingTail.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: fadeRange)
            let crossfade = AVMutableVideoCompositionInstruction()
            crossfade.timeRange = fadeRange
            crossfade.layerInstructions = [fadingTail, layer(seamTrack)]
            instructions.append(crossfade)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(
            seconds: 1 / Double(settings.frameRate),
            preferredTimescale: 60_000
        )
        videoComposition.renderSize = settings.renderSize
        videoComposition.instructions = instructions

        return StudioComposition(
            asset: composition.copy() as? AVComposition ?? composition,
            videoComposition: videoComposition.copy() as? AVVideoComposition ?? videoComposition,
            plan: plan,
            settings: settings
        )
    }

    private static func performExport(
        source: URL,
        output: URL,
        edit: ImportEdit,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        let studio = try await makeComposition(source: source, edit: edit)
        let videoTracks = try await studio.asset.loadTracks(withMediaType: .video)
        try Task.checkCancellation()

        let settings = studio.settings
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: settings.renderSize.width,
            AVVideoHeightKey: settings.renderSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: settings.bitrate,
                AVVideoExpectedSourceFrameRateKey: settings.frameRate,
            ] as [String: Any],
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw VideoConverterError.cannotAddInput }
        writer.add(writerInput)

        let reader = try AVAssetReader(asset: studio.asset)
        let readerOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        readerOutput.videoComposition = studio.videoComposition
        guard reader.canAdd(readerOutput) else { throw VideoConverterError.cannotAddOutput }
        reader.add(readerOutput)

        guard reader.startReading() else {
            throw VideoConverterError.cannotRead(reader.error)
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw VideoConverterError.cannotWrite(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        let session = TranscodeSession(
            reader: reader,
            readerOutput: readerOutput,
            writer: writer,
            writerInput: writerInput,
            totalSeconds: studio.plan.outputDuration.seconds,
            progress: progress
        )
        try await withTaskCancellationHandler {
            try await session.run()
        } onCancel: {
            session.cancel()
        }
    }

    /// Saves the upright frame of `source` at `seconds` as a JPEG at `destination`, scaled to
    /// fit `maximumSize`. Used for the poster the studio stores next to an import.
    static func writePosterFrame(
        of source: URL,
        at seconds: Double,
        to destination: URL,
        maximumSize: CGSize = CGSize(width: 1920, height: 1920)
    ) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: max(0, seconds.isFinite ? seconds : 0), preferredTimescale: 600)
        let image = try await generator.image(at: time).image

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let output = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw VideoConverterError.cannotWritePoster }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw VideoConverterError.cannotWritePoster }
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

    private var continuation: CheckedContinuation<Void, any Error>?
    private var isFinished = false
    private var isCancelled = false
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
            queue.async { [self] in
                self.continuation = continuation
                // `cancel()` may have run before we got here.
                if isCancelled {
                    abort(with: CancellationError())
                    return
                }
                writerInput.requestMediaDataWhenReady(on: queue) { [self] in
                    pump()
                }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            isCancelled = true
            // Once finishing has started the writer can't be cancelled; its
            // completion handler reports the cancellation instead.
            guard !isFinished else { return }
            abort(with: CancellationError())
        }
    }

    private func pump() {
        guard !isFinished else { return }
        while writerInput.isReadyForMoreMediaData {
            guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                finish()
                return
            }

            guard writerInput.append(sampleBuffer) else {
                abort(with: VideoConverterError.transcodingFailed(writer.error))
                return
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let pct = totalSeconds > 0 ? min(max(pts.seconds / totalSeconds, 0), 1) : 0
            if pct - lastProgress >= 0.05 {
                lastProgress = pct
                let progress = progress
                Task { @MainActor in progress(pct) }
            }
        }
    }

    /// The reader ran out of samples: either the whole file was read or reading failed.
    private func finish() {
        isFinished = true
        guard reader.status == .completed else {
            abort(with: VideoConverterError.transcodingFailed(reader.error))
            return
        }
        writerInput.markAsFinished()
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

    /// Resumes the continuation at most once.
    private func resume(with result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

nonisolated enum VideoConverterError: LocalizedError {
    case noVideoTrack
    case cannotAddInput
    case cannotAddOutput
    case cannotRead(Error?)
    case cannotWrite(Error?)
    case transcodingFailed(Error?)
    case emptyTimeRange
    case cannotBuildComposition
    case cannotWritePoster

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The selected file has no video track."
        case .cannotAddInput: return "Failed to configure video encoder."
        case .cannotAddOutput: return "Failed to read source video."
        case .cannotRead(let error): return error?.localizedDescription ?? "Cannot read source video."
        case .cannotWrite(let error): return error?.localizedDescription ?? "Cannot start encoding."
        case .transcodingFailed(let error): return error?.localizedDescription ?? "Transcoding failed."
        case .emptyTimeRange: return "The selected part of the video is empty."
        case .cannotBuildComposition: return "Failed to prepare the video for export."
        case .cannotWritePoster: return "Failed to save the poster frame."
        }
    }
}
