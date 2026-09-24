import AVFoundation
import SwiftUI

/// The import studio's video preview. The video is letterboxed (aspect-fit) so the whole frame
/// is visible; while `isEditingFocalPoint` is on, clicking or dragging on it moves the focal
/// point, and the part a display of `screenAspect` would show is outlined.
struct StudioPreviewView: View {
    let player: AVPlayer
    /// The upright video size; `.zero` until the metadata has loaded.
    let videoSize: CGSize
    @Binding var focalPoint: FocalPoint?
    let isEditingFocalPoint: Bool
    /// Width / height of the display the crop outline previews.
    let screenAspect: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let videoRect = videoSize.width > 0 && videoSize.height > 0
                ? AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
                : bounds

            ZStack(alignment: .topLeading) {
                PlayerLayerView(player: player)

                if isEditingFocalPoint {
                    cropOutline(in: videoRect)
                }
                if isEditingFocalPoint || focalPoint != nil {
                    focalMarker(at: (focalPoint ?? .center).location(in: videoRect))
                }
                if isEditingFocalPoint {
                    // A SwiftUI layer above the AppKit player view, so the drag reaches SwiftUI.
                    Color.clear
                        .contentShape(.rect)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    focalPoint = FocalPoint(location: value.location, in: videoRect)
                                }
                        )
                        .onContinuousHover { phase in
                            if case .active = phase { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
                        }
                }
            }
        }
        .background(.black)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Video preview"))
        .accessibilityValue(Text(focalAccessibilityValue))
        .accessibilityAction(named: Text("Move Focal Point Left")) { nudgeFocalPoint(dx: -0.05) }
        .accessibilityAction(named: Text("Move Focal Point Right")) { nudgeFocalPoint(dx: 0.05) }
        .accessibilityAction(named: Text("Move Focal Point Up")) { nudgeFocalPoint(dy: -0.05) }
        .accessibilityAction(named: Text("Move Focal Point Down")) { nudgeFocalPoint(dy: 0.05) }
    }

    private func nudgeFocalPoint(dx: Double = 0, dy: Double = 0) {
        let point = focalPoint ?? .center
        focalPoint = FocalPoint(x: point.x + dx, y: point.y + dy)
    }

    private var focalAccessibilityValue: String {
        let point = focalPoint ?? .center
        return String(localized: "Focal point \(Int(point.x * 100))% across, \(Int(point.y * 100))% down")
    }

    private func focalMarker(at location: CGPoint) -> some View {
        ZStack {
            Circle()
                .strokeBorder(.white, lineWidth: 2)
                .frame(width: 26, height: 26)
            Circle()
                .fill(.white)
                .frame(width: 5, height: 5)
        }
        .shadow(color: .black.opacity(0.6), radius: 2)
        .position(location)
        .allowsHitTesting(false)
    }

    /// Dashed outline of what stays visible when the video is aspect-filled on the display.
    private func cropOutline(in videoRect: CGRect) -> some View {
        let region = FocalPointLayout.visibleRegion(
            contentSize: videoSize,
            screenAspect: screenAspect,
            focalPoint: focalPoint ?? .center
        )
        let rect = CGRect(
            x: videoRect.minX + region.minX * videoRect.width,
            y: videoRect.minY + region.minY * videoRect.height,
            width: region.width * videoRect.width,
            height: region.height * videoRect.height
        )
        return Path { $0.addRect(rect) }
            .stroke(.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .allowsHitTesting(false)
    }
}

/// A bare `AVPlayerLayer` (no controls; the studio has its own transport) that aspect-fits,
/// so the preview geometry is predictable for the focal point overlay.
private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerNSView {
        let view = PlayerLayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }

    static func dismantleNSView(_ nsView: PlayerLayerNSView, coordinator: ()) {
        nsView.playerLayer.player = nil
    }
}

private final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Mouse events go to the SwiftUI overlay, never to the video.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
