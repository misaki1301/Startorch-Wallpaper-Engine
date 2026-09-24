import Testing
@testable import StarTorch_Wallpaper_Engine

struct EnergyWeeklySummaryTests {
    @Test func emptyDaysProduceAnEmptySummary() {
        #expect(EnergyWeeklySummary.summarize([]) == .empty)
        #expect(!EnergyWeeklySummary.empty.hasData)
    }

    @Test func aggregatesPlayedAndPausedTimeAcrossDays() {
        let days = [
            DailyPlayback(day: "2026-09-20", playedSeconds: 3_600, pausedSecondsByReason: [PauseReason.desktopCovered.rawValue: 400]),
            DailyPlayback(day: "2026-09-21", playedSeconds: 1_800, pausedSecondsByReason: [PauseReason.desktopCovered.rawValue: 200, PauseReason.onBattery.rawValue: 100]),
        ]
        let summary = EnergyWeeklySummary.summarize(days)
        #expect(summary.hasData)
        #expect(summary.totalPlayedSeconds == 5_400)
        #expect(summary.totalPausedSeconds == 700)
        #expect(summary.percentPaused.rounded() == ((700.0 / 6_100.0) * 100).rounded())
    }

    @Test func topPauseReasonsAreSortedLargestFirstAndCapped() {
        let days = [
            DailyPlayback(day: "2026-09-20", playedSeconds: 0, pausedSecondsByReason: [
                PauseReason.desktopCovered.rawValue: 100,
                PauseReason.onBattery.rawValue: 500,
                PauseReason.fullScreenApp.rawValue: 300,
                PauseReason.lowPowerMode.rawValue: 50,
            ]),
        ]
        let summary = EnergyWeeklySummary.summarize(days, topCount: 2)
        #expect(summary.topPauseReasons.map(\.reason) == [.onBattery, .fullScreenApp])
        #expect(summary.topPauseReasons.map(\.seconds) == [500, 300])
    }

    @Test func zeroSecondReasonsAreExcluded() {
        let days = [DailyPlayback(day: "2026-09-20", playedSeconds: 100, pausedSecondsByReason: [PauseReason.user.rawValue: 0])]
        let summary = EnergyWeeklySummary.summarize(days)
        #expect(summary.topPauseReasons.isEmpty)
        #expect(summary.percentPaused == 0)
    }

    @Test func noPlaybackAtAllHasZeroPercentPaused() {
        let days = [DailyPlayback(day: "2026-09-20")]
        let summary = EnergyWeeklySummary.summarize(days)
        #expect(!summary.hasData)
        #expect(summary.percentPaused == 0)
    }

    @Test func allPausedIsAHundredPercent() {
        let days = [DailyPlayback(day: "2026-09-20", playedSeconds: 0, pausedSecondsByReason: [PauseReason.screenAsleep.rawValue: 60])]
        let summary = EnergyWeeklySummary.summarize(days)
        #expect(summary.percentPaused == 100)
    }
}
