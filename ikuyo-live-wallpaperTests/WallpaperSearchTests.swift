import Testing
import Foundation
@testable import StarTorch_Wallpaper_Engine

@MainActor
@Suite("WallpaperSearch")
struct WallpaperSearchTests {
    private func item(_ name: String) -> WallpaperItem {
        WallpaperItem(url: URL(string: "https://example.com/\(UUID().uuidString).mp4")!, name: name)
    }

    @Test("Empty query returns every item, unchanged in order")
    func emptyQuery() {
        let items = [item("Rain"), item("Snow"), item("Fire")]
        #expect(WallpaperSearch.filter(items, query: "") == items)
        #expect(WallpaperSearch.filter(items, query: "   ") == items)
    }

    @Test("Filters case-insensitively by substring")
    func caseInsensitive() {
        let items = [item("Ocean Waves"), item("Mountain Snow"), item("Desert Sun")]
        let result = WallpaperSearch.filter(items, query: "ocean")
        #expect(result.map(\.name) == ["Ocean Waves"])
    }

    @Test("Filters diacritic-insensitively")
    func diacriticInsensitive() {
        let items = [item("Café Morning"), item("Forest")]
        let result = WallpaperSearch.filter(items, query: "cafe")
        #expect(result.map(\.name) == ["Café Morning"])
    }

    @Test("No match returns an empty array")
    func noMatch() {
        let items = [item("Rain"), item("Snow")]
        #expect(WallpaperSearch.filter(items, query: "volcano").isEmpty)
    }
}
