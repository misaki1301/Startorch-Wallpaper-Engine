import SwiftUI

struct WallpaperGalleryView: View {
    let urls: [URL]
    @Environment(WallpaperManager.self) private var manager

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 16) {
                ForEach(urls, id: \.self) { url in
                    VideoThumbnailView(
                        url: url,
                        isActive: (manager.isActive && manager.currentURL == url)
                    )
                    .onTapGesture {
                        manager.start(with: url)
                    }
                    .contextMenu {
                        Button("Set as Wallpaper") { manager.start(with: url) }
                        Button("Preview") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Wallpapers")
    }
}

#Preview {
    WallpaperGalleryView(urls: [
        "https://cdn.donmai.us/original/b6/b9/b6b9d3154ebac86ca2cd80b47c2e856c.mp4",
        "https://cdn.donmai.us/original/53/33/5333f37fb7e84233bb75373f281c52ba.mp4",
        "https://cdn.donmai.us/original/fb/2b/fb2baba32375a5509e67b67a63a86abe.mp4",
        "https://cdn.donmai.us/original/d7/61/d761ec22b6363c0b080fd7677b1d18f1.mp4",
        "https://cdn.donmai.us/original/e3/32/e33241733467d072822890348aa62f48.mp4",
        "https://cdn.donmai.us/original/44/2a/442a58406a379375c3ff4c8d676b8c19.mp4",
    ].compactMap(URL.init(string:)))
    .environment(WallpaperManager())
    .frame(width: 800, height: 600)
}
