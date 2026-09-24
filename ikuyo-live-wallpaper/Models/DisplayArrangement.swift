import AppKit

/// A connected display as the Displays view shows it.
nonisolated struct DisplayInfo: Identifiable, Equatable, Sendable {
    /// The stable display UUID.
    let id: String
    let name: String
    /// In AppKit's global coordinates (origin at the bottom left of the main display).
    let frame: CGRect
    let isMain: Bool
}

extension DisplayInfo {
    /// The connected displays, the main display first.
    static var connected: [DisplayInfo] {
        let screens = NSScreen.screens
        return screens.enumerated().compactMap { index, screen in
            screen.displayUUID.map {
                DisplayInfo(id: $0, name: screen.localizedName, frame: screen.frame, isMain: index == 0)
            }
        }
    }
}

/// Lays displays out like System Settings → Displays: proportional to their frames, arranged as
/// they are physically, scaled to fit and centered.
nonisolated enum DisplayArrangement {
    /// Scales `frames` (AppKit global coordinates, y up) into a view of `size` (y down).
    /// Adjacent displays are inset by `spacing / 2` so they read as separate screens.
    static func fit(_ frames: [String: CGRect], in size: CGSize, spacing: CGFloat = 6) -> [String: CGRect] {
        guard let first = frames.values.first, size.width > 0, size.height > 0 else { return [:] }
        let union = frames.values.reduce(first) { $0.union($1) }
        guard union.width > 0, union.height > 0 else { return [:] }

        let scale = min(size.width / union.width, size.height / union.height)
        let offset = CGPoint(
            x: (size.width - union.width * scale) / 2,
            y: (size.height - union.height * scale) / 2
        )
        return frames.mapValues { frame in
            CGRect(
                x: offset.x + (frame.minX - union.minX) * scale,
                y: offset.y + (union.maxY - frame.maxY) * scale,
                width: frame.width * scale,
                height: frame.height * scale
            )
            .insetBy(dx: spacing / 2, dy: spacing / 2)
        }
    }
}
