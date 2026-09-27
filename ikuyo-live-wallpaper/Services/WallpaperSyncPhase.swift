import Foundation

/// A compact, UI-facing summary of where an auto-synced export stands. `WallpaperExtensionExporter`
/// and `ScreenSaverExporter` each expose their own `syncPhase`, computed from their existing
/// `status`/`isExporting`/error state (no new storage, so the old APIs keep working unchanged).
///
/// `.waitingForDownload` isn't one of those two states — only `ExportCoordinator` knows a remote
/// wallpaper hasn't finished downloading yet — so the coordinator overlays it in front of the
/// exporter's own phase (see `ExportCoordinator.systemWallpaperSyncPhase` /
/// `screenSaverSyncPhase`), giving the UI the full five-state picture described in the task.
nonisolated enum WallpaperSyncPhase: Equatable, Sendable {
    case idle
    case waitingForDownload
    case syncing
    case upToDate(Date)
    case failed(String)

    var statusText: String {
        switch self {
        case .idle: String(localized: "Not synced yet")
        case .waitingForDownload: String(localized: "Waiting for download…")
        case .syncing: String(localized: "Syncing…")
        case .upToDate(let date): String(localized: "Up to date (\(date.formatted(date: .abbreviated, time: .shortened)))")
        case .failed(let message): String(localized: "Sync failed: \(message)")
        }
    }
}
