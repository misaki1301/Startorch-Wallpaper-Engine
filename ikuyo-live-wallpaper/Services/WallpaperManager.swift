import AppKit
import AVKit
import SwiftUI

@MainActor
@Observable
final class WallpaperManager {
    private var windows: [NSWindow] = []
    private var player: AVPlayer?
    private var playerLayers: [AVPlayerLayer] = []
    private var playerObserver: NSObjectProtocol?
    private var isStopping = false

    private(set) var isActive = false
    private(set) var currentURL: URL?
    private var originalWallpaperURLs: [NSScreen: URL] = [:]

    func start(with url: URL) {
        if isActive { stop() }
        isStopping = false

        hideDesktopWallpaper()

        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.play()
        self.player = player
        currentURL = url

        playerObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { notification in
            guard let item = notification.object as? AVPlayerItem else { return }
            item.seek(to: .zero, completionHandler: nil)
        }

        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))

        for screen in NSScreen.screens {
            let screenRect = screen.frame
            let viewRect = CGRect(origin: .zero, size: screenRect.size)

            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.videoGravity = .resizeAspectFill
            playerLayer.frame = viewRect
            playerLayers.append(playerLayer)

            let contentView = NSView(frame: viewRect)
            contentView.wantsLayer = true
            contentView.layer?.addSublayer(playerLayer)

            let window = NSWindow(
                contentRect: screenRect,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = NSWindow.Level(rawValue: desktopLevel + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.contentView = contentView
            window.orderFrontRegardless()

            windows.append(window)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        isActive = true
    }

    func pause() {
        player?.pause()
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        restoreDesktopWallpaper()

        player?.pause()
        player = nil

        for layer in playerLayers {
            layer.removeFromSuperlayer()
        }
        playerLayers.removeAll()

        for window in windows {
            window.contentView = nil
            window.orderOut(nil)
        }
        windows.removeAll()

        if let observer = playerObserver {
            NotificationCenter.default.removeObserver(observer)
            playerObserver = nil
        }
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)

        currentURL = nil
        isActive = false
    }

    private func hideDesktopWallpaper() {
        originalWallpaperURLs = [:]
        for screen in NSScreen.screens {
            originalWallpaperURLs[screen] = NSWorkspace.shared.desktopImageURL(for: screen)
            writeSolidColorImage()
            try? NSWorkspace.shared.setDesktopImageURL(solidColorURL, for: screen, options: [
                .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
                .allowClipping: true,
            ])
        }
    }

    private func restoreDesktopWallpaper() {
        for screen in NSScreen.screens {
            if let original = originalWallpaperURLs[screen] {
                try? NSWorkspace.shared.setDesktopImageURL(original, for: screen, options: [:])
            }
        }
        originalWallpaperURLs = [:]
    }

    private let solidColorURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ikuyo_solid_bg")
        .appendingPathExtension("png")

    private func writeSolidColorImage() {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.black.drawSwatch(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        image.unlockFocus()
        if let data = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: data),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: solidColorURL)
        }
    }

    @objc private func screenParametersDidChange() {
        guard isActive, let currentURL = (player?.currentItem?.asset as? AVURLAsset)?.url else { return }
        stop()
        start(with: currentURL)
    }
}
