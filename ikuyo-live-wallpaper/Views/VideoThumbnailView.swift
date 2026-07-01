import SwiftUI
import AVKit

struct VideoThumbnailView: View {
    let url: URL
    let isActive: Bool
    @State private var thumbnail: NSImage?
    @State private var isLoading = true
    @State private var failed = false

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
            .overlay(alignment: .topTrailing) {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .padding(6)
                        .symbolEffect(.appear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isActive ? Color.green : Color.gray.opacity(0.3), lineWidth: isActive ? 2 : 0.5)
            )
            .contentShape(.rect)
            .task {
                await loadThumbnail()
            }
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
    VideoThumbnailView(url: URL(string: "https://cdn.donmai.us/original/44/2a/442a58406a379375c3ff4c8d676b8c19.mp4")!, isActive: false)
}
