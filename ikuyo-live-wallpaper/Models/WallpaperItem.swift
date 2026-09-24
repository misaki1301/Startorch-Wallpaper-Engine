import Foundation

struct WallpaperItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    var creator: String?
    var license: String?
    /// Catalog-reported video metadata, when the manifest carries it (see `Catalog.Entry`).
    /// Imported and local files leave these `nil`; `EnergyScoreResolver` probes the file itself
    /// in that case instead of failing the badge.
    var width: Int?
    var height: Int?
    var fps: Double?
    var bitrate: Int?
    /// Import studio: a still chosen by the user, used instead of a frame grabbed from the
    /// video for thumbnails. Only imported wallpapers have one.
    var posterURL: URL?
    /// Import studio: what to keep on screen when the video is aspect-filled. `nil` = center.
    var focalPoint: FocalPoint?

    init(
        url: URL,
        name: String? = nil,
        creator: String? = nil,
        license: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fps: Double? = nil,
        bitrate: Int? = nil,
        posterURL: URL? = nil,
        focalPoint: FocalPoint? = nil
    ) {
        self.id = url.absoluteString
        self.url = url
        self.name = name ?? url.deletingPathExtension().lastPathComponent
            .replacing("_", with: " ")
            .replacing("-", with: " ")
            .capitalized
        self.creator = creator
        self.license = license
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.posterURL = posterURL
        self.focalPoint = focalPoint
    }
}
