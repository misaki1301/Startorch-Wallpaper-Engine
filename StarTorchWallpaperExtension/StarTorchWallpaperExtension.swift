import ExtensionFoundation
import Foundation

/// The StarTorch wallpaper extension: WallpaperAgent launches it (it is never launched by the
/// app) when "StarTorch" is the chosen wallpaper in System Settings › Wallpaper, then asks it to
/// draw into remote layer contexts on the desktop and the lock screen.
///
/// Structure — ported from the owner's prototype (WallpaperAppWallpaperExtension), with the web
/// renderer replaced by a video renderer:
/// - `Private/` — the only private/reverse-engineered code: the XPC protocol shapes, the
///   connection handler, and the settings payload (see the notice in WallpaperHostBridge.swift).
/// - `VideoWallpaperRenderer` — AVFoundation layers, public API only.
/// - `WallpaperContentSource` — reads what the app exported to the shared App Group container.
@main
final class StarTorchWallpaperExtension: AppExtension {
    required init() {
        // Before any connection: NSXPC must find the private payload classes to decode requests.
        _ = WallpaperPrivateRuntime.load()
    }

    var configuration: some AppExtensionConfiguration {
        WallpaperHostConfiguration()
    }
}
