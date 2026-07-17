import SwiftUI

struct WallpaperGalleryView: View {
    let items: [WallpaperItem]
    @Environment(WallpaperManager.self) private var manager
    @Environment(WallpaperCacheManager.self) private var cacheManager
    @State private var favoriteURLs: Set<String>

    init(items: [WallpaperItem]) {
        self.items = items
        self._favoriteURLs = State(initialValue: Set(UserDefaults.standard.stringArray(forKey: "favoriteWallpapers") ?? []))
    }

    private var sortedItems: [WallpaperItem] {
        items.sorted { lhs, rhs in
            let lFav = favoriteURLs.contains(lhs.url.absoluteString)
            let rFav = favoriteURLs.contains(rhs.url.absoluteString)
            if lFav != rFav { return lFav }
            return lhs.name < rhs.name
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 16) {
                ForEach(sortedItems) { item in
                    videoCard(for: item)
                }
            }
            .padding()
        }
        .navigationTitle("Gallery")
    }

    private func videoCard(for item: WallpaperItem) -> some View {
        VideoThumbnailView(
            url: item.url,
            name: item.name,
            isActive: manager.isActive && manager.currentURL == item.url,
            downloadState: cacheManager.states[item.url],
            isFavorite: Binding(
                get: { favoriteURLs.contains(item.url.absoluteString) },
                set: { toggleFavorite(item.url, $0) }
            )
        )
        .onTapGesture {
            manager.start(with: item.url)
        }
        .contextMenu {
            Button("Set as Wallpaper") { manager.start(with: item.url) }
            Button("Preview") { NSWorkspace.shared.open(item.url) }
            Divider()
            Button(favoriteURLs.contains(item.url.absoluteString) ? "Remove from Favorites" : "Add to Favorites") {
                toggleFavorite(item.url)
            }
        }
    }

    private func saveFavorites() {
        UserDefaults.standard.set(Array(favoriteURLs), forKey: "favoriteWallpapers")
    }

    private func toggleFavorite(_ url: URL, _ force: Bool? = nil) {
        let key = url.absoluteString
        if let force {
            if force { favoriteURLs.insert(key); cacheManager.startDownload(url) }
            else { favoriteURLs.remove(key); cacheManager.removeCache(for: url) }
        } else {
            if favoriteURLs.contains(key) { favoriteURLs.remove(key); cacheManager.removeCache(for: url) }
            else { favoriteURLs.insert(key); cacheManager.startDownload(url) }
        }
        saveFavorites()
    }
}

#Preview {
    WallpaperGalleryView(items: [
        "https://cdn.donmai.us/original/b6/b9/b6b9d3154ebac86ca2cd80b47c2e856c.mp4",
        "https://cdn.donmai.us/original/53/33/5333f37fb7e84233bb75373f281c52ba.mp4",
        "https://cdn.donmai.us/original/fb/2b/fb2baba32375a5509e67b67a63a86abe.mp4",
        "https://cdn.donmai.us/original/d7/61/d761ec22b6363c0b080fd7677b1d18f1.mp4",
        "https://cdn.donmai.us/original/e3/32/e33241733467d072822890348aa62f48.mp4",
        "https://cdn.donmai.us/original/44/2a/442a58406a379375c3ff4c8d676b8c19.mp4",
    ].compactMap(URL.init(string:)).map({ WallpaperItem(url: $0) }))
    .environment(WallpaperManager())
    .environment(WallpaperCacheManager())
    .frame(width: 800, height: 600)
}
