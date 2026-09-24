import SwiftUI
import AVKit

@MainActor
struct ImportPreviewView: View {
    let sourceURL: URL
    /// More files waiting behind this one in the import queue, shown so a multi-file drop
    /// doesn't look like it silently dropped the rest.
    var remainingCount: Int = 0
    let onComplete: (URL, String) -> Void
    let onCancel: () -> Void

    @State private var metadata: VideoMetadata?
    @State private var player: AVPlayer?
    @State private var wallpaperName: String = ""
    @State private var keepOriginal = false
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
                    Text("Converting to HEVC…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Cancel", role: .cancel) { cancelConversion() }
                        .keyboardShortcut(.escape)
                }
                .padding()
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        videoPreview
                        nameField
                        formatPicker
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
        .frame(width: 500, height: 600)
        .onAppear(perform: {
            startPreview()
            Task {
                try? await loadMetadata()
            }
        })
        .onDisappear {
            isDismissed = true
            player?.pause()
            conversionTask?.cancel()
        }
    }

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

    private var videoPreview: some View {
        PlayerView(player: player)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(height: 220)
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

    private var formatPicker: some View {
        Picker("Format", selection: $keepOriginal) {
            Text("Convert to HEVC").tag(false)
            Text("Keep Original").tag(true)
        }
        .pickerStyle(.segmented)
    }

    private func comparisonTable(_ meta: VideoMetadata) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Video Details")
                .font(.subheadline.weight(.semibold))
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                compareRow(
                    label: "Format",
                    original: meta.codec,
                    converted: keepOriginal ? meta.codec : "HEVC (H.265)"
                )
                Divider().padding(.leading, 100)
                compareRow(
                    label: "Resolution",
                    original: "\(Int(meta.resolution.width))×\(Int(meta.resolution.height))",
                    converted: "\(Int(meta.resolution.width))×\(Int(meta.resolution.height))"
                )
                Divider().padding(.leading, 100)
                compareRow(
                    label: "File Size",
                    original: formatBytes(meta.fileSize),
                    // The converted size is only ever an estimate until conversion finishes.
                    converted: keepOriginal ? formatBytes(meta.fileSize) : "≈\(formatBytes(meta.estimatedHEVCSize))"
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
            Button(keepOriginal ? "Import" : "Import & Convert") { startConversion() }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(wallpaperName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
    }

    private func loadMetadata() async throws {
        wallpaperName = sourceURL.deletingPathExtension().lastPathComponent
            .replacing("_", with: " ")
            .replacing("-", with: " ")
            .capitalized
        metadata = try? await VideoConverter.metadata(for: sourceURL)
    }

    private func startPreview() {
        let p = AVPlayer(url: sourceURL)
        p.isMuted = true
        p.play()
        player = p
    }

    private func startConversion() {
        player?.pause()
        player = nil
        let name = wallpaperName.trimmingCharacters(in: .whitespaces)

        // "Keep Original" skips transcoding entirely: just copy the source next to the other
        // imports, keeping its own container/codec.
        guard !keepOriginal else {
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(sourceURL.pathExtension)
            do {
                try FileManager.default.copyItem(at: sourceURL, to: outputURL)
                onComplete(outputURL, name)
            } catch {
                conversionError = error.localizedDescription
            }
            return
        }

        conversionProgress = 0
        isConverting = true
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        conversionTask = Task {
            do {
                try await VideoConverter.transcodeToHEVC(source: sourceURL, output: outputURL) { pct in
                    conversionProgress = pct
                }
                onComplete(outputURL, name)
            } catch is CancellationError {
                // The converter already removed the partial output; go back to the form.
                isConverting = false
                if !isDismissed { startPreview() }
            } catch {
                conversionError = error.localizedDescription
            }
            conversionTask = nil
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
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
