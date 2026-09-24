import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @SceneStorage("sidebarSelection") private var sidebarSelection: SidebarItem = .gallery
    @State private var searchText = ""
    @State private var selectedItemID: WallpaperItem.ID?
    @State private var importQueue = ImportQueue()
    @State private var isShowingImporter = false
    @State private var deleteError: String?
    @State private var isShowingNewCollectionAlert = false
    @State private var newCollectionName = ""
    @State private var renamingCollection: WallpaperCollection?
    @State private var renameCollectionName = ""

    @Environment(WallpaperLibrary.self) private var library
    @Environment(ImportedWallpaperStore.self) private var importedStore
    @Environment(WallpaperManager.self) private var manager
    @Environment(WallpaperCacheManager.self) private var cacheManager
    @Environment(ScheduleService.self) private var scheduleService
    @Environment(\.undoManager) private var undoManager

    private static let importableTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie, .movie]

    /// The items visible in the currently selected sidebar section, after search.
    private var currentItems: [WallpaperItem] {
        let base: [WallpaperItem]
        switch sidebarSelection {
        case .gallery:
            // Stable, name-only order: favoriting or downloading a card never reshuffles the grid.
            base = library.catalog.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .favorites:
            base = library.favoriteCatalogItems
        case .myFiles:
            base = importedStore.items
        case .collection(let id):
            if let collection = library.collection(id) {
                base = library.resolvedItems(for: collection, importedItems: importedStore.items)
            } else {
                base = []
            }
        case .displays:
            base = []
        }
        return WallpaperSearch.filter(base, query: searchText)
    }

    private var selectedCollection: WallpaperCollection? {
        sidebarSelection.collectionID.flatMap { library.collection($0) }
    }

    private var selectedItem: WallpaperItem? {
        currentItems.first { $0.id == selectedItemID }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("Search Wallpapers"))
        .toolbar { toolbarContent }
        .inspector(isPresented: inspectorPresented) {
            if let selectedItem {
                WallpaperInspectorView(item: selectedItem, isImported: sidebarSelection == .myFiles)
                    .inspectorColumnWidth(min: 260, ideal: 300)
            }
        }
        .onChange(of: sidebarSelection) { _, _ in selectedItemID = nil }
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: Self.importableTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                enqueueImports(urls, securityScoped: true)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            enqueueImports(urls, securityScoped: false)
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: .didReceiveDockDrop)) { notification in
            if let urls = notification.userInfo?["urls"] as? [URL] {
                enqueueImports(urls, securityScoped: false)
            }
        }
        .sheet(item: importSheetBinding) { source in
            ImportPreviewView(
                sourceURL: source.url,
                remainingCount: importQueue.remainingCount,
                onComplete: { convertedURL, name in
                    importedStore.addConvertedVideo(at: convertedURL, name: name)
                    importQueue.advance()
                },
                onCancel: {
                    try? FileManager.default.removeItem(at: source.url)
                    importQueue.advance()
                }
            )
        }
        .alert(
            "Couldn't Move to Trash",
            isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }),
            presenting: deleteError
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
        .alert("New Collection", isPresented: $isShowingNewCollectionAlert) {
            TextField("Name", text: $newCollectionName)
            Button("Cancel", role: .cancel) { newCollectionName = "" }
            Button("Create") { createCollection() }
                .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .alert("Rename Collection", isPresented: renameAlertPresented) {
            TextField("Name", text: $renameCollectionName)
            Button("Cancel", role: .cancel) { renamingCollection = nil }
            Button("Rename") { commitRenameCollection() }
                .disabled(renameCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Section("Wallpapers") {
                Label(SidebarItem.gallery.title, systemImage: SidebarItem.gallery.systemImage)
                    .tag(SidebarItem.gallery)
                Label(SidebarItem.favorites.title, systemImage: SidebarItem.favorites.systemImage)
                    .tag(SidebarItem.favorites)
            }
            Section("Local") {
                Label(SidebarItem.myFiles.title, systemImage: SidebarItem.myFiles.systemImage)
                    .tag(SidebarItem.myFiles)
            }
            Section("Desktop") {
                Label(SidebarItem.displays.title, systemImage: SidebarItem.displays.systemImage)
                    .tag(SidebarItem.displays)
            }
            Section {
                ForEach(library.collections) { collection in
                    Label(collection.name, systemImage: SidebarItem.collection(collection.id).systemImage)
                        .tag(SidebarItem.collection(collection.id))
                        .contextMenu { collectionSidebarContextMenu(for: collection) }
                }
            } header: {
                HStack {
                    Text("Collections")
                    Spacer()
                    Button {
                        newCollectionName = ""
                        isShowingNewCollectionAlert = true
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("New Collection")
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
    }

    @ViewBuilder
    private func collectionSidebarContextMenu(for collection: WallpaperCollection) -> some View {
        Button("Play Collection") { scheduleService.playCollection(collection.id) }
        Button("Rename…") {
            renamingCollection = collection
            renameCollectionName = collection.name
        }
        Divider()
        Button("Delete", role: .destructive) { deleteCollection(collection) }
    }

    @ViewBuilder
    private var detail: some View {
        switch sidebarSelection {
        case .gallery:
            grid(emptyTitle: "No Wallpapers Yet", emptyImage: "sparkles.tv", emptyDescription: "Import your own videos from My Files.")
                .navigationTitle(SidebarItem.gallery.title)
        case .favorites:
            grid(emptyTitle: "No Favorites", emptyImage: "heart", emptyDescription: "Tap the heart icon on a wallpaper to add it here.")
                .navigationTitle(SidebarItem.favorites.title)
        case .myFiles:
            grid(emptyTitle: "No Imported Videos", emptyImage: "video.badge.plus", emptyDescription: "Import video files from your Mac to use as wallpapers.")
                .navigationTitle(SidebarItem.myFiles.title)
                .navigationSubtitle(Text("^[\(importedStore.items.count) file](inflect: true)"))
        case .displays:
            DisplaysView()
                .navigationTitle(SidebarItem.displays.title)
        case .collection(let id):
            if let collection = library.collection(id) {
                grid(emptyTitle: "No Wallpapers in This Collection", emptyImage: "rectangle.stack", emptyDescription: "Add wallpapers from Gallery, Favorites or My Files using \u{201C}Add to Collection.\u{201D}")
                    .navigationTitle(collection.name)
            } else {
                ContentUnavailableView("Collection Not Found", systemImage: "rectangle.stack")
            }
        }
    }

    private func grid(emptyTitle: LocalizedStringKey, emptyImage: String, emptyDescription: LocalizedStringKey) -> some View {
        WallpaperGridView(
            items: currentItems,
            selection: $selectedItemID,
            isActive: { manager.isShowing($0.url) },
            isFavorite: { library.isFavorite($0.url) },
            downloadState: { cacheManager.states[$0.url] },
            hideDownloadBadge: sidebarSelection == .myFiles,
            onApply: { manager.start(with: $0.url) },
            onToggleFavorite: { library.toggleFavorite($0.url) },
            contextMenu: { item in contextMenu(for: item) },
            emptyState: {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptyImage,
                    description: Text(emptyDescription)
                )
            }
        )
    }

    @ViewBuilder
    private func contextMenu(for item: WallpaperItem) -> some View {
        Button("Set as Wallpaper") { manager.start(with: item.url) }
        Button("Preview") { NSWorkspace.shared.open(item.url) }
        Divider()
        Button(library.isFavorite(item.url) ? "Remove from Favorites" : "Add to Favorites") {
            library.toggleFavorite(item.url)
        }
        if sidebarSelection != .myFiles {
            keepOfflineButton(for: item)
        }
        Divider()
        addToCollectionMenu(for: item)
        if let collectionID = sidebarSelection.collectionID {
            Button("Remove from Collection") { library.removeItem(item.url, from: collectionID) }
        }
        if sidebarSelection == .myFiles {
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button("Move to Trash", role: .destructive) { deleteImported(item) }
        }
    }

    @ViewBuilder
    private func addToCollectionMenu(for item: WallpaperItem) -> some View {
        Menu("Add to Collection") {
            if library.collections.isEmpty {
                Text("No Collections Yet")
            }
            ForEach(library.collections) { collection in
                Button(collection.name) { library.addItem(item.url, to: collection.id) }
                    .disabled(collection.itemURLs.contains(item.url))
            }
            Divider()
            Button("New Collection…") {
                newCollectionName = ""
                isShowingNewCollectionAlert = true
            }
        }
    }

    /// A "Keep Offline" action independent of favoriting, using `WallpaperCacheManager` directly.
    /// Note: unfavoriting a video still evicts its cache (`WallpaperLibrary.setFavorite`), so a
    /// favorite you've also "kept offline" loses that offline copy if you unfavorite it — the two
    /// aren't fully decoupled yet, since that touches favorite/cache coupling from Phase 1.
    @ViewBuilder
    private func keepOfflineButton(for item: WallpaperItem) -> some View {
        switch cacheManager.states[item.url] ?? .notStarted {
        case .completed:
            Button("Remove from Offline") { cacheManager.removeCache(for: item.url) }
        default:
            Button("Keep Offline") { cacheManager.startDownload(item.url) }
        }
    }

    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renamingCollection != nil },
            set: { if !$0 { renamingCollection = nil } }
        )
    }

    private func createCollection() {
        let name = newCollectionName.trimmingCharacters(in: .whitespaces)
        newCollectionName = ""
        guard !name.isEmpty else { return }
        let collection = library.createCollection(name: name)
        sidebarSelection = .collection(collection.id)
    }

    private func commitRenameCollection() {
        guard let collection = renamingCollection else { return }
        let name = renameCollectionName.trimmingCharacters(in: .whitespaces)
        renamingCollection = nil
        guard !name.isEmpty else { return }
        library.renameCollection(collection.id, to: name)
    }

    private func deleteCollection(_ collection: WallpaperCollection) {
        if sidebarSelection == .collection(collection.id) {
            sidebarSelection = .gallery
        }
        library.deleteCollection(collection.id, undoManager: undoManager)
    }

    private func deleteImported(_ item: WallpaperItem) {
        // Also forgets it on displays that aren't connected right now.
        manager.remove(item.url)
        do {
            try importedStore.moveToTrash(item.url, undoManager: undoManager)
        } catch {
            deleteError = error.localizedDescription
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if sidebarSelection == .myFiles {
            ToolbarItem(placement: .primaryAction) {
                Button("Import Video", systemImage: "plus") {
                    isShowingImporter = true
                }
            }
        }
        if let collection = selectedCollection, !collection.itemURLs.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button("Play Collection", systemImage: "shuffle") {
                    scheduleService.playCollection(collection.id)
                }
                .help("Play Collection")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // An automatic pause (desktop covered, full-screen app, etc.) explains itself here;
            // a pause by the user already reads as "Resume" on the control itself.
            if let reason = manager.pauseReason, reason != .user {
                Text("Paused: \(reason.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PlaybackControls()
        }
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { selectedItem != nil },
            set: { isPresented in if !isPresented { selectedItemID = nil } }
        )
    }

    private var importSheetBinding: Binding<ImportSource?> {
        Binding(
            get: { importQueue.current },
            set: { newValue in if newValue == nil { importQueue.advance() } }
        )
    }

    private func enqueueImports(_ urls: [URL], securityScoped: Bool) {
        sidebarSelection = .myFiles
        var copiedURLs: [URL] = []
        for url in urls {
            let didStartScope = securityScoped && url.startAccessingSecurityScopedResource()
            defer { if didStartScope { url.stopAccessingSecurityScopedResource() } }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(url.pathExtension)
            guard (try? FileManager.default.copyItem(at: url, to: tempURL)) != nil else { continue }
            copiedURLs.append(tempURL)
        }
        importQueue.enqueue(copiedURLs)
    }
}

#Preview {
    let settings = AppSettings()
    let library = WallpaperLibrary()
    let manager = WallpaperManager()
    ContentView()
        .environment(manager)
        .environment(settings)
        .environment(library)
        .environment(WallpaperCacheManager())
        .environment(ImportedWallpaperStore())
        .environment(ScheduleService(manager: manager, library: library, settings: settings, observeSystemEvents: false))
}
