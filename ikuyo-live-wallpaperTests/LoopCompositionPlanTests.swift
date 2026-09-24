import CoreMedia
import Testing
@testable import StarTorch_Wallpaper_Engine

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private func range(_ start: Double, _ end: Double) -> CMTimeRange {
    CMTimeRange(start: seconds(start), end: seconds(end))
}

struct LoopCompositionPlanTests {
    @Test func withoutCrossfadeTheOutputIsTheWholeClip() {
        let plan = LoopCompositionPlan(sourceDuration: seconds(10))

        #expect(!plan.hasCrossfade)
        #expect(plan.crossfade == .zero)
        #expect(plan.trim == range(0, 10))
        #expect(plan.main == .init(source: range(0, 10), outputStart: .zero))
        #expect(plan.seam == nil)
        #expect(plan.outputDuration == seconds(10))
        #expect(plan.passthroughRange == range(0, 10))
        #expect(plan.crossfadeRange == nil)
    }

    @Test func trimWithoutCrossfadeKeepsOnlyTheTrimmedRange() {
        let plan = LoopCompositionPlan(sourceDuration: seconds(10), trim: range(2, 7))

        #expect(plan.main.source == range(2, 7))
        #expect(plan.main.outputStart == .zero)
        #expect(plan.outputDuration == seconds(5))
    }

    @Test func crossfadeLaysTheHeadUnderTheTail() {
        // Trim 2…8 (6 s) with a 0.5 s crossfade.
        let plan = LoopCompositionPlan(sourceDuration: seconds(10), trim: range(2, 8), crossfade: 0.5)

        #expect(plan.hasCrossfade)
        #expect(plan.crossfade == seconds(0.5))
        // A: everything after the head, from output 0.
        #expect(plan.main == .init(source: range(2.5, 8), outputStart: .zero))
        // B: the head, starting where A's last 0.5 s start.
        #expect(plan.seam == .init(source: range(2, 2.5), outputStart: seconds(5)))
        #expect(plan.outputDuration == seconds(5.5))
        #expect(plan.passthroughRange == range(0, 5))
        #expect(plan.crossfadeRange == range(5, 5.5))
    }

    @Test func theLoopWrapsOntoTheSameSourceTime() throws {
        let plan = LoopCompositionPlan(sourceDuration: seconds(10), trim: range(1, 9), crossfade: 1)
        let seam = try #require(plan.seam)

        // The output ends on the end of B and starts on the start of A: the same source time.
        #expect(seam.source.end == plan.main.source.start)
        // A and B end together, so the fade finishes exactly at the wrap.
        #expect(seam.outputRange.end == plan.main.outputRange.end)
        // The segments cover the whole trimmed clip exactly once.
        #expect(seam.source.duration + plan.main.source.duration == plan.trim.duration)
    }

    @Test func zeroOrInvalidCrossfadeMeansNone() {
        for requested in [0, -1, .nan, .infinity] as [Double] {
            let plan = LoopCompositionPlan(sourceDuration: seconds(4), crossfade: requested)
            #expect(!plan.hasCrossfade)
            #expect(plan.outputDuration == seconds(4))
        }
    }

    @Test func clipShorterThanTwiceTheCrossfadeIsCapped() {
        // 0.9 s clip, 0.5 s requested: 2×N > D, so N is held to a third of the clip.
        let plan = LoopCompositionPlan(sourceDuration: seconds(0.9), crossfade: 0.5)

        #expect(plan.crossfade == seconds(0.3))
        #expect(plan.outputDuration == seconds(0.6))
        #expect(plan.passthroughRange.duration == seconds(0.3))
        #expect(plan.crossfadeRange == range(0.3, 0.6))
    }

    @Test func crossfadeTooShortToSeeIsDropped() {
        // A third of 0.06 s is 0.02 s: less than a frame.
        let plan = LoopCompositionPlan(sourceDuration: seconds(0.06), crossfade: 0.5)
        #expect(!plan.hasCrossfade)
        #expect(plan.outputDuration == seconds(0.06))
    }

    @Test func effectiveCrossfadeClampsToAFractionOfTheClip() {
        #expect(LoopCompositionPlan.effectiveCrossfade(requested: 0.5, clipDuration: 10) == 0.5)
        #expect(LoopCompositionPlan.effectiveCrossfade(requested: 5, clipDuration: 3) == 1)
        #expect(LoopCompositionPlan.effectiveCrossfade(requested: 0.5, clipDuration: 0) == 0)
        #expect(LoopCompositionPlan.effectiveCrossfade(requested: 0.5, clipDuration: .nan) == 0)
        #expect(LoopCompositionPlan.maximumCrossfade(clipDuration: 6) == 2)
    }

    @Test func trimIsClampedToTheSource() {
        let past = LoopCompositionPlan(sourceDuration: seconds(5), trim: range(3, 9))
        #expect(past.trim == range(3, 5))

        let outside = LoopCompositionPlan(sourceDuration: seconds(5), trim: range(6, 9))
        #expect(outside.trim == range(0, 5))

        let invalid = LoopCompositionPlan(sourceDuration: seconds(5), trim: .invalid)
        #expect(invalid.trim == range(0, 5))
    }
}

struct TrimSelectionTests {
    @Test func startsUntrimmed() {
        let trim = TrimSelection(duration: 8)
        #expect(trim.start == 0 && trim.end == 8)
        #expect(!trim.isTrimmed)
        #expect(trim.timeRange == nil)
    }

    @Test func handlesKeepAMinimumLengthAndStayInsideTheClip() {
        var trim = TrimSelection(duration: 8)
        trim.setStart(-3)
        #expect(trim.start == 0)
        trim.setEnd(20)
        #expect(trim.end == 8)

        trim.setStart(7.9)
        #expect(trim.start == 8 - TrimSelection.minimumLength)
        trim.setEnd(0)
        #expect(trim.end == trim.start + TrimSelection.minimumLength)
    }

    @Test func trimmedSelectionExportsItsRange() {
        var trim = TrimSelection(duration: 8)
        trim.setStart(1)
        trim.setEnd(6)
        #expect(trim.isTrimmed)
        #expect(trim.length == 5)
        #expect(trim.timeRange == range(1, 6))
        #expect(trim.clamp(0.2) == 1)
        #expect(trim.clamp(7) == 6)
        #expect(trim.clamp(3) == 3)

        trim.reset()
        #expect(!trim.isTrimmed)
    }

    @Test func clipShorterThanTheMinimumCanStillBeSelectedWhole() {
        var trim = TrimSelection(duration: 0.3)
        trim.setStart(0.2)
        #expect(trim.start == 0)
        #expect(trim.end == 0.3)
    }
}
