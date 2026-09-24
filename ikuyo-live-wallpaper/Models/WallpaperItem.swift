import Foundation

struct WallpaperItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    var creator: String?
    var license: String?

    init(url: URL, name: String? = nil, creator: String? = nil, license: String? = nil) {
        self.id = url.absoluteString
        self.url = url
        self.name = name ?? url.deletingPathExtension().lastPathComponent
            .replacing("_", with: " ")
            .replacing("-", with: " ")
            .capitalized
        self.creator = creator
        self.license = license
    }
}
