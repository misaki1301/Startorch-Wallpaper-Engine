import SwiftUI

struct ContentView: View {

    var body: some View {
        NavigationSplitView {
            List {
                Section("Wallpapers") {
                    NavigationLink {
                        WallpaperGalleryView()
                    } label: {
                        Label("Gallery", systemImage: "square.grid.2x2")
                    }
                    NavigationLink {
                        FavoritesView()
                    } label: {
                        Label("Favorites", systemImage: "heart")
                    }
                }

                Section("Local") {
                    NavigationLink {
                        ImportedWallpaperView()
                    } label: {
                        Label("My Files", systemImage: "folder")
                    }
                }

                Section("Configuration") {
                    NavigationLink {
                        ConfigurationView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)

        } detail: {
            Text("Select an item")
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                PlaybackControls()
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(WallpaperManager())
        .environment(AppSettings())
        .environment(WallpaperLibrary())
        .environment(WallpaperCacheManager())
        .environment(ImportedWallpaperStore())
}
