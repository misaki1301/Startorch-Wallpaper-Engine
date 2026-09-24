import SwiftUI
import AVKit

/// Shown in the `.inspector` for whichever card is selected. A single click on a card only gets
/// you here — this is where "Set as Wallpaper" actually applies it.
struct WallpaperInspectorView: View {
    let item: WallpaperItem
    let isImported: Bool

    @Environment(WallpaperManager.self) private var manager
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var poster: NSImage?
    /// The poster's pixels, for the menu bar contrast check.
    @State private var posterImage: CGImage?
    @State private var previewPlayer: AVPlayer?
    @State private var isPreviewing = false
    @State private var metadata: VideoMetadata?

    private var isCurrent: Bool {
        manager.isShowing(item.url)
    }

    /// This wallpaper's dim, blur, vignette and speed; edits apply to the desktop immediately.
    private var readability: Binding<ReadabilitySettings> {
        Binding(
            get: { settings.readability(for: item.url) },
            set: { settings.setReadability($0, for: item.url) }
        )
    }

    private var contrast: MenuBarContrast.Analysis? {
        posterImage.flatMap {
            MenuBarContrast.analyze($0, screenHeight: NSScreen.main?.frame.height ?? 982, dim: readability.wrappedValue.dim)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                preview
                header
                details
                applyButton
                Divider()
                ReadabilityControls(readability: readability, contrast: contrast)
            }
            .padding()
        }
        .onChange(of: readability.wrappedValue.speed) { _, speed in
            previewPlayer?.defaultRate = Float(speed)
            if previewPlayer?.rate != 0 { previewPlayer?.rate = Float(speed) }
        }
        .onChange(of: item.url) { _, _ in stopPreview() }
        .onDisappear { stopPreview() }
        .task(id: item.url) {
            poster = nil
            posterImage = nil
            await loadPoster()
            metadata = try? await VideoConverter.metadata(for: item.url)
        }
    }

    /// The wallpaper on a miniature desktop, with this wallpaper's readability settings.
    private var preview: some View {
        DesktopPreview(
            poster: poster,
            player: isPreviewing ? previewPlayer : nil,
            readability: readability.wrappedValue,
            usesDarkMenuBarText: contrast?.usesDarkText ?? false
        )
        .overlay(alignment: .bottomTrailing) {
            Button(isPreviewing ? "Stop Preview" : "Play Preview", systemImage: isPreviewing ? "stop.fill" : "play.fill") {
                togglePreview()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(8)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.name)
                    .font(.title3.weight(.semibold))
                if isCurrent {
                    Label("Current", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.accentColor)
                        .help("Current")
                }
            }
            if let creator = item.creator {
                Text("Creator: \(creator)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let license = item.license {
                Text("License: \(license)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        if let metadata {
            VStack(alignment: .leading, spacing: 6) {
                detailRow("Resolution", "\(Int(metadata.resolution.width))×\(Int(metadata.resolution.height))")
                detailRow("Duration", formattedDuration(metadata.duration))
                detailRow("File Size", formatBytes(metadata.fileSize))
            }
            .padding(.top, 4)
        }
    }

    private func detailRow(_ titleKey: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(titleKey)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.callout)
    }

    private var applyButton: some View {
        Button {
            manager.start(with: item.url)
        } label: {
            Label("Set as Wallpaper", systemImage: "photo.on.rectangle.angled")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        // Still useful while it's only on some displays: it applies to all of them.
        .disabled(isCurrent && manager.assignments.assignments == DisplayAssignments(allDisplays: item.url))
        .accessibilityHint(Text("Double-click or press Return to set as wallpaper"))
    }

    private func togglePreview() {
        guard !reduceMotion else { return }
        if isPreviewing {
            stopPreview()
        } else {
            let player = AVPlayer(url: WallpaperCacheManager.resolvedURL(for: item.url))
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            // At the wallpaper's ambient speed, like on the desktop.
            player.defaultRate = Float(readability.wrappedValue.speed)
            previewPlayer = player
            isPreviewing = true
            player.play()
        }
    }

    private func stopPreview() {
        isPreviewing = false
        previewPlayer?.pause()
        previewPlayer = nil
    }

    private func loadPoster() async {
        let asset = AVAsset(url: item.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 500)
        if let cgImage = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 1)).image {
            poster = NSImage(cgImage: cgImage, size: .zero)
            posterImage = cgImage
        }
    }

    private func formattedDuration(_ time: CMTime) -> String {
        let seconds = time.seconds.isFinite ? time.seconds : 0
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: seconds) ?? "--:--"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
