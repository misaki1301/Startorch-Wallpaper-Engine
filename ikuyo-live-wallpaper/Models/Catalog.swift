import Foundation

/// The gallery manifest. See `catalog/README.md` for the schema and licensing rules.
struct Catalog: Codable, Equatable {
    var version: Int
    var wallpapers: [Entry]

    struct Entry: Codable, Equatable {
        var id: String
        var title: String
        var creator: String
        var license: String
        var url: URL
        var sourceURL: URL?
        var posterURL: URL?
        var duration: Double?
        var width: Int?
        var height: Int?
        var fps: Double?
        var bitrate: Int?
    }

    static let empty = Catalog(version: 1, wallpapers: [])

    var items: [WallpaperItem] {
        wallpapers.map { WallpaperItem(url: $0.url, name: $0.title, creator: $0.creator, license: $0.license) }
    }
}
