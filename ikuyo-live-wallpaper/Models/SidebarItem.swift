import Foundation

/// The sidebar's sections. `@SceneStorage` persists the raw value across launches, so don't
/// change the fixed cases' encoded strings without migrating any stored selection.
///
/// `.collection` carries the collection's stable `UUID`, encoded as `"collection:<uuid>"`; it
/// can't be `CaseIterable` because of that associated value, so `allCases` below is a plain
/// static list of the fixed sections instead of the synthesized protocol conformance.
enum SidebarItem: Hashable, Identifiable {
    case gallery
    case favorites
    case myFiles
    case collection(UUID)

    /// The fixed (non-collection) sections, in sidebar order.
    static let allCases: [SidebarItem] = [.gallery, .favorites, .myFiles]

    var id: String { rawValue }

    /// The collection's own `UUID`, or `nil` for a fixed section.
    var collectionID: UUID? {
        if case .collection(let id) = self { return id }
        return nil
    }

    var title: String {
        switch self {
        case .gallery: return String(localized: "sidebar.gallery", defaultValue: "Gallery")
        case .favorites: return String(localized: "sidebar.favorites", defaultValue: "Favorites")
        case .myFiles: return String(localized: "sidebar.myFiles", defaultValue: "My Files")
        case .collection: return "" // Views look up the live name from WallpaperLibrary instead.
        }
    }

    var systemImage: String {
        switch self {
        case .gallery: return "square.grid.2x2"
        case .favorites: return "heart"
        case .myFiles: return "folder"
        case .collection: return "rectangle.stack"
        }
    }
}

extension SidebarItem: RawRepresentable {
    private static let collectionPrefix = "collection:"

    init?(rawValue: String) {
        switch rawValue {
        case "gallery": self = .gallery
        case "favorites": self = .favorites
        case "myFiles": self = .myFiles
        default:
            guard rawValue.hasPrefix(Self.collectionPrefix),
                  let id = UUID(uuidString: String(rawValue.dropFirst(Self.collectionPrefix.count)))
            else { return nil }
            self = .collection(id)
        }
    }

    var rawValue: String {
        switch self {
        case .gallery: return "gallery"
        case .favorites: return "favorites"
        case .myFiles: return "myFiles"
        case .collection(let id): return Self.collectionPrefix + id.uuidString
        }
    }
}
