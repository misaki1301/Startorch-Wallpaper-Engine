import Foundation

/// Applies "Pause while this Focus is on" without ever fighting a pause the user set themselves.
///
/// `WallpaperManager.pause()`/`resume()` don't know who's asking, and `isPaused` is a single flag
/// shared by the user's own Play/Pause button and this filter. So this coordinator remembers,
/// itself, whether *it* was the one that paused: it only calls `resume()` on deactivation if it
/// was, meaning a pause the user set (before or during the Focus) is left alone when the Focus
/// ends.
@MainActor
final class WallpaperFocusCoordinator {
    /// The one instance `PauseWhileFocusIntent` uses. Tests make their own instance instead, so
    /// each test's "was it me who paused" bit starts fresh.
    static let shared = WallpaperFocusCoordinator()

    init() {}

    private var pausedByFilter = false

    /// `isActive` is the Focus filter's own on/off state, not whether it's currently paused —
    /// `PauseWhileFocusIntent.perform()` calls this with `true` when the configured Focus turns
    /// on, and again with `false` when it turns off.
    func setFilterActive(_ isActive: Bool) {
        guard let manager = WallpaperIntentBridge.manager else { return }
        if isActive {
            guard !manager.isPaused else { return }
            manager.pause()
            pausedByFilter = true
        } else if pausedByFilter {
            pausedByFilter = false
            manager.resume()
        }
    }
}
