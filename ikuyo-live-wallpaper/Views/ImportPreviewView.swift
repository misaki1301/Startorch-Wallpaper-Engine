import SwiftUI
import AVKit

/// The import studio: preview a new video, trim it, optionally crossfade the loop seam, pick a
/// poster frame and a focal point, choose a quality preset (or keep the original file), then
/// export. `onComplete` receives the finished file; the studio's choices ride along as
/// `ImportStudioSidecar` files next to it, which `ImportedWallpaperStore` adopts.
@MainActor
struct ImportPreviewView: View {
    let sourceURL: URL
    /// More files waiting behind this one in the import queue, shown so a multi-file drop
    /// doesn't look like it silently dropped the rest.
    var remainingCount: Int = 0
    let onComplete: (URL, String) -> Void
    let onCancel: () -> Void

    @State private var previewPlayer: ImportPreviewPlayer?
    @State private var metadata: VideoMetadata?
    @State private var wallpaperName: String = ""
    @State private var trim = TrimSelection(duration: 0)
    @State private var loopEnabled = false
    @State private var crossfade = LoopCompositionPlan.defaultCrossfade
    @State private var preset = ExportQualityPreset.default
    @State private var keepOriginal = false
    @State private var posterTime: Double?
    @State private var focalPoint: FocalPoint?
    @State private var isEditingFocalPoint = false
    @State private var isPreparingSeam = false
    @State private var isConverting = false
    @State private var conversionProgress: Double = 0
    @State private var conversionError: String?
    @State private var conversionTask: Task<Void, Never>?
    @State private var isDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let error = conversionError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(error)
                        .foregroundStyle(.secondary)
                    Button("OK") { onCancel() }
                }
                .padding()
                Spacer()
            } else if isConverting {
                VStack(spacing: 16) {
                    ProgressView(value: conversionProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 280)
                    Text("\(Int(conversionProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Group {
                        if usesOriginal {
                            Text("Importing…")
                        } else {
                            Text("Exporting (\(preset.title))…")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    Button("Cancel", role: .cancel) { cancelConversion() }
                        .keyboardShortcut(.escape)
                }
                .padding()
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        previewSection
                        if duration > 0 {
                            timelineSection
                            loopSection
                        }
                        nameField
                        qualitySection
                        if let metadata {
                            comparisonTable(metadata)
                        }
                    }
                    .padding()
                }

                Divider()
                footerView
            }
        }
        .frame(width: 640, height: 740)
        .onAppear {
            if previewPlayer == nil {
                let player = ImportPreviewPlayer(url: sourceURL)
                player.play()
                previewPlayer = player
            }
            Task {
                await loadMetadata()
            }
        }
        .onDisappear {
            isDismissed = true
            previewPlayer?.invalidate()
            conversionTask?.cancel()
        }
        .onChange(of: trim) { _, newTrim in
            previewPlayer?.setRange(newTrim.start...newTrim.end)
        }
        .onChange(of: effectiveCrossfade) { _, _ in
            previewPlayer?.leaveSeamPreview()
        }
        .onChange(of: hasTimelineEdits) { _, edited in
            if edited { keepOriginal = false }
        }
    }

    // MARK: - Derived state

    private var duration: Double {
        guard let seconds = metadata?.duration.seconds, seconds.isFinite else { return 0 }
        return max(0, seconds)
    }

    private var effectiveCrossfade: Double {
        guard loopEnabled else { return 0 }
        return LoopCompositionPlan.effectiveCrossfade(requested: crossfade, clipDuration: trim.length)
    }

    /// Trimming or looping needs a render, so "Keep Original" isn't possible.
    private var hasTimelineEdits: Bool {
        trim.isTrimmed || effectiveCrossfade > 0
    }

    private var usesOriginal: Bool {
        keepOriginal && !hasTimelineEdits
    }

    private var edit: ImportEdit {
        ImportEdit(trim: trim.timeRange, crossfade: effectiveCrossfade, preset: preset)
    }

    private var outputSeconds: Double {
        max(0, trim.length - effectiveCrossfade)
    }

    private var outputSettings: ExportOutputSettings? {
        guard let metadata else { return nil }
        return preset.outputSettings(
            sourceSize: metadata.displaySize,
            sourceFrameRate: metadata.frameRate,
            sourceBitrate: metadata.bitrate
        )
    }

    private var screenAspect: CGFloat {
        guard let frame = NSScreen.main?.frame, frame.height > 0 else { return 16 / 10 }
        return frame.width / frame.height
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 2) {
            Text("Import Video")
                .font(.headline)
            if remainingCount > 0 {
                Text("^[\(remainingCount) more video](inflect: true) waiting")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var previewSection: some View {
        if let previewPlayer {
            VStack(spacing: 8) {
                StudioPreviewView(
                    player: previewPlayer.player,
                    videoSize: metadata?.displaySize ?? .zero,
                    focalPoint: $focalPoint,
                    isEditingFocalPoint: isEditingFocalPoint,
                    screenAspect: screenAspect
                )
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) { previewBadge(previewPlayer) }

                transportBar(previewPlayer)
            }
        }
    }

    @ViewBuilder
    private func previewBadge(_ player: ImportPreviewPlayer) -> some View {
        if case .seam = player.mode {
            Label("Loop seam preview", systemImage: "repeat")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
        } else if isEditingFocalPoint {
            Text("Click or drag to set the focal point. The dashed box is what this display shows.")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
        }
    }

    private func transportBar(_ player: ImportPreviewPlayer) -> some View {
        HStack(spacing: 10) {
            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
            }
            .accessibilityLabel(player.isPlaying ? Text("Pause") : Text("Play"))

            if player.mode == .clip {
                Text(TrimTimelineView.timestamp(player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Button("Back to Clip") { player.leaveSeamPreview() }
                    .font(.caption)
            }

            Spacer()

            Button {
                posterTime = trim.clamp(player.currentTime)
            } label: {
                Label("Use as Poster", systemImage: "photo")
            }
            .disabled(player.mode != .clip || duration == 0)
            .help("Use the frame under the playhead as this wallpaper's poster")
            if posterTime != nil {
                Button {
                    posterTime = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text("Clear Poster"))
                .help("Clear the poster frame")
            }

            Toggle(isOn: $isEditingFocalPoint) {
                Label("Focal Point", systemImage: "scope")
            }
            .toggleStyle(.button)
            .help("Pick what stays on screen when the video is cropped to fit a display")

            Button {
                previewSeam()
            } label: {
                if isPreparingSeam {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Preview Seam", systemImage: "repeat")
                }
            }
            .disabled(isPreparingSeam || duration == 0)
            .help("Play the second before and after the loop point")
        }
        .controlSize(.small)
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TrimTimelineView(
                sourceURL: sourceURL,
                duration: duration,
                trim: $trim,
                playhead: previewPlayer?.currentTime ?? 0,
                posterTime: posterTime,
                crossfade: effectiveCrossfade,
                onScrub: { seconds in previewPlayer?.seek(to: seconds) }
            )
            HStack {
                Text("In \(TrimTimelineView.timestamp(trim.start))")
                Text("Out \(TrimTimelineView.timestamp(trim.end))")
                Text("Length \(TrimTimelineView.timestamp(trim.length))")
                Spacer()
                if trim.isTrimmed {
                    Button("Reset Trim") { trim.reset() }
                        .buttonStyle(.link)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var loopSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Seamless loop", isOn: $loopEnabled)
            if loopEnabled {
                let maximum = max(LoopCompositionPlan.minimumCrossfade, LoopCompositionPlan.maximumCrossfade(clipDuration: trim.length))
                HStack {
                    Text("Crossfade")
                        .foregroundStyle(.secondary)
                    Slider(
                        value: $crossfade,
                        in: LoopCompositionPlan.minimumCrossfade...max(maximum, LoopCompositionPlan.minimumCrossfade + 0.01)
                    )
                    .accessibilityValue(Text("\(effectiveCrossfade, specifier: "%.2f") seconds"))
                    Text("\(effectiveCrossfade, specifier: "%.2f") s")
                        .font(.caption.monospacedDigit())
                        .frame(width: 48, alignment: .trailing)
                }
                Group {
                    if effectiveCrossfade > 0 {
                        Text("The last \(effectiveCrossfade, specifier: "%.2f") s fade into the first, so the loop has no visible jump. The result is that much shorter.")
                    } else {
                        Text("This clip is too short for a crossfade.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var nameField: some View {
        HStack {
            Text("Name")
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            TextField("Wallpaper name", text: $wallpaperName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Quality", selection: $preset) {
                ForEach(ExportQualityPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .disabled(usesOriginal)

            Text(usesOriginal ? "The file is imported exactly as it is." : preset.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Keep original file (no conversion)", isOn: $keepOriginal)
                .disabled(hasTimelineEdits)
            if hasTimelineEdits {
                Text("Trimming or looping needs a conversion, so the original file can't be kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func comparisonTable(_ meta: VideoMetadata) -> some View {
        let settings = outputSettings
        let size = meta.displaySize == .zero ? meta.resolution : meta.displaySize
        let outputSize = usesOriginal ? size : (settings?.renderSize ?? size)
        let sourceRate = VideoConverter.effectiveFrameRate(meta.frameRate)
        let outputRate = usesOriginal ? sourceRate : (settings?.frameRate ?? sourceRate)
        let outputBytes = usesOriginal ? meta.fileSize : (settings?.estimatedFileSize(seconds: outputSeconds) ?? 0)

        return VStack(alignment: .leading, spacing: 0) {
            Text("Video Details")
                .font(.subheadline.weight(.semibold))
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                compareRow(
                    label: "Format",
                    original: meta.codec,
                    converted: usesOriginal ? meta.codec : "HEVC (H.265)"
                )
                Divider().padding(.leading, 100)
                compareRow(
                    label: "Resolution",
                    original: "\(Int(size.width))×\(Int(size.height))",
                    converted: "\(Int(outputSize.width))×\(Int(outputSize.height))"
                )
                Divider().padding(.leading, 100)
                compareRow(
                    label: "Frame Rate",
                    original: Self.formatFrameRate(sourceRate),
                    converted: Self.formatFrameRate(outputRate)
                )
                Divider().padding(.leading, 100)
                compareRow(
                    label: "Duration",
                    original: TrimTimelineView.timestamp(duration),
                    converted: TrimTimelineView.timestamp(usesOriginal ? duration : outputSeconds)
                )
                Divider().padding(.leading, 100)
                compareRow(
                    label: "File Size",
                    original: formatBytes(meta.fileSize),
                    // The converted size is only ever an estimate until conversion finishes.
                    converted: usesOriginal ? formatBytes(meta.fileSize) : "≈\(formatBytes(outputBytes))"
                )
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func compareRow(label: LocalizedStringKey, original: String, converted: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(original)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(converted)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footerView: some View {
        HStack {
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.escape)
            Spacer()
            Button(usesOriginal ? "Import" : "Import & Convert") { startImport() }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(wallpaperName.trimmingCharacters(in: .whitespaces).isEmpty || metadata == nil)
        }
        .padding()
    }

    // MARK: - Actions

    private func loadMetadata() async {
        wallpaperName = sourceURL.deletingPathExtension().lastPathComponent
            .replacing("_", with: " ")
            .replacing("-", with: " ")
            .capitalized
        metadata = try? await VideoConverter.metadata(for: sourceURL)
        trim = TrimSelection(duration: duration)
    }

    private func previewSeam() {
        guard let previewPlayer else { return }
        isPreparingSeam = true
        let edit = edit
        let sourceURL = sourceURL
        Task {
            defer { isPreparingSeam = false }
            do {
                let composition = try await VideoConverter.makeComposition(source: sourceURL, edit: edit)
                guard !isDismissed else { return }
                previewPlayer.previewSeam(of: composition)
            } catch {
                // The seam preview is a nicety; the import itself can still go ahead.
                NSSound.beep()
            }
        }
    }

    private func startImport() {
        previewPlayer?.pause()
        isEditingFocalPoint = false
        let name = wallpaperName.trimmingCharacters(in: .whitespaces)
        let studio = ImportStudioMetadata(
            focalPoint: focalPoint,
            posterTime: posterTime.map(trim.clamp),
            preset: usesOriginal ? nil : preset,
            trimStart: trim.isTrimmed ? trim.start : nil,
            trimEnd: trim.isTrimmed ? trim.end : nil,
            crossfade: effectiveCrossfade > 0 ? effectiveCrossfade : nil
        )
        let sourceURL = sourceURL

        // "Keep Original" skips transcoding entirely: just copy the source next to the other
        // imports, keeping its own container/codec.
        let copyOriginal = usesOriginal
        let edit = edit
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(copyOriginal ? sourceURL.pathExtension : "mp4")

        conversionProgress = 0
        isConverting = true
        conversionTask = Task {
            do {
                if copyOriginal {
                    try FileManager.default.copyItem(at: sourceURL, to: outputURL)
                } else {
                    try await VideoConverter.export(source: sourceURL, output: outputURL, edit: edit) { pct in
                        conversionProgress = pct
                    }
                }
                try Task.checkCancellation()
                await writeSidecars(studio, for: outputURL)
                onComplete(outputURL, name)
            } catch is CancellationError {
                // The converter already removed the partial output; go back to the form.
                try? FileManager.default.removeItem(at: outputURL)
                isConverting = false
            } catch {
                conversionError = error.localizedDescription
            }
            conversionTask = nil
        }
    }

    /// Leaves the poster and studio metadata next to `outputURL` for the store to adopt. Both
    /// are extras: failing to write them never fails the import.
    private func writeSidecars(_ studio: ImportStudioMetadata, for outputURL: URL) async {
        if let posterTime = studio.posterTime {
            try? await VideoConverter.writePosterFrame(
                of: sourceURL,
                at: posterTime,
                to: ImportStudioSidecar.pendingPosterURL(for: outputURL)
            )
        }
        if !studio.isEmpty {
            try? ImportStudioSidecar.writePendingMetadata(studio, for: outputURL)
        }
    }

    private func cancelConversion() {
        conversionTask?.cancel()
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private static func formatFrameRate(_ fps: Float) -> String {
        fps.rounded() == fps ? "\(Int(fps)) fps" : String(format: "%.2f fps", fps)
    }
}
