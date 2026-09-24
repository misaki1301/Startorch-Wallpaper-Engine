import Foundation

/// A user-created, named group of wallpapers — catalog items or imported files — stored as their
/// URLs so it survives catalog refreshes without duplicating `WallpaperItem` metadata.
struct WallpaperCollection: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var itemURLs: [URL]
    var shuffle: ShuffleSettings?

    init(id: UUID = UUID(), name: String, itemURLs: [URL] = [], shuffle: ShuffleSettings? = nil) {
        self.id = id
        self.name = name
        self.itemURLs = itemURLs
        self.shuffle = shuffle
    }
}

/// How often a collection rotates to a new wallpaper while it is the active source, and whether
/// that rotation currently runs. `.onWake`/`.onLaunch` don't tick on a timer; `ScheduleService`
/// fires them from the matching system event instead.
struct ShuffleSettings: Codable, Hashable {
    enum Interval: Codable, Hashable {
        case minutes(Int)
        case hours(Int)
        case daily
        case onWake
        case onLaunch
    }

    var interval: Interval
    var isEnabled: Bool = true

    /// The fixed-cadence intervals' length; `nil` for the event-driven ones.
    var timeInterval: TimeInterval? {
        switch interval {
        case .minutes(let minutes): return TimeInterval(minutes * 60)
        case .hours(let hours): return TimeInterval(hours * 3600)
        case .daily: return 24 * 3600
        case .onWake, .onLaunch: return nil
        }
    }
}
