import AppKit
import OSLog

/// The borderless window a wallpaper plays in. It covers the whole display, menu bar strip
/// included: on macOS 26 the menu bar is transparent, and a window pushed below it would leave the
/// still frame (the desktop picture) showing through instead of the video.
final class DesktopWallpaperWindow: NSWindow {
    private static let log = Logger(subsystem: "com.shibuyaxpress.startorch-wallpaper", category: "DesktopWindow")

    /// AppKit keeps windows clear of the menu bar; this one belongs under it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Logs where the window really is, in AppKit's and the window server's view, next to the
    /// display it should cover. Read with
    /// `log stream --level debug --predicate 'subsystem == "com.shibuyaxpress.startorch-wallpaper"'`.
    func logPlacement(on screen: NSScreen) {
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]])?.first
        let serverBounds = (info?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        let serverLayer = info?[kCGWindowLayer as String] as? Int
        let placement = """
            window \(windowNumber) frame \(NSStringFromRect(frame)) \
            server bounds \(serverBounds.map { NSStringFromRect($0) } ?? "unknown") layer \(serverLayer ?? -1) \
            screen \(NSStringFromRect(screen.frame)) visible \(NSStringFromRect(screen.visibleFrame)) \
            safe area top \(screen.safeAreaInsets.top)
            """
        Self.log.debug("\(placement, privacy: .public)")
    }
}
