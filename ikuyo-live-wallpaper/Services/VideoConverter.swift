import AVFoundation
import UniformTypeIdentifiers

struct VideoMetadata {
    let codec: String
    let resolution: CGSize
    let fileSize: UInt64
    let duration: CMTime
    let bitrate: Float
    let estimatedHEVCSize: UInt64
}

enum VideoConverter {
    static func metadata(for url: URL) async throws -> VideoMetadata {
        let asset = AVURLAsset(url: url)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 ?? 0
        let duration = asset.duration
        var codec = "Unknown"
        var resolution = CGSize.zero
        var bitrate: Float = 0

        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first {
            let descs = videoTrack.formatDescriptions as! [CMFormatDescription]
            if let first = descs.first {
                let fourCC = CMFormatDescriptionGetMediaSubType(first)
                codec = fourCCToString(fourCC)
            }
            resolution = videoTrack.naturalSize
            bitrate = videoTrack.estimatedDataRate
        }

        let estimatedHEVCSize: UInt64
        if bitrate > .zero {
            let durationSec = duration.seconds
            let hevcBitrate = Double(bitrate) * 0.5
            estimatedHEVCSize = UInt64(hevcBitrate / 8 * durationSec)
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
        progress: @escaping (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else {
            throw VideoConverterError.noVideoTrack
        }

        let sourceBitrate = videoTrack.estimatedDataRate > 0 ? videoTrack.estimatedDataRate : 5_000_000
        let hevcBitrate = Double(sourceBitrate) * 0.5

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: videoTrack.naturalSize.width,
            AVVideoHeightKey: videoTrack.naturalSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(hevcBitrate),
                AVVideoExpectedSourceFrameRateKey: videoTrack.nominalFrameRate,
            ] as [String: Any],
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw VideoConverterError.cannotAddInput }
        writer.add(writerInput)

        let reader = try AVAssetReader(asset: asset)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: Int32(videoTrack.nominalFrameRate))
        videoComposition.renderSize = videoTrack.naturalSize

        let passThroughInstruction = AVMutableVideoCompositionInstruction()
        passThroughInstruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

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

        let totalDuration = asset.duration.seconds
        var lastProgress: Double = 0

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            var isFinished = false
            writerInput.requestMediaDataWhenReady(on: .global(qos: .userInitiated)) {
                guard !isFinished else { return }
                while writerInput.isReadyForMoreMediaData {
                    guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                        writerInput.markAsFinished()
                        isFinished = true
                        writer.finishWriting {
                            if reader.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: VideoConverterError.transcodingFailed(reader.error))
                            }
                        }
                        return
                    }

                    guard writerInput.isReadyForMoreMediaData else { continue }

                    writerInput.append(sampleBuffer)

                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let pct = min(pts.seconds / totalDuration, 1)
                    if pct - lastProgress >= 0.05 {
                        lastProgress = pct
                        DispatchQueue.main.async { progress(pct) }
                    }
                }
            }
        }
    }

    private static func fourCCToString(_ fourCC: FourCharCode) -> String {
        let chars: [CChar] = [
            CChar((fourCC >> 24) & 0xFF),
            CChar((fourCC >> 16) & 0xFF),
            CChar((fourCC >> 8) & 0xFF),
            CChar(fourCC & 0xFF),
            0,
        ]
        return String(cString: chars).trimmingCharacters(in: .whitespaces)
    }
}

enum VideoConverterError: LocalizedError {
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
