import SwiftUI
import AVKit

struct VideoThumbnailView: View {
    let url: URL
    let name: String
    let isActive: Bool
    let downloadState: DownloadState?
    let hideDownloadBadge: Bool
    @Binding var isFavorite: Bool
    @State private var thumbnail: NSImage?
    @State private var isLoading = true
    @State private var failed = false

    init(url: URL, name: String, isActive: Bool, downloadState: DownloadState?, hideDownloadBadge: Bool = false, isFavorite: Binding<Bool>) {
        self.url = url
        self.name = name
        self.isActive = isActive
        self.downloadState = downloadState
        self.hideDownloadBadge = hideDownloadBadge
        self._isFavorite = isFavorite
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.fill.quaternary)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if failed {
                    Image(systemName: "video.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .overlay(alignment: .topLeading) {
                Button("Favorite", systemImage: isFavorite ? "heart.fill" : "heart") {
                    isFavorite.toggle()
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(isFavorite ? .red : .white)
                .shadow(radius: 2)
                .padding(6)
                .symbolEffect(.bounce, value: isFavorite)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    downloadBadge
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .symbolEffect(.appear)
                    }
                }
                .padding(6)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.7), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 48)
                .overlay(alignment: .bottomLeading) {
                    Text(name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
            .contentShape(.rect)
            .task {
                await loadThumbnail()
            }
    }

    @ViewBuilder
    private var downloadBadge: some View {
        if hideDownloadBadge {
            EmptyView()
        } else {
            switch downloadState ?? .notStarted {
            case .downloading:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .shadow(radius: 1)
            case .completed:
                Image(systemName: "icloud.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
            case .failed:
                Image(systemName: "exclamationmark.icloud")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .shadow(radius: 1)
            case .notStarted:
                EmptyView()
            }
        }
    }

    private var borderColor: Color {
        if isActive { .green }
        else if isFavorite { .yellow }
        else { .gray.opacity(0.3) }
    }

    private var borderWidth: CGFloat {
        isActive || isFavorite ? 2 : 0.5
    }

    private func loadThumbnail() async {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 225)
        do {
            let cgImage = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 1)).image
            thumbnail = NSImage(cgImage: cgImage, size: .zero)
        } catch {
            failed = true
        }
        isLoading = false
    }
}

#Preview {
    VideoThumbnailView(
        url: URL(string: "https://cdn.donmai.us/original/44/2a/442a58406a379375c3ff4c8d676b8c19.mp4")!,
        name: "Sample Video",
        isActive: false,
        downloadState: nil,
        isFavorite: .constant(false)
    )
    .frame(width: 300)
    .padding()
}
