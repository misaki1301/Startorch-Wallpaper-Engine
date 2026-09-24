import CoreMedia

/// The time math behind a trimmed, optionally seamless loop. Pure, so it can be tested
/// without building a composition.
///
/// With a crossfade of `N` seconds over the trimmed clip `[in, out]` (duration `D`):
///
/// ```
/// source:  in ── in+N ─────────────── out-N ── out
///            (B)  └──── main segment (A) ─────────┘
/// output:  0 ───────────── D-2N ────── D-N
///          │ A plays alone │ A fades out │
///          │               │ over B      │
/// ```
///
/// Track A plays `[in+N, out]` from output time 0. Track B plays the clip's first `N` seconds,
/// `[in, in+N]`, underneath A's last `N` seconds while A's opacity ramps from 1 to 0. The
/// output ends on source time `in+N` (all B) and starts over on `in+N` (all A), so the wrap
/// is continuous. The output is `N` seconds shorter than the trimmed clip.
///
/// Without a crossfade, the output is simply the trimmed clip.
nonisolated struct LoopCompositionPlan: Equatable, Sendable {
    /// Seconds. The default the studio suggests.
    static let defaultCrossfade: Double = 0.5
    /// The crossfade can never be more than this fraction of the trimmed clip, so the part
    /// that plays alone is always at least as long as the crossfade itself.
    static let maximumCrossfadeFraction: Double = 1.0 / 3.0
    /// Crossfades shorter than this (about one frame at 30 fps) are dropped entirely.
    static let minimumCrossfade: Double = 1.0 / 30.0
    static let timescale: CMTimeScale = 600

    /// A piece of the source placed on the output timeline.
    struct Segment: Equatable, Sendable {
        var source: CMTimeRange
        var outputStart: CMTime

        var outputRange: CMTimeRange { CMTimeRange(start: outputStart, duration: source.duration) }
    }

    /// The part of the source that was kept.
    let trim: CMTimeRange
    /// The crossfade actually applied, after clamping. `.zero` when there's none.
    let crossfade: CMTime
    /// Track A: the trimmed clip, minus its first `crossfade` seconds when looping.
    let main: Segment
    /// Track B: the clip's first `crossfade` seconds, laid under the end of `main`.
    let seam: Segment?

    var hasCrossfade: Bool { seam != nil }
    var outputDuration: CMTime { main.source.duration }
    /// Output time where only track A is shown.
    var passthroughRange: CMTimeRange {
        CMTimeRange(start: .zero, duration: outputDuration - crossfade)
    }
    /// Output time where A fades out over B, if looping.
    var crossfadeRange: CMTimeRange? { seam?.outputRange }

    /// - Parameters:
    ///   - trim: the part of the source to keep, clamped to `sourceDuration`.
    ///   - crossfade: requested crossfade in seconds; clamped by `effectiveCrossfade`.
    init(sourceDuration: CMTime, trim requestedTrim: CMTimeRange? = nil, crossfade requested: Double = 0) {
        let trim = Self.clampedTrim(requestedTrim, sourceDuration: sourceDuration)
        let fade = Self.effectiveCrossfade(requested: requested, clipDuration: trim.duration.seconds)
        let crossfade = fade > 0 ? CMTime(seconds: fade, preferredTimescale: Self.timescale) : .zero
        self.trim = trim
        self.crossfade = crossfade

        if crossfade > .zero {
            let mainSource = CMTimeRange(start: trim.start + crossfade, end: trim.end)
            main = Segment(source: mainSource, outputStart: .zero)
            seam = Segment(
                source: CMTimeRange(start: trim.start, duration: crossfade),
                outputStart: mainSource.duration - crossfade
            )
        } else {
            main = Segment(source: trim, outputStart: .zero)
            seam = nil
        }
    }

    /// The crossfade (seconds) that fits in a clip of `clipDuration` seconds: never negative,
    /// never more than `maximumCrossfadeFraction` of the clip, and 0 when that leaves less
    /// than `minimumCrossfade`.
    static func effectiveCrossfade(requested: Double, clipDuration: Double) -> Double {
        guard requested.isFinite, requested > 0, clipDuration.isFinite, clipDuration > 0 else { return 0 }
        let capped = min(requested, clipDuration * maximumCrossfadeFraction)
        // Round to the plan's timescale so the reported value matches what gets rendered. The
        // epsilon keeps e.g. 0.9 / 3 (0.29999…) from losing a whole tick.
        let rounded = (capped * Double(timescale) + 1e-6).rounded(.down) / Double(timescale)
        return rounded >= minimumCrossfade ? rounded : 0
    }

    /// The largest crossfade a clip of `clipDuration` seconds allows. Drives the slider range.
    static func maximumCrossfade(clipDuration: Double) -> Double {
        guard clipDuration.isFinite, clipDuration > 0 else { return 0 }
        return clipDuration * maximumCrossfadeFraction
    }

    static func clampedTrim(_ trim: CMTimeRange?, sourceDuration: CMTime) -> CMTimeRange {
        let full = CMTimeRange(start: .zero, duration: sourceDuration.isNumeric ? sourceDuration : .zero)
        guard let trim, trim.isValid, !trim.isEmpty, trim.start.isNumeric, trim.duration.isNumeric else {
            return full
        }
        let clamped = trim.intersection(full)
        return clamped.isEmpty ? full : clamped
    }
}
