import SwiftUI
import AVKit

struct ImportPreviewView: View {
    let sourceURL: URL
    let onComplete: (URL, String) -> Void
    let onCancel: () -> Void

    @State private var metadata: VideoMetadata?
    @State private var player: AVPlayer?
    @State private var wallpaperName: String = ""
    @State private var isConverting = false
    @State private var conversionProgress: Double = 0
    @State private var conversionError: String?

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
                }
                .padding()
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        videoPreview
                        nameField
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
            Task {
                try? await loadMetadata()
            }
        })
        .onDisappear { player?.pause() }
    }

    private var header: some View {
        Text("Import Video")
            .font(.headline)
            .padding()
    }

    private var videoPreview: some View {
        VideoPlayer(player: player)
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear {
                let p = AVPlayer(url: sourceURL)
                p.isMuted = true
                p.play()
                player = p
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

    private func comparisonTable(_ meta: VideoMetadata) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Video Details")
                .font(.subheadline.weight(.semibold))
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                compareRow(label: "Format", original: meta.codec, converted: "HEVC (H.265)")
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
                    converted: formatBytes(meta.estimatedHEVCSize)
                )
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func compareRow(label: String, original: String, converted: String) -> some View {
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
            Button("Import & Convert") { startConversion() }
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

    private func startConversion() {
        player?.pause()
        player = nil
        isConverting = true
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        Task {
            do {
                try await VideoConverter.transcodeToHEVC(source: sourceURL, output: outputURL) { pct in
                    conversionProgress = pct
                }
                await MainActor.run {
                    onComplete(outputURL, wallpaperName.trimmingCharacters(in: .whitespaces))
                }
            } catch {
                await MainActor.run {
                    conversionError = error.localizedDescription
                }
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
