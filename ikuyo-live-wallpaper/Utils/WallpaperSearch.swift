import Foundation

/// Pure filtering logic behind the toolbar's `.searchable` field, kept separate from any view
/// so it's simple to unit test.
enum WallpaperSearch {
    /// Items whose name contains `query`, case- and diacritic-insensitively. An empty (or
    /// whitespace-only) query returns every item, unchanged in order.
    static func filter(_ items: [WallpaperItem], query: String) -> [WallpaperItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter {
            $0.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
