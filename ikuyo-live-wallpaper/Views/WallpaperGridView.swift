import SwiftUI

/// The adaptive grid of `WallpaperCardView`s shared by Gallery, Favorites and My Files.
///
/// Keeping the grid, selection and keyboard navigation in one place means arrow-key movement,
/// double-click-to-apply and the empty state only need to be right once.
struct WallpaperGridView<Menu: View, Empty: View>: View {
    let items: [WallpaperItem]
    @Binding var selection: WallpaperItem.ID?
    let isActive: (WallpaperItem) -> Bool
    let isFavorite: (WallpaperItem) -> Bool
    let downloadState: (WallpaperItem) -> DownloadState?
    var hideDownloadBadge: Bool = false
    let onApply: (WallpaperItem) -> Void
    let onToggleFavorite: (WallpaperItem) -> Void
    @ViewBuilder let contextMenu: (WallpaperItem) -> Menu
    @ViewBuilder let emptyState: () -> Empty

    @FocusState private var focusedID: WallpaperItem.ID?
    @State private var columnCount = 1

    private static var minItemWidth: CGFloat { 220 }
    private static var gridSpacing: CGFloat { 16 }

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: Self.minItemWidth), spacing: Self.gridSpacing)],
                        spacing: Self.gridSpacing
                    ) {
                        ForEach(items) { item in
                            card(for: item)
                                .focusable()
                                .focused($focusedID, equals: item.id)
                                .onMoveCommand { direction in move(direction, from: item) }
                        }
                    }
                    .padding()
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { newWidth in
                        columnCount = max(1, Int((newWidth + Self.gridSpacing) / (Self.minItemWidth + Self.gridSpacing)))
                    }
                }
            }
        }
        .onChange(of: focusedID) { _, newValue in
            if let newValue { selection = newValue }
        }
    }

    private func card(for item: WallpaperItem) -> some View {
        WallpaperCardView(
            item: item,
            isActive: isActive(item),
            isSelected: selection == item.id,
            isFavorite: isFavorite(item),
            downloadState: downloadState(item),
            hideDownloadBadge: hideDownloadBadge,
            onSelect: {
                selection = item.id
                focusedID = item.id
            },
            onApply: { onApply(item) },
            onToggleFavorite: { onToggleFavorite(item) }
        )
        .contextMenu { contextMenu(item) }
    }

    private func move(_ direction: MoveCommandDirection, from item: WallpaperItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var target = index
        switch direction {
        case .left: target -= 1
        case .right: target += 1
        case .up: target -= columnCount
        case .down: target += columnCount
        default: return
        }
        guard items.indices.contains(target) else { return }
        focusedID = items[target].id
    }
}
