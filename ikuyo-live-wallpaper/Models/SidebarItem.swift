import Foundation

/// The sidebar's sections. `@SceneStorage` persists the raw value across launches, so don't
/// change these strings without migrating any stored selection.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case gallery
    case favorites
    case myFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gallery: return String(localized: "sidebar.gallery", defaultValue: "Gallery")
        case .favorites: return String(localized: "sidebar.favorites", defaultValue: "Favorites")
        case .myFiles: return String(localized: "sidebar.myFiles", defaultValue: "My Files")
        }
    }

    var systemImage: String {
        switch self {
        case .gallery: return "square.grid.2x2"
        case .favorites: return "heart"
        case .myFiles: return "folder"
        }
    }
}
