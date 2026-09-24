import Foundation
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

    @Test("A collection's raw value round-trips its UUID, since it's also @SceneStorage-persisted")
    func collectionRawValueRoundTrips() {
        let id = UUID()
        let item = SidebarItem.collection(id)
        #expect(SidebarItem(rawValue: item.rawValue) == item)
        #expect(item.collectionID == id)
        #expect(item.rawValue == "collection:\(id.uuidString)")
    }

    @Test("A garbled or unknown raw value fails to decode, rather than crashing or aliasing a fixed case")
    func invalidRawValuesReturnNil() {
        #expect(SidebarItem(rawValue: "collection:not-a-uuid") == nil)
        #expect(SidebarItem(rawValue: "collection:") == nil)
        #expect(SidebarItem(rawValue: "somethingElse") == nil)
    }

    @Test("Only .collection carries a collectionID")
    func collectionIDIsNilForFixedCases() {
        for item in SidebarItem.allCases {
            #expect(item.collectionID == nil)
        }
    }
}
