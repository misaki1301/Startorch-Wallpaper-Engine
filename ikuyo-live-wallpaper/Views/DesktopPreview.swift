import AVFoundation
import SwiftUI

/// A miniature of the desktop with the wallpaper on it — menu bar, a few icons and the Dock — so
/// legibility can be judged before applying. Honors the wallpaper's readability settings.
struct DesktopPreview: View {
    let poster: NSImage?
    /// Plays instead of the poster when set (muted, at the wallpaper's speed).
    let player: AVPlayer?
    let readability: ReadabilitySettings
    /// The menu bar text color macOS would pick for this wallpaper.
    let usesDarkMenuBarText: Bool

    /// The size of the display being imitated, in points.
    private let screenSize: CGSize = NSScreen.main?.frame.size ?? CGSize(width: 1512, height: 982)

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / max(screenSize.width, 1)
            ZStack {
                wallpaper(scale: scale)
                if readability.dim > 0 {
                    Color.black.opacity(readability.dim)
                }
                if readability.vignette {
                    vignette(in: proxy.size)
                }
                desktopIcons(scale: scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                dock(scale: scale)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                menuBar(scale: scale)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(screenSize.width / max(screenSize.height, 1), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview of the wallpaper on the desktop"))
    }

    // MARK: - Layers

    @ViewBuilder
    private func wallpaper(scale: CGFloat) -> some View {
        if let player {
            PlayerLayerView(player: player, blurRadius: readability.blur * scale)
        } else if let poster {
            Image(nsImage: poster)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: readability.blur * scale, opaque: true)
        } else {
            Rectangle()
                .fill(.fill.quaternary)
                .overlay { ProgressView() }
        }
    }

    private func vignette(in size: CGSize) -> some View {
        RadialGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: ReadabilitySettings.vignetteInnerRadius),
                .init(color: .black.opacity(ReadabilitySettings.vignetteOpacity), location: 1),
            ],
            center: .center,
            startRadius: 0,
            endRadius: hypot(size.width, size.height) / 2
        )
    }

    /// Real proportions would make everything unreadably small in a 300 pt preview, so the
    /// chrome is drawn at least this large.
    private func chrome(_ points: CGFloat, _ scale: CGFloat, minimum: CGFloat) -> CGFloat {
        max(points * scale, minimum)
    }

    private func menuBar(scale: CGFloat) -> some View {
        let height = chrome(24, scale, minimum: 11)
        let font = Font.system(size: chrome(13, scale, minimum: 7), weight: .medium)
        let color: Color = usesDarkMenuBarText ? .black : .white
        return HStack(spacing: height * 0.6) {
            Image(systemName: "apple.logo")
            Text("Finder").bold()
            Text("File")
            Text("Edit")
            Text("View")
            Spacer(minLength: 0)
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text(Date.now, format: .dateTime.hour().minute())
        }
        .font(font)
        .foregroundStyle(color)
        .lineLimit(1)
        .padding(.horizontal, height * 0.5)
        .frame(height: height)
        // The real menu bar is translucent; a faint tint in the text's opposite color.
        .background((usesDarkMenuBarText ? Color.white : Color.black).opacity(0.12))
    }

    private func desktopIcons(scale: CGFloat) -> some View {
        let size = chrome(56, scale, minimum: 18)
        return VStack(spacing: size * 0.35) {
            desktopIcon("folder.fill", "Projects", size: size, tint: .blue)
            desktopIcon("doc.fill", "Notes.txt", size: size, tint: .white)
            desktopIcon("externaldrive.fill", "Backup", size: size, tint: .gray)
        }
        .padding(.top, chrome(24, scale, minimum: 11) + size * 0.3)
        .padding(.trailing, size * 0.4)
    }

    private func desktopIcon(_ symbol: String, _ name: String, size: CGFloat, tint: Color) -> some View {
        VStack(spacing: size * 0.08) {
            Image(systemName: symbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(tint)
                .frame(width: size * 0.7, height: size * 0.6)
            // Desktop icon labels are white with a shadow.
            Text(verbatim: name)
                .font(.system(size: max(size * 0.2, 6), weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 1, y: 0.5)
                .lineLimit(1)
        }
        .frame(width: size * 1.3)
    }

    private func dock(scale: CGFloat) -> some View {
        let tile = chrome(48, scale, minimum: 12)
        let colors: [Color] = [.blue, .green, .orange, .pink, .purple, .teal]
        return HStack(spacing: tile * 0.2) {
            ForEach(colors.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: tile * 0.22)
                    .fill(colors[index].gradient)
                    .frame(width: tile, height: tile)
            }
        }
        .padding(tile * 0.18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: tile * 0.35))
        .padding(.bottom, tile * 0.12)
    }
}

/// An `AVPlayerLayer` for SwiftUI, with the same Core Image blur the desktop windows use
/// (SwiftUI's `.blur` doesn't reach into AppKit-hosted layers).
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var blurRadius: Double = 0

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(playerLayer)
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let playerLayer = view.layer?.sublayers?.first as? AVPlayerLayer else { return }
        if playerLayer.player !== player { playerLayer.player = player }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let outset = blurRadius * 2
        playerLayer.frame = view.bounds.insetBy(dx: -outset, dy: -outset)
        if blurRadius > 0, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(blurRadius, forKey: kCIInputRadiusKey)
            playerLayer.filters = [blur]
        } else {
            playerLayer.filters = nil
        }
        CATransaction.commit()
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view.layer?.sublayers?.first as? AVPlayerLayer)?.player = nil
    }
}
