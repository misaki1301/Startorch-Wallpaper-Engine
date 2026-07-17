import Foundation

struct WallpaperItem: Identifiable {
    let id: String
    let url: URL
    let name: String

    init(url: URL, name: String? = nil) {
        self.id = url.absoluteString
        self.url = url
        self.name = name ?? url.deletingPathExtension().lastPathComponent
            .replacing("_", with: " ")
            .replacing("-", with: " ")
            .capitalized
    }
}
