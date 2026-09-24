import CoreMedia

/// The in/out points picked on the import studio's timeline, in source seconds. Moving one
/// handle never lets the selection get shorter than `minimumLength` or leave the clip.
nonisolated struct TrimSelection: Equatable, Sendable {
    static let minimumLength: Double = 0.5
    /// In/out points closer than this to the clip's ends count as untrimmed.
    static let tolerance: Double = 0.01

    let duration: Double
    private(set) var start: Double
    private(set) var end: Double

    init(duration: Double) {
        let duration = duration.isFinite ? max(0, duration) : 0
        self.duration = duration
        start = 0
        end = duration
    }

    var length: Double { end - start }

    var isTrimmed: Bool {
        start > Self.tolerance || end < duration - Self.tolerance
    }

    /// The range to export, or `nil` for the whole clip.
    var timeRange: CMTimeRange? {
        guard isTrimmed else { return nil }
        return CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
    }

    /// The shortest selection this clip allows: `minimumLength`, or the whole of a clip
    /// shorter than that.
    private var minimumLength: Double { min(Self.minimumLength, duration) }

    mutating func setStart(_ seconds: Double) {
        guard seconds.isFinite else { return }
        start = min(max(0, seconds), end - minimumLength)
    }

    mutating func setEnd(_ seconds: Double) {
        guard seconds.isFinite else { return }
        end = max(min(duration, seconds), start + minimumLength)
    }

    mutating func reset() {
        start = 0
        end = duration
    }

    /// `seconds` pulled inside the selection.
    func clamp(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return start }
        return min(max(seconds, start), end)
    }
}
