import AppKit
import CoreGraphics

/// The subset of `NSWorkspace.DesktopImageOptionKey` values we can persist.
nonisolated struct DesktopImageOptions: Codable, Equatable, Sendable {
    var imageScaling: UInt?
    var allowClipping: Bool?
    /// sRGB red, green, blue, alpha.
    var fillColor: [Double]?

    /// Fill the screen, cropping as needed — how the wallpaper video is drawn.
    static let fill = DesktopImageOptions(
        imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
        allowClipping: true
    )

    init(imageScaling: UInt? = nil, allowClipping: Bool? = nil, fillColor: [Double]? = nil) {
        self.imageScaling = imageScaling
        self.allowClipping = allowClipping
        self.fillColor = fillColor
    }

    init(_ options: [NSWorkspace.DesktopImageOptionKey: Any]) {
        imageScaling = (options[.imageScaling] as? NSNumber)?.uintValue
        allowClipping = (options[.allowClipping] as? NSNumber)?.boolValue
        if let color = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) {
            fillColor = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                .map(Double.init)
        }
    }

    var workspaceOptions: [NSWorkspace.DesktopImageOptionKey: Any] {
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let imageScaling { options[.imageScaling] = NSNumber(value: imageScaling) }
        if let allowClipping { options[.allowClipping] = NSNumber(value: allowClipping) }
        if let fillColor, fillColor.count == 4 {
            options[.fillColor] = NSColor(
                srgbRed: fillColor[0], green: fillColor[1], blue: fillColor[2], alpha: fillColor[3]
            )
        }
        return options
    }
}

/// Reads and writes the system desktop picture per display. Displays are identified by a
/// stable UUID string so a saved record still matches after a relaunch or reconnect.
protocol DesktopImageSetting {
    var connectedDisplayIDs: [String] { get }
    func desktopImageURL(for displayID: String) -> URL?
    func desktopImageOptions(for displayID: String) -> DesktopImageOptions
    func setDesktopImageURL(_ url: URL, for displayID: String, options: DesktopImageOptions) throws
}

/// The real desktop, via `NSWorkspace`.
struct SystemDesktop: DesktopImageSetting {
    var connectedDisplayIDs: [String] {
        NSScreen.screens.compactMap(\.displayUUID)
    }

    func desktopImageURL(for displayID: String) -> URL? {
        screen(for: displayID).flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    }

    func desktopImageOptions(for displayID: String) -> DesktopImageOptions {
        guard let screen = screen(for: displayID),
              let options = NSWorkspace.shared.desktopImageOptions(for: screen) else { return DesktopImageOptions() }
        return DesktopImageOptions(options)
    }

    func setDesktopImageURL(_ url: URL, for displayID: String, options: DesktopImageOptions) throws {
        guard let screen = screen(for: displayID) else { return }
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options.workspaceOptions)
    }

    private func screen(for displayID: String) -> NSScreen? {
        NSScreen.screens.first { $0.displayUUID == displayID }
    }
}

/// A desktop with no displays: nothing is ever read or changed. Used when the app is only
/// hosting unit tests, so a test run can never touch the real wallpaper.
struct InertDesktop: DesktopImageSetting {
    var connectedDisplayIDs: [String] { [] }
    func desktopImageURL(for displayID: String) -> URL? { nil }
    func desktopImageOptions(for displayID: String) -> DesktopImageOptions { DesktopImageOptions() }
    func setDesktopImageURL(_ url: URL, for displayID: String, options: DesktopImageOptions) throws {}
}

extension NSScreen {
    /// Stable across reboots and reconnects, unlike `CGDirectDisplayID`.
    var displayUUID: String? {
        guard let displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

/// Keeps the user's own desktop pictures safe while a wallpaper is running.
///
/// Before StarTorch first changes a display's desktop picture, its original URL and options are
/// written to `desktop-backup.json`. Restoring puts them back and deletes the record. Because the
/// record lives on disk, a relaunch after a crash or `kill -9` can still restore them.
final class DesktopRestorer {
    nonisolated struct SavedDesktop: Codable, Equatable, Sendable {
        var imageURL: URL
        var options: DesktopImageOptions
    }

    let recordURL: URL
    /// Where still frames shown as the desktop picture are kept. Never a temporary directory:
    /// the system keeps pointing at the file until we restore the original.
    let framesDirectory: URL
    private let desktop: any DesktopImageSetting

    init(
        desktop: any DesktopImageSetting = SystemDesktop(),
        directory: URL = URL.applicationSupportDirectory.appending(path: "StarTorch", directoryHint: .isDirectory)
    ) {
        self.desktop = desktop
        recordURL = directory.appending(path: "desktop-backup.json")
        framesDirectory = directory.appending(path: "Frames", directoryHint: .isDirectory)
    }

    /// Originals saved and not yet restored, keyed by display UUID.
    var savedDesktops: [String: SavedDesktop] {
        guard let data = try? Data(contentsOf: recordURL) else { return [:] }
        return (try? JSONDecoder().decode([String: SavedDesktop].self, from: data)) ?? [:]
    }

    var hasSavedDesktops: Bool { !savedDesktops.isEmpty }

    /// Records the current picture of every connected display, unless it is one of our frames.
    /// While a wallpaper runs the current picture is our frame, so switching wallpapers keeps the
    /// real original; if the user picks a new picture meanwhile, that becomes the one to restore.
    func saveOriginalDesktops() {
        var saved = savedDesktops
        for id in desktop.connectedDisplayIDs {
            guard let url = desktop.desktopImageURL(for: id), !isOwnFrame(url) else { continue }
            saved[id] = SavedDesktop(imageURL: url, options: desktop.desktopImageOptions(for: id))
        }
        write(saved)
    }

    /// Shows `frameURL` (a file in `framesDirectory`) as the desktop picture of every display
    /// whose original is safely recorded.
    func showFrame(_ frameURL: URL) {
        saveOriginalDesktops()
        let saved = savedDesktops
        for id in desktop.connectedDisplayIDs {
            // Never replace a picture we couldn't record — we'd have no way to put it back.
            let current = desktop.desktopImageURL(for: id)
            guard saved[id] != nil || current.map(isOwnFrame) == true else { continue }
            try? desktop.setDesktopImageURL(frameURL, for: id, options: .fill)
        }
        removeFrames(except: frameURL)
    }

    /// Puts back every recorded original on displays that are connected. Entries for
    /// disconnected displays, or that fail to apply, are kept for the next attempt.
    func restoreOriginalDesktops() {
        var saved = savedDesktops
        guard !saved.isEmpty else { return }
        let connected = Set(desktop.connectedDisplayIDs)
        for (id, original) in saved where connected.contains(id) {
            do {
                try desktop.setDesktopImageURL(original.imageURL, for: id, options: original.options)
                saved[id] = nil
            } catch {
                continue
            }
        }
        write(saved)
        if saved.isEmpty {
            // Nothing points at our frames any more.
            try? FileManager.default.removeItem(at: framesDirectory)
        }
    }

    // MARK: - Private

    private func isOwnFrame(_ url: URL) -> Bool {
        let directory = framesDirectory.standardizedFileURL.path(percentEncoded: false)
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return url.standardizedFileURL.path(percentEncoded: false).hasPrefix(prefix)
    }

    private func write(_ saved: [String: SavedDesktop]) {
        if saved.isEmpty {
            try? FileManager.default.removeItem(at: recordURL)
            return
        }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(
            at: recordURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: recordURL, options: .atomic)
    }

    private func removeFrames(except keep: URL) {
        let fm = FileManager.default
        guard let frames = try? fm.contentsOfDirectory(at: framesDirectory, includingPropertiesForKeys: nil) else { return }
        for frame in frames where frame.standardizedFileURL != keep.standardizedFileURL {
            try? fm.removeItem(at: frame)
        }
    }
}
