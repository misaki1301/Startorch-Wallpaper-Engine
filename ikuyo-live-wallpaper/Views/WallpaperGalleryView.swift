import SwiftUI

struct WallpaperGalleryView: View {
    @Environment(WallpaperLibrary.self) private var library
    @Environment(WallpaperManager.self) private var manager
    @Environment(WallpaperCacheManager.self) private var cacheManager

    private var sortedItems: [WallpaperItem] {
        library.catalog.sorted { lhs, rhs in
            let lFav = library.isFavorite(lhs.url)
            let rFav = library.isFavorite(rhs.url)
            if lFav != rFav { return lFav }
            return lhs.name < rhs.name
        }
    }

    var body: some View {
        Group {
            if library.catalog.isEmpty {
                ContentUnavailableView(
                    "No Wallpapers Yet",
                    systemImage: "sparkles.tv",
                    description: Text("Import your own videos from My Files.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 16) {
                        ForEach(sortedItems) { item in
                            videoCard(for: item)
                        }
                    }
                    .padding()
                }
            }
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
                get: { library.isFavorite(item.url) },
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
            Button(library.isFavorite(item.url) ? "Remove from Favorites" : "Add to Favorites") {
                library.toggleFavorite(item.url)
            }
        }
    }
}

#Preview {
    WallpaperGalleryView()
        .environment(WallpaperLibrary())
        .environment(WallpaperManager())
        .environment(WallpaperCacheManager())
        .frame(width: 800, height: 600)
}
