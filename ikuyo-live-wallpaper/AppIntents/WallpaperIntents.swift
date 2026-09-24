import AppIntents

/// Thrown when an intent runs before `StarTorchApp.init()` has wired `WallpaperIntentBridge` —
/// in practice, only if the system somehow invokes one outside the app process.
enum WallpaperIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appNotReady

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: "StarTorch isn't ready yet. Open StarTorch and try again."
        }
    }
}

struct SetWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Wallpaper"
    static let description = IntentDescription("Starts a StarTorch wallpaper.")
    // Runs in the app process without bringing the window forward.
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Wallpaper")
    var wallpaper: WallpaperEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$wallpaper) as wallpaper")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let manager = WallpaperIntentBridge.manager else { throw WallpaperIntentError.appNotReady }
        manager.start(with: wallpaper.url)
        return .result(dialog: "Set \(wallpaper.name) as your wallpaper.")
    }
}

struct PauseWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Wallpaper"
    static let description = IntentDescription("Pauses the running StarTorch wallpaper.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let manager = WallpaperIntentBridge.manager else { throw WallpaperIntentError.appNotReady }
        manager.pause()
        return .result(dialog: "Paused StarTorch.")
    }
}

struct ResumeWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Wallpaper"
    static let description = IntentDescription("Resumes the StarTorch wallpaper, or starts the last one if nothing is running.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let manager = WallpaperIntentBridge.manager else { throw WallpaperIntentError.appNotReady }
        manager.play(orStart: WallpaperIntentBridge.settings?.availableLastWallpaperURL())
        return .result(dialog: "Resumed StarTorch.")
    }
}

struct StopWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Wallpaper"
    static let description = IntentDescription("Stops StarTorch and restores your desktop picture.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let manager = WallpaperIntentBridge.manager else { throw WallpaperIntentError.appNotReady }
        manager.stop()
        return .result(dialog: "Stopped StarTorch and restored your desktop picture.")
    }
}

struct NextFavoriteWallpaperIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Favorite Wallpaper"
    static let description = IntentDescription("Starts the next wallpaper in your Favorites list.")
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let manager = WallpaperIntentBridge.manager, let library = WallpaperIntentBridge.library else {
            throw WallpaperIntentError.appNotReady
        }
        let favorites = library.favoriteCatalogItems
        guard !favorites.isEmpty else {
            return .result(dialog: "You don't have any favorites yet.")
        }
        let currentIndex = favorites.firstIndex { $0.url == manager.currentURL }
        let nextIndex = currentIndex.map { favorites.index(after: $0) % favorites.count } ?? 0
        let next = favorites[nextIndex]
        manager.start(with: next.url)
        return .result(dialog: "Set \(next.name) as your wallpaper.")
    }
}

struct NextInCollectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Next in Collection"
    static let description = IntentDescription("Starts the next wallpaper in a StarTorch collection.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Collection")
    var collection: WallpaperCollectionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Set the next wallpaper in \(\.$collection)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let manager = WallpaperIntentBridge.manager, let library = WallpaperIntentBridge.library else {
            throw WallpaperIntentError.appNotReady
        }
        guard let id = UUID(uuidString: collection.id), let stored = library.collection(id) else {
            throw WallpaperIntentError.appNotReady
        }
        let urls = stored.itemURLs
        guard !urls.isEmpty else {
            return .result(dialog: "\(collection.name) doesn't have any wallpapers yet.")
        }
        let currentIndex = urls.firstIndex { $0 == manager.currentURL }
        let nextIndex = currentIndex.map { urls.index(after: $0) % urls.count } ?? 0
        let nextURL = urls[nextIndex]
        manager.start(with: nextURL)
        let name = (library.catalog + (WallpaperIntentBridge.importedStore?.items ?? []))
            .first { $0.url == nextURL }?.name ?? nextURL.deletingPathExtension().lastPathComponent
        return .result(dialog: "Set \(name) as your wallpaper.")
    }
}
