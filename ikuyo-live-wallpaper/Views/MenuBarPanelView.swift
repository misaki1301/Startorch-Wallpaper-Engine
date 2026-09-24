import SwiftUI

/// The `MenuBarExtra`'s `.window`-style content: everything you need day-to-day without opening
/// the main window. Built from plain SwiftUI controls (not `Menu`/`Button` menu items), so Tab
/// and Space work like any other window and VoiceOver reads it the same way.
struct MenuBarPanelView: View {
    let stats: SystemStatsService

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(WallpaperManager.self) private var manager
    @Environment(WallpaperLibrary.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            nowPlayingSection

            PlaybackControlsRow()

            if let reason = manager.pauseReason, reason != .user {
                Text("Paused: \(reason.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Paused, \(reason.label)"))
            }

            if !library.favoriteCatalogItems.isEmpty {
                Divider()
                favoritesSection
            }

            Divider()

            StatsMenuView(stats: stats)

            Divider()

            actionsSection
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: - Now Playing

    @ViewBuilder
    private var nowPlayingSection: some View {
        if let url = manager.currentURL {
            HStack(spacing: 10) {
                NowPlayingPosterView(url: url)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Now Playing")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(WallpaperItem(url: url).name)
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        } else {
            HStack {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No Wallpaper Running")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Favorites

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Favorites")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(library.favoriteCatalogItems) { item in
                        FavoriteThumbnailButton(item: item, isCurrent: manager.currentURL == item.url) {
                            manager.start(with: item.url)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Open StarTorch…") {
                NSApplication.shared.activate()
                openWindow(id: MainWindow.id)
            }
            .buttonStyle(.borderless)

            Button("Settings…") {
                NSApplication.shared.activate()
                openSettings()
            }
            .keyboardShortcut(",")
            .buttonStyle(.borderless)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .buttonStyle(.borderless)
        }
    }
}

/// Play/Pause and Stop, sized for the menu bar panel rather than a toolbar.
private struct PlaybackControlsRow: View {
    @Environment(WallpaperManager.self) private var manager
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack(spacing: 8) {
            if manager.isActive && !manager.isPaused {
                Button("Pause", systemImage: "pause.fill") { manager.pause() }
            } else {
                Button(manager.isActive ? "Resume" : "Start", systemImage: "play.fill") {
                    manager.play(orStart: settings.availableLastWallpaperURL())
                }
                .disabled(!manager.isActive && settings.availableLastWallpaperURL() == nil)
            }

            Button("Stop", systemImage: "stop.fill") { manager.stop() }
                .disabled(!manager.isActive)

            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

/// A single favorite in the horizontal strip: a small poster you can click to start it.
private struct FavoriteThumbnailButton: View {
    let item: WallpaperItem
    let isCurrent: Bool
    let action: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.fill.quaternary)
                    .frame(width: 64, height: 40)
                    .overlay {
                        if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 64, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(item.name)
        .accessibilityLabel(Text(isCurrent ? "\(item.name), current wallpaper" : item.name))
        .accessibilityHint(Text("Sets this as the wallpaper"))
        .task(id: item.url) {
            thumbnail = await VideoThumbnailLoader.thumbnail(for: item.url, maxSize: CGSize(width: 128, height: 80))
        }
    }
}

/// The Now Playing thumbnail. Kept separate so its own `.task` only reloads when the URL changes.
private struct NowPlayingPosterView: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.fill.quaternary)
            .frame(width: 48, height: 30)
            .overlay {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .accessibilityHidden(true)
            .task(id: url) {
                thumbnail = await VideoThumbnailLoader.thumbnail(for: url, maxSize: CGSize(width: 96, height: 60))
            }
    }
}

/// CPU/RAM, shown while the panel is visible only — `SystemStatsService` polls on `onAppear` and
/// stops on `onDisappear`.
struct StatsMenuView: View {
    @ObservedObject var stats: SystemStatsService

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("CPU:")
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f%%", stats.cpuUsage))
                    .monospacedDigit()
                Spacer()
            }

            HStack {
                Text("RAM:")
                    .foregroundStyle(.secondary)
                Text("\(stats.memoryUsedFormatted) / \(stats.memoryTotalFormatted)")
                    .monospacedDigit()
                Spacer()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("CPU \(String(format: "%.0f", stats.cpuUsage)) percent. Memory \(stats.memoryUsedFormatted) of \(stats.memoryTotalFormatted)."))
        // The menu bar extra's content view stays alive even while the menu is closed, so without
        // this the 2-second poll would run for the app's entire lifetime for no reason.
        .onAppear { stats.start() }
        .onDisappear { stats.stop() }
    }
}
