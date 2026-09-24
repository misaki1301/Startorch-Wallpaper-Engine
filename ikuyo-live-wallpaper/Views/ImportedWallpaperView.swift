import SwiftUI
import UniformTypeIdentifiers

struct ImportSource: Identifiable {
    let id = UUID()
    let url: URL
}

struct ImportedWallpaperView: View {
    @Environment(ImportedWallpaperStore.self) private var store
    @Environment(WallpaperManager.self) private var manager
    @Environment(WallpaperCacheManager.self) private var cacheManager
    @Environment(WallpaperLibrary.self) private var library
    @State private var importSource: ImportSource?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Import Video", systemImage: "plus") {
                    openImportPanel()
                }
                Spacer()
                Text("\(store.items.count) file\(store.items.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            if store.items.isEmpty {
                ContentUnavailableView(
                    "No Imported Videos",
                    systemImage: "video.badge.plus",
                    description: Text("Import video files from your Mac to use as wallpapers.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 16) {
                        ForEach(store.items) { item in
                            videoCard(for: item)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("My Files")
        .sheet(item: $importSource) { source in
            ImportPreviewView(
                sourceURL: source.url,
                onComplete: { convertedURL, name in
                    store.addConvertedVideo(at: convertedURL, name: name)
                    importSource = nil
                },
                onCancel: {
                    try? FileManager.default.removeItem(at: source.url)
                    importSource = nil
                }
            )
        }
    }

    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .video]
        panel.allowsMultipleSelection = false
        panel.message = "Select a video to import as wallpaper"
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }

        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        // Copy to temp immediately to avoid security scope issues
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        guard (try? FileManager.default.copyItem(at: url, to: tempURL)) != nil else { return }

        importSource = ImportSource(url: tempURL)
    }

    private func videoCard(for item: WallpaperItem) -> some View {
        VideoThumbnailView(
            url: item.url,
            name: item.name,
            isActive: manager.isActive && manager.currentURL == item.url,
            downloadState: cacheManager.states[item.url],
            hideDownloadBadge: true,
            isFavorite: Binding(
                get: { library.isFavorite(item.url) },
                set: { library.setFavorite($0, for: item.url) }
            )
        )
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                fileSizeBadge(for: item.url)
                deleteButton(for: item)
            }
        }
        .onTapGesture {
            manager.start(with: item.url)
        }
        .contextMenu {
            Button("Set as Wallpaper") { manager.start(with: item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Divider()
            Button(library.isFavorite(item.url) ? "Remove from Favorites" : "Add to Favorites") {
                library.toggleFavorite(item.url)
            }
            Divider()
            Button("Delete", role: .destructive) { deleteItem(item) }
        }
    }

    @ViewBuilder
    private func fileSizeBadge(for url: URL) -> some View {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64 {
            Text(formatBytes(size))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.5), in: Capsule())
                .padding(6)
        }
    }

    private func deleteButton(for item: WallpaperItem) -> some View {
        Button("Delete", systemImage: "trash") {
            deleteItem(item)
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(.red)
        .shadow(radius: 2)
        .padding(6)
    }

    private func deleteItem(_ item: WallpaperItem) {
        library.setFavorite(false, for: item.url)
        if manager.currentURL == item.url {
            manager.stop()
        }
        store.delete(item.url)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

#Preview {
    ImportedWallpaperView()
        .environment(ImportedWallpaperStore())
        .environment(WallpaperManager())
        .environment(WallpaperCacheManager())
        .environment(WallpaperLibrary())
        .frame(width: 800, height: 600)
}
