import SwiftUI

/// Mirrors System Settings → Displays: the connected displays laid out as they are arranged,
/// each showing its wallpaper. Drag a wallpaper from the strip onto a display, or onto
/// "All Displays"; the pickers below do the same from the keyboard or VoiceOver.
struct DisplaysView: View {
    @Environment(WallpaperManager.self) private var manager
    @Environment(WallpaperLibrary.self) private var library
    @Environment(ImportedWallpaperStore.self) private var importedStore
    @State private var displays: [DisplayInfo] = []

    private var assignments: DisplayAssignments { manager.assignments.assignments }

    private var allItems: [WallpaperItem] {
        library.catalog.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            + importedStore.items
    }

    private func name(for url: URL?) -> String? {
        guard let url else { return nil }
        return allItems.first { $0.url == url }?.name
            ?? WallpaperItem(url: url).name
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !manager.isActive, !assignments.isEmpty {
                        stoppedBanner
                    }
                    arrangement
                        .frame(height: 260)
                    allDisplaysTile
                    pickers
                }
                .padding()
            }
            Divider()
            wallpaperStrip
        }
        .onAppear { displays = DisplayInfo.connected }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayInfo.connected
        }
    }

    // MARK: - Arrangement

    private var arrangement: some View {
        GeometryReader { proxy in
            let frames = DisplayArrangement.fit(
                Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.frame) }),
                in: proxy.size
            )
            ZStack(alignment: .topLeading) {
                ForEach(displays) { display in
                    if let frame = frames[display.id] {
                        MiniScreen(
                            display: display,
                            url: assignments.wallpaper(forDisplay: display.id),
                            wallpaperName: name(for: assignments.wallpaper(forDisplay: display.id)),
                            hasOverride: assignments.hasOverride(forDisplay: display.id),
                            isRunning: manager.isActive,
                            onDrop: { manager.assign($0, to: .display(display.id)) },
                            onClearOverride: { manager.clearOverride(forDisplay: display.id) }
                        )
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Display Arrangement"))
    }

    private var allDisplaysTile: some View {
        DropTile(onDrop: { manager.start(with: $0) }) { isTargeted in
            HStack(spacing: 12) {
                PosterImage(url: assignments.allDisplays)
                    .frame(width: 96, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Label("All Displays", systemImage: "display.2")
                        .font(.headline)
                    Text(name(for: assignments.allDisplays) ?? String(localized: "Drop a wallpaper here to use it everywhere"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(10)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isTargeted ? Color.accentColor : .clear, lineWidth: 3)
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Replaces the wallpaper on every display"))
    }

    private var stoppedBanner: some View {
        HStack {
            Label("Wallpapers are stopped", systemImage: "pause.circle")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Play") { manager.play(orStart: nil) }
        }
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Pickers

    private var pickers: some View {
        Form {
            Picker("All Displays", selection: allDisplaysSelection) {
                if assignments.allDisplays == nil {
                    Text("None").tag(URL?.none)
                }
                ForEach(allItems) { item in
                    Text(item.name).tag(URL?.some(item.url))
                }
            }
            ForEach(displays) { display in
                Picker(display.name, selection: selection(for: display.id)) {
                    Text("Same as All Displays").tag(URL?.none)
                    Divider()
                    ForEach(allItems) { item in
                        Text(item.name).tag(URL?.some(item.url))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private var allDisplaysSelection: Binding<URL?> {
        Binding(
            get: { assignments.allDisplays },
            set: { url in if let url { manager.start(with: url) } }
        )
    }

    private func selection(for displayID: String) -> Binding<URL?> {
        Binding(
            get: { assignments.perDisplay[displayID] },
            set: { url in
                if let url {
                    manager.assign(url, to: .display(displayID))
                } else {
                    manager.clearOverride(forDisplay: displayID)
                }
            }
        )
    }

    // MARK: - Strip

    private var wallpaperStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drag a wallpaper onto a display")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(allItems) { item in
                        WallpaperChip(item: item)
                    }
                }
            }
            .scrollIndicators(.visible)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(height: 124)
    }
}

/// One display in the arrangement.
private struct MiniScreen: View {
    let display: DisplayInfo
    let url: URL?
    let wallpaperName: String?
    let hasOverride: Bool
    let isRunning: Bool
    let onDrop: (URL) -> Void
    let onClearOverride: () -> Void

    var body: some View {
        DropTile(onDrop: onDrop) { isTargeted in
            ZStack(alignment: .bottomLeading) {
                PosterImage(url: url)
                    .saturation(isRunning ? 1 : 0.2)
                if display.isMain {
                    // The menu bar marks the main display, as in System Settings.
                    Rectangle()
                        .fill(.white.opacity(0.75))
                        .frame(height: 4)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(display.name)
                        .font(.caption.weight(.semibold))
                    Text(wallpaperName ?? String(localized: "No wallpaper"))
                        .font(.caption2)
                        .opacity(0.85)
                }
                .lineLimit(1)
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isTargeted ? Color.accentColor : Color.gray.opacity(0.5), lineWidth: isTargeted ? 3 : 1)
            )
        }
        .contextMenu {
            if hasOverride {
                Button("Use All Displays Wallpaper", action: onClearOverride)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(display.name), \(wallpaperName ?? String(localized: "No wallpaper"))"))
        .help(hasOverride ? Text("Custom wallpaper for this display") : Text("Uses the All Displays wallpaper"))
    }
}

/// Accepts a dragged wallpaper and highlights while one hovers over it.
private struct DropTile<Content: View>: View {
    let onDrop: (URL) -> Void
    @ViewBuilder let content: (Bool) -> Content
    @State private var isTargeted = false

    var body: some View {
        content(isTargeted)
            .contentShape(.rect)
            .dropDestination(for: WallpaperDragPayload.self) { payloads, _ in
                guard let url = payloads.first?.url else { return false }
                onDrop(url)
                return true
            } isTargeted: { isTargeted = $0 }
    }
}

/// A draggable wallpaper in the strip.
private struct WallpaperChip: View {
    let item: WallpaperItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PosterImage(url: item.url)
                .frame(width: 112, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
        }
        .draggable(WallpaperDragPayload(url: item.url)) {
            PosterImage(url: item.url)
                .frame(width: 112, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .help(Text("Drag onto a display"))
        .accessibilityElement(children: .combine)
    }
}
