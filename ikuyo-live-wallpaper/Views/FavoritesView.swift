import SwiftUI

struct FavoritesView: View {
    let items: [WallpaperItem]
    @Environment(WallpaperManager.self) private var manager
    @Environment(WallpaperCacheManager.self) private var cacheManager
    @State private var favoriteURLs: Set<String>

    init(items: [WallpaperItem]) {
        self.items = items
        self._favoriteURLs = State(initialValue: Set(UserDefaults.standard.stringArray(forKey: "favoriteWallpapers") ?? []))
    }

    private var favoritedItems: [WallpaperItem] {
        items.filter { favoriteURLs.contains($0.url.absoluteString) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        Group {
            if favoritedItems.isEmpty {
                ContentUnavailableView(
                    "No Favorites",
                    systemImage: "heart",
                    description: Text("Tap the heart icon on a wallpaper to add it here.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 16) {
                        ForEach(favoritedItems) { item in
                            videoCard(for: item)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Favorites")
    }

    private func videoCard(for item: WallpaperItem) -> some View {
        VideoThumbnailView(
            url: item.url,
            name: item.name,
            isActive: manager.isActive && manager.currentURL == item.url,
            downloadState: cacheManager.states[item.url],
            isFavorite: Binding(
                get: { true },
                set: { if !$0 { toggleFavorite(item.url) } }
            )
        )
        .onTapGesture {
            manager.start(with: item.url)
        }
        .contextMenu {
            Button("Set as Wallpaper") { manager.start(with: item.url) }
            Button("Preview") { NSWorkspace.shared.open(item.url) }
            Divider()
            Button("Remove from Favorites") { toggleFavorite(item.url) }
        }
    }

    private func saveFavorites() {
        UserDefaults.standard.set(Array(favoriteURLs), forKey: "favoriteWallpapers")
    }

    private func toggleFavorite(_ url: URL) {
        let key = url.absoluteString
        favoriteURLs.remove(key)
        cacheManager.removeCache(for: url)
        saveFavorites()
    }
}

#Preview {
    FavoritesView(items: [
        WallpaperItem(url: URL(string: "https://cdn.donmai.us/original/b6/b9/b6b9d3154ebac86ca2cd80b47c2e856c.mp4")!),
    ])
    .environment(WallpaperManager())
    .environment(WallpaperCacheManager())
    .frame(width: 800, height: 600)
}
