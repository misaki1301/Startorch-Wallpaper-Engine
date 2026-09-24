import AVFoundation
import SwiftUI

/// A filmstrip of the source with draggable in/out handles, the playhead and the poster
/// marker. Clicking or dragging anywhere on the strip scrubs; dragging a handle moves that end
/// of the trim (and shows the frame under it). With a loop crossfade, the head and tail that
/// get blended are shaded.
struct TrimTimelineView: View {
    let sourceURL: URL
    let duration: Double
    @Binding var trim: TrimSelection
    let playhead: Double
    let posterTime: Double?
    /// Effective crossfade in seconds, 0 for none.
    let crossfade: Double
    let onScrub: (Double) -> Void

    @State private var filmstrip: [NSImage] = []

    private static let height: CGFloat = 54
    private static let handleWidth: CGFloat = 12
    private static let frameCount = 10
    private static let space = "trim-timeline"

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let startX = xPosition(trim.start, width: width)
            let endX = xPosition(trim.end, width: width)

            ZStack(alignment: .topLeading) {
                filmstripView(width: width)

                // Outside the trim is dimmed.
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: startX, height: Self.height)
                Rectangle().fill(.black.opacity(0.6))
                    .frame(width: max(0, width - endX), height: Self.height)
                    .offset(x: endX)

                if crossfade > 0 {
                    seamShading(x: startX, width: xPosition(crossfade, width: width))
                    seamShading(x: endX - xPosition(crossfade, width: width), width: xPosition(crossfade, width: width))
                }

                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: max(0, endX - startX), height: Self.height)
                    .offset(x: startX)
                    .allowsHitTesting(false)

                if let posterTime {
                    posterMarker
                        .offset(x: xPosition(posterTime, width: width) - 5, y: -12)
                }

                Rectangle()
                    .fill(.white)
                    .shadow(color: .black, radius: 1)
                    .frame(width: 2, height: Self.height + 6)
                    .offset(x: xPosition(playhead, width: width) - 1, y: -3)
                    .allowsHitTesting(false)

                handle(isStart: true, width: width)
                    .offset(x: startX - Self.handleWidth / 2)
                handle(isStart: false, width: width)
                    .offset(x: endX - Self.handleWidth / 2)
            }
            .frame(width: width, height: Self.height, alignment: .topLeading)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in onScrub(time(at: value.location.x, width: width)) }
            )
            .coordinateSpace(name: Self.space)
            .accessibilityElement(children: .contain)
        }
        .frame(height: Self.height)
        .padding(.top, 12)
        .task(id: duration) { await loadFilmstrip() }
    }

    // MARK: - Pieces

    private func filmstripView(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if filmstrip.isEmpty {
                Rectangle().fill(.fill.tertiary)
            } else {
                ForEach(filmstrip.indices, id: \.self) { index in
                    Image(nsImage: filmstrip[index])
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(filmstrip.count), height: Self.height)
                        .clipped()
                }
            }
        }
        .frame(width: width, height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }

    private func seamShading(x: CGFloat, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.35))
            .frame(width: max(0, width), height: Self.height)
            .offset(x: x)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var posterMarker: some View {
        Image(systemName: "photo.fill")
            .font(.system(size: 9))
            .foregroundStyle(.white)
            .padding(2)
            .background(Color.orange, in: RoundedRectangle(cornerRadius: 2))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func handle(isStart: Bool, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .overlay {
                Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 16)
            }
            .frame(width: Self.handleWidth, height: Self.height)
            .contentShape(.rect)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        let seconds = time(at: value.location.x, width: width)
                        if isStart { trim.setStart(seconds) } else { trim.setEnd(seconds) }
                        onScrub(isStart ? trim.start : trim.end)
                    }
            )
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .accessibilityElement()
            .accessibilityLabel(isStart ? Text("Trim Start") : Text("Trim End"))
            .accessibilityValue(Text(Self.timestamp(isStart ? trim.start : trim.end)))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.1 : -0.1
                if isStart { trim.setStart(trim.start + step) } else { trim.setEnd(trim.end + step) }
                onScrub(isStart ? trim.start : trim.end)
            }
    }

    // MARK: - Geometry

    private func xPosition(_ seconds: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(seconds / duration, 0), 1)) * width
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * duration
    }

    static func timestamp(_ seconds: Double) -> String {
        let seconds = seconds.isFinite ? max(0, seconds) : 0
        let minutes = Int(seconds) / 60
        let rest = seconds - Double(minutes * 60)
        return String(format: "%d:%05.2f", minutes, rest)
    }

    // MARK: - Filmstrip

    private func loadFilmstrip() async {
        guard duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        var frames: [NSImage] = []
        for index in 0..<Self.frameCount {
            let seconds = duration * (Double(index) + 0.5) / Double(Self.frameCount)
            guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else {
                continue
            }
            frames.append(NSImage(cgImage: image, size: .zero))
            if Task.isCancelled { return }
        }
        filmstrip = frames
    }
}
