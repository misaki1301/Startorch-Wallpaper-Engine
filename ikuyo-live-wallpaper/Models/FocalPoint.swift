import CoreGraphics

/// The part of a video that must stay on screen when it's aspect-filled onto a display with a
/// different shape, in normalized video coordinates: (0, 0) is the top-left corner of the
/// upright picture, (1, 1) the bottom-right, (0.5, 0.5) the center.
nonisolated struct FocalPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double

    static let center = FocalPoint(x: 0.5, y: 0.5)

    init(x: Double, y: Double) {
        self.x = Self.clamp(x)
        self.y = Self.clamp(y)
    }

    /// The focal point under `location` in a view that shows the video at `videoRect`
    /// (both in the same top-left-origin coordinate space). Points outside the video clamp to
    /// its edge.
    init(location: CGPoint, in videoRect: CGRect) {
        guard videoRect.width > 0, videoRect.height > 0 else {
            self = .center
            return
        }
        self.init(
            x: (location.x - videoRect.minX) / videoRect.width,
            y: (location.y - videoRect.minY) / videoRect.height
        )
    }

    /// Where this focal point sits in a view that shows the video at `videoRect`.
    func location(in videoRect: CGRect) -> CGPoint {
        CGPoint(x: videoRect.minX + x * videoRect.width, y: videoRect.minY + y * videoRect.height)
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0.5
    }
}

/// Aspect-fill layout that keeps a focal point on screen: the video is scaled to cover
/// `bounds` exactly as `.resizeAspectFill` would, but instead of always cropping evenly from
/// both sides it's shifted so the focal point lands as close to the center of `bounds` as
/// possible without exposing an edge.
///
/// The renderer doesn't use this yet (see the Phase 5C PR); it's the hook for applying the
/// stored focal point: lay the video out at `aspectFillFrame(...)` inside a layer that clips
/// to its bounds.
nonisolated enum FocalPointLayout {
    static func aspectFillFrame(
        contentSize: CGSize,
        in bounds: CGRect,
        focalPoint: FocalPoint = .center
    ) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }
        let scale = max(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)

        func origin(extent: CGFloat, available: CGFloat, focus: Double, minEdge: CGFloat) -> CGFloat {
            let overflow = extent - available
            guard overflow > 0.0001 else { return minEdge - overflow / 2 }
            // Put the focal point in the middle of the visible area, then clamp so the video
            // still covers the whole of it.
            let ideal = available / 2 - CGFloat(focus) * extent
            return minEdge + min(0, max(-overflow, ideal))
        }

        return CGRect(
            x: origin(extent: size.width, available: bounds.width, focus: focalPoint.x, minEdge: bounds.minX),
            y: origin(extent: size.height, available: bounds.height, focus: focalPoint.y, minEdge: bounds.minY),
            width: size.width,
            height: size.height
        )
    }

    /// The part of the video (in normalized video coordinates, top-left origin) that stays
    /// visible on a screen of `screenAspect` (width / height). Used to preview the crop.
    static func visibleRegion(
        contentSize: CGSize,
        screenAspect: CGFloat,
        focalPoint: FocalPoint
    ) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0, screenAspect > 0, screenAspect.isFinite else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let bounds = CGRect(x: 0, y: 0, width: screenAspect, height: 1)
        let frame = aspectFillFrame(contentSize: contentSize, in: bounds, focalPoint: focalPoint)
        return CGRect(
            x: (bounds.minX - frame.minX) / frame.width,
            y: (bounds.minY - frame.minY) / frame.height,
            width: bounds.width / frame.width,
            height: bounds.height / frame.height
        )
    }
}
