import AVFoundation
import AppKit
import SwiftUI
import Testing
@testable import StarTorch_Wallpaper_Engine

/// Regression coverage for the AVKit `VideoPlayer` crash (`getSuperclassMetadata` /
/// `_AVKit_SwiftUI`, see the PR description): `WallpaperCardView`'s hover preview used to build a
/// SwiftUI `VideoPlayer`, which on macOS 27 could abort while the Swift runtime resolved the
/// backing class's superclass metadata. It's now backed by the plain `NSViewRepresentable`
/// `PlayerLayerView` (an `AVPlayerLayer`), which never touches that AVKit SwiftUI overlay type.
///
/// These tests host the real view in an `NSHostingView` — inside an offscreen `NSWindow` so
/// SwiftUI actually runs the view's lifecycle (`.onAppear`, `.task`) instead of leaving it
/// unattached — and inspect the resulting `CALayer` tree instead of the view's private `@State`.
@MainActor
struct WallpaperCardViewTests {
    private func makeItem() async throws -> WallpaperItem {
        let dir = try makeTempDirectory()
        let url = dir.appending(path: "sample.mp4")
        try await makeTinyTestVideo(at: url)
        return WallpaperItem(url: url)
    }

    /// Hosts `view` in a real (offscreen) window and forces a layout pass, so SwiftUI builds the
    /// full view tree — including any `NSViewRepresentable` — the way it would on screen.
    private func host(_ view: WallpaperCardView) -> NSHostingView<WallpaperCardView> {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 200)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)

        hosting.layoutSubtreeIfNeeded()
        // `.onAppear` / `.task` are scheduled on the run loop rather than run synchronously by
        // `layoutSubtreeIfNeeded`; give them a moment to execute before inspecting the result.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    private func hasPlayerLayer(_ layer: CALayer?) -> Bool {
        guard let layer else { return false }
        if layer is AVPlayerLayer { return true }
        return (layer.sublayers ?? []).contains { hasPlayerLayer($0) }
    }

    /// Walks the AppKit view tree (not just one layer) looking for an `AVPlayerLayer` anywhere —
    /// `PlayerLayerView` puts it a few `NSView`s deep inside the SwiftUI-hosted hierarchy.
    private func anyPlayerLayer(in view: NSView) -> Bool {
        if hasPlayerLayer(view.layer) { return true }
        return view.subviews.contains { anyPlayerLayer(in: $0) }
    }

    private func makeCard(item: WallpaperItem, startsHovering: Bool) -> WallpaperCardView {
        WallpaperCardView(
            item: item,
            isActive: false,
            isSelected: false,
            isFavorite: false,
            downloadState: nil,
            hideDownloadBadge: false,
            onSelect: {},
            onApply: {},
            onToggleFavorite: {},
            startsHoveringForTesting: startsHovering
        )
    }

    @Test func nonHoveringCardHostsWithoutCrashingAndCreatesNoPlayer() async throws {
        let item = try await makeItem()
        let hosting = host(makeCard(item: item, startsHovering: false))

        #expect(!anyPlayerLayer(in: hosting))
    }

    @Test func hoveringCardHostsWithoutCrashingAndBacksThePreviewWithAPlayerLayer() async throws {
        let item = try await makeItem()
        let hosting = host(makeCard(item: item, startsHovering: true))

        // The old `VideoPlayer(player:)` crashed while SwiftUI instantiated its AVKit backing
        // class right around here; reaching this point at all is the regression check. The
        // `AVPlayerLayer` confirms the hover preview is actually wired up, not just absent.
        #expect(anyPlayerLayer(in: hosting))
    }

    @Test func importedItemWithNoPosterOrFocalPointHostsCleanly() async throws {
        // Mirrors a legacy import: a real video, no poster, no focal point — the exact shape of
        // `ImportedWallpaperStoreTests.legacyImportWithNoSidecarDataLoadsCleanly`'s file.
        let item = try await makeItem()
        #expect(item.posterURL == nil)
        #expect(item.focalPoint == nil)

        let hovering = host(makeCard(item: item, startsHovering: true))
        let notHovering = host(makeCard(item: item, startsHovering: false))

        #expect(anyPlayerLayer(in: hovering))
        #expect(!anyPlayerLayer(in: notHovering))
    }
}
