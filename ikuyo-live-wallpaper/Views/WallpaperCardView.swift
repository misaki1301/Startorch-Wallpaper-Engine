import SwiftUI
import AVKit

/// One wallpaper in a grid. A single click only selects the card (see `onSelect`); applying it
/// takes a double-click, Return while focused, or the context menu / inspector button
/// (`onApply`) — nothing here changes the desktop picture by itself.
///
/// State (current / favorite / offline) is always shown with an icon and a word, never color
/// alone, so it reads the same with Increase Contrast, Reduce Transparency, or for anyone who
/// can't see color.
struct WallpaperCardView: View {
    let item: WallpaperItem
    let isActive: Bool
    let isSelected: Bool
    let isFavorite: Bool
    let downloadState: DownloadState?
    let hideDownloadBadge: Bool
    let onSelect: () -> Void
    let onApply: () -> Void
    let onToggleFavorite: () -> Void
    var trailingBadge: (() -> AnyView)? = nil

    @State private var thumbnail: NSImage?
    @State private var failedThumbnail = false
    @State private var isHovering = false
    @State private var previewPlayer: AVPlayer?
    @State private var energyScore: EnergyScore?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Button(action: onSelect) {
            cardBody
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { onApply() })
        .onKeyPress(.return) {
            onApply()
            return .handled
        }
        .contentShape(.rect)
        .onHover { hovering in
            isHovering = hovering
            updatePreviewPlayback(hovering: hovering)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text("Double-click or press Return to set as wallpaper"))
        .accessibilityAction(named: Text("Set as Wallpaper"), onApply)
        .task(id: item.url) {
            await loadThumbnail()
        }
        .task(id: item.id) {
            energyScore = await EnergyScoreResolver.shared.score(for: item)
        }
    }

    private var accessibilityLabel: String {
        var parts = [item.name]
        if isActive { parts.append(String(localized: "Current", defaultValue: "Current wallpaper")) }
        if isFavorite { parts.append(String(localized: "Favorite", defaultValue: "Favorite")) }
        if case .completed = downloadState ?? .notStarted, !hideDownloadBadge {
            parts.append(String(localized: "Available Offline", defaultValue: "Available offline"))
        }
        if let energyScore { parts.append(energyScore.label) }
        return parts.joined(separator: ", ")
    }

    private var cardBody: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.fill.quaternary)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay { posterOrPreview }
                .overlay(alignment: .topLeading) { favoriteButton }
                .overlay(alignment: .topTrailing) { statusBadges }
                .overlay(alignment: .bottom) { nameOverlay }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.25), lineWidth: isSelected ? 3 : 0.5)
        )
    }

    @ViewBuilder
    private var posterOrPreview: some View {
        if isHovering, !reduceMotion, let previewPlayer {
            VideoPlayer(player: previewPlayer)
                .disabled(true)
                .allowsHitTesting(false)
        } else if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if failedThumbnail {
            Image(systemName: "video.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
        } else {
            ProgressView()
        }
    }

    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .foregroundStyle(isFavorite ? .red : .white)
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .labelStyle(.iconOnly)
        .padding(6)
        .symbolEffect(.bounce, value: isFavorite)
        .accessibilityLabel(Text(isFavorite ? "Remove from Favorites" : "Add to Favorites"))
        .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
    }

    @ViewBuilder
    private var statusBadges: some View {
        HStack(spacing: 4) {
            if let energyScore {
                EnergyBadgeView(score: energyScore)
            }
            downloadBadge
            if let trailingBadge {
                trailingBadge()
            }
            if isActive {
                Label("Current", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
                    .help("Current")
            }
        }
        .padding(6)
    }

    @ViewBuilder
    private var downloadBadge: some View {
        if hideDownloadBadge {
            EmptyView()
        } else {
            switch downloadState ?? .notStarted {
            case .downloading(let progress):
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .help(Text("Downloading… \(Int(progress * 100))%"))
                    .tint(.white)
                    .shadow(radius: 1)
            case .completed:
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .help("Available Offline")
            case .failed:
                Image(systemName: "exclamationmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .shadow(radius: 1)
                    .help("Download failed")
            case .notStarted:
                EmptyView()
            }
        }
    }

    private var nameOverlay: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(reduceTransparency ? 0.9 : 0.7), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 48)
        .overlay(alignment: .bottomLeading) {
            Text(item.name)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
    }

    private func loadThumbnail() async {
        let asset = AVAsset(url: item.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 250)
        do {
            let cgImage = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 1)).image
            thumbnail = NSImage(cgImage: cgImage, size: .zero)
        } catch {
            failedThumbnail = true
        }
    }

    private func updatePreviewPlayback(hovering: Bool) {
        guard !reduceMotion else { return }
        if hovering {
            if previewPlayer == nil {
                let player = AVPlayer(url: item.url)
                player.isMuted = true
                previewPlayer = player
            }
            previewPlayer?.play()
        } else {
            previewPlayer?.pause()
            previewPlayer?.seek(to: .zero)
        }
    }
}

#Preview {
    WallpaperCardView(
        item: WallpaperItem(url: URL(string: "https://example.com/sample.mp4")!),
        isActive: false,
        isSelected: false,
        isFavorite: false,
        downloadState: nil,
        hideDownloadBadge: false,
        onSelect: {},
        onApply: {},
        onToggleFavorite: {}
    )
    .frame(width: 300)
    .padding()
}
