import AppKit

extension Notification.Name {
    /// Posted with a `"urls": [URL]` payload when the Dock icon receives dropped or
    /// "Open With"-ed files. `ContentView` listens for this to queue them for import.
    static let didReceiveDockDrop = Notification.Name("StarTorchDidReceiveDockDrop")
}

/// Bridges the one AppKit callback SwiftUI's `App` protocol doesn't expose: files handed to us
/// via the Dock icon (drag & drop, or "Open With").
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: .didReceiveDockDrop, object: nil, userInfo: ["urls": urls])
    }
}
