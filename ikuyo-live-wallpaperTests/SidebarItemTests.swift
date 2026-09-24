import Testing
@testable import StarTorch_Wallpaper_Engine

@MainActor
@Suite("SidebarItem")
struct SidebarItemTests {
    @Test("Raw values round-trip, since @SceneStorage persists them across launches")
    func rawValueRoundTrip() {
        for item in SidebarItem.allCases {
            #expect(SidebarItem(rawValue: item.rawValue) == item)
        }
    }

    @Test("Gallery is first, so it is the sensible launch default")
    func galleryIsDefault() {
        #expect(SidebarItem.allCases.first == .gallery)
    }

    @Test("Every case has a distinct id and system image")
    func distinctMetadata() {
        let ids = Set(SidebarItem.allCases.map(\.id))
        let images = Set(SidebarItem.allCases.map(\.systemImage))
        #expect(ids.count == SidebarItem.allCases.count)
        #expect(images.count == SidebarItem.allCases.count)
    }
}
