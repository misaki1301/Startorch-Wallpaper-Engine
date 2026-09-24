import Foundation

/// One video waiting to go through `ImportPreviewView`.
struct ImportSource: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

/// A simple FIFO of files dropped, picked or dragged in faster than the preview sheet can show
/// them. `ImportedWallpaperView`/`ContentView` present `current` one at a time and call
/// `advance()` when the sheet for it is done (imported or cancelled).
struct ImportQueue {
    private(set) var pending: [ImportSource] = []

    var current: ImportSource? { pending.first }
    var isEmpty: Bool { pending.isEmpty }
    /// How many more imports are queued behind the one currently shown.
    var remainingCount: Int { max(0, pending.count - 1) }

    mutating func enqueue(_ urls: [URL]) {
        pending.append(contentsOf: urls.map(ImportSource.init))
    }

    /// Removes the item currently being shown, if any, revealing the next one.
    mutating func advance() {
        guard !pending.isEmpty else { return }
        pending.removeFirst()
    }
}
