import SwiftUI

struct FavoritesView: View {
    @Environment(WallpaperLibrary.self) private var library
    @Environment(WallpaperManager.self) private var manager
    @Environment(WallpaperCacheManager.self) private var cacheManager

    private var favoritedItems: [WallpaperItem] {
        library.favoriteCatalogItems
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
                set: { library.setFavorite($0, for: item.url) }
            )
        )
        .onTapGesture {
            manager.start(with: item.url)
        }
        .contextMenu {
            Button("Set as Wallpaper") { manager.start(with: item.url) }
            Button("Preview") { NSWorkspace.shared.open(item.url) }
            Divider()
            Button("Remove from Favorites") { library.setFavorite(false, for: item.url) }
        }
    }
}

#Preview {
    FavoritesView()
        .environment(WallpaperLibrary())
        .environment(WallpaperManager())
        .environment(WallpaperCacheManager())
        .frame(width: 800, height: 600)
}
