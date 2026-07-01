import SwiftUI

struct ContentView: View {

    private let wallpapers: [URL] = [
        "https://cdn.donmai.us/original/b6/b9/b6b9d3154ebac86ca2cd80b47c2e856c.mp4",
        "https://cdn.donmai.us/original/53/33/5333f37fb7e84233bb75373f281c52ba.mp4",
        "https://cdn.donmai.us/original/fb/2b/fb2baba32375a5509e67b67a63a86abe.mp4",
        "https://cdn.donmai.us/original/d7/61/d761ec22b6363c0b080fd7677b1d18f1.mp4",
        "https://cdn.donmai.us/original/e3/32/e33241733467d072822890348aa62f48.mp4",
        "https://cdn.donmai.us/original/44/2a/442a58406a379375c3ff4c8d676b8c19.mp4",
        "https://cdn.donmai.us/original/72/90/7290bf5d6f27c02995a60916881a4665.mp4",
        "https://videos.pexels.com/video-files/19841180/19841180-uhd_2560_1440_60fps.mp4",
        "https://cdn.donmai.us/original/28/00/28008134e9a521ee3166d27b36cf0201.mp4"
    ].compactMap(URL.init(string:))

    var body: some View {
        NavigationSplitView {
            List {
                Section("Wallpapers") {
                    NavigationLink {
                        WallpaperGalleryView(urls: wallpapers)
                    } label: {
                        Label("Gallery", systemImage: "square.grid.2x2")
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
    }
}

#Preview {
    ContentView()
}
