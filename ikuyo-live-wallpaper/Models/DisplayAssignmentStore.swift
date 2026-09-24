import Foundation

/// Where a wallpaper is assigned: every display, or one display by its stable UUID
/// (`NSScreen.displayUUID`, from `CGDisplayCreateUUIDFromDisplayID`).
nonisolated enum DisplayTarget: Hashable, Sendable {
    case allDisplays
    case display(String)
}

/// Which wallpaper each display shows: an "All Displays" default plus per-display overrides.
///
/// Overrides are keyed by display UUID and are kept while a display is disconnected, so plugging
/// it back in brings its wallpaper back.
nonisolated struct DisplayAssignments: Codable, Equatable, Sendable {
    /// Shown on every display without an override.
    var allDisplays: URL?
    /// Display UUID → wallpaper.
    var perDisplay: [String: URL] = [:]

    init(allDisplays: URL? = nil, perDisplay: [String: URL] = [:]) {
        self.allDisplays = allDisplays
        self.perDisplay = perDisplay
    }

    var isEmpty: Bool { allDisplays == nil && perDisplay.isEmpty }

    /// Every wallpaper mentioned, connected display or not.
    var allURLs: Set<URL> {
        Set(perDisplay.values).union(allDisplays.map { [$0] } ?? [])
    }

    func wallpaper(forDisplay id: String) -> URL? {
        perDisplay[id] ?? allDisplays
    }

    func hasOverride(forDisplay id: String) -> Bool {
        perDisplay[id] != nil
    }

    /// What each of the `connected` displays shows. Displays with nothing assigned are left out.
    func resolved(for connected: [String]) -> [String: URL] {
        var result: [String: URL] = [:]
        for id in connected {
            if let url = wallpaper(forDisplay: id) { result[id] = url }
        }
        return result
    }

    /// "All Displays" replaces every override, the way a new desktop picture applies everywhere.
    /// Assigning a display the default wallpaper drops its override, so it follows later changes.
    mutating func assign(_ url: URL, to target: DisplayTarget) {
        switch target {
        case .allDisplays:
            allDisplays = url
            perDisplay.removeAll()
        case .display(let id):
            perDisplay[id] = url == allDisplays ? nil : url
        }
    }

    /// The display follows "All Displays" again.
    mutating func clearOverride(forDisplay id: String) {
        perDisplay[id] = nil
    }

    /// Forgets `url` everywhere, e.g. after its file was moved to the Trash.
    mutating func remove(_ url: URL) {
        if allDisplays == url { allDisplays = nil }
        perDisplay = perDisplay.filter { $0.value != url }
    }

    /// Drops local files that no longer exist. Remote URLs are kept.
    mutating func removeMissingFiles(fileExists: (URL) -> Bool) {
        for url in allURLs where url.isFileURL && !fileExists(url) {
            remove(url)
        }
    }
}

/// Persists `DisplayAssignments` as `display-assignments.json` in Application Support/StarTorch.
@Observable
final class DisplayAssignmentStore {
    private(set) var assignments: DisplayAssignments

    @ObservationIgnored let fileURL: URL

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "StarTorch", directoryHint: .isDirectory)
            .appending(path: "display-assignments.json")
    }

    init(fileURL: URL = DisplayAssignmentStore.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(DisplayAssignments.self, from: data) {
            assignments = stored
        } else {
            assignments = DisplayAssignments()
        }
    }

    func assign(_ url: URL, to target: DisplayTarget) {
        update { $0.assign(url, to: target) }
    }

    func clearOverride(forDisplay id: String) {
        update { $0.clearOverride(forDisplay: id) }
    }

    func remove(_ url: URL) {
        update { $0.remove(url) }
    }

    func removeMissingFiles(
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    ) {
        update { $0.removeMissingFiles(fileExists: fileExists) }
    }

    private func update(_ change: (inout DisplayAssignments) -> Void) {
        var updated = assignments
        change(&updated)
        guard updated != assignments else { return }
        assignments = updated
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(assignments) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
