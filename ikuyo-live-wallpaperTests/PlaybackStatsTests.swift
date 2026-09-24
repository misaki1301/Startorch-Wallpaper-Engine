import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

@MainActor
struct PlaybackStatsTests {
    final class Clock {
        var date: Date
        init(_ date: Date) { self.date = date }
        func advance(_ seconds: TimeInterval) { date += seconds }
    }

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Lima")!
        return calendar
    }()

    private let fileURL = FileManager.default.temporaryDirectory
        .appending(path: "PlaybackStatsTests-\(UUID().uuidString)/playback-stats.json")

    /// 2026-09-24 10:00 in Lima.
    private func morning(day: Int = 24) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: 10))!
    }

    private func makeStats(_ clock: Clock) -> PlaybackStats {
        PlaybackStats(fileURL: fileURL, calendar: calendar, now: { clock.date })
    }

    @Test func accumulatesPlayedAndPausedTimeOnTransitions() {
        let clock = Clock(morning())
        let stats = makeStats(clock)

        stats.record(.playing)
        clock.advance(60)
        stats.record(.paused(.desktopCovered))
        clock.advance(30)
        stats.record(.playing)
        clock.advance(10)
        stats.record(.paused(.user))
        clock.advance(5)
        stats.record(nil)
        clock.advance(1000)

        let days = stats.recentDays()
        #expect(days.count == 1)
        let today = days[0]
        #expect(today.day == "2026-09-24")
        #expect(today.playedSeconds == 70)
        #expect(today.pausedSeconds(for: .desktopCovered) == 30)
        #expect(today.pausedSeconds(for: .user) == 5)
        #expect(today.pausedSeconds(for: .onBattery) == 0)
        #expect(today.pausedSeconds == 35)
    }

    @Test func repeatingTheSameStateDoesNotRestartTheSegment() {
        let clock = Clock(morning())
        let stats = makeStats(clock)
        stats.record(.playing)
        clock.advance(20)
        stats.record(.playing)
        clock.advance(20)
        stats.record(nil)
        #expect(stats.recentDays().first?.playedSeconds == 40)
    }

    @Test func theRunningStateCountsWithoutBeingSaved() {
        let clock = Clock(morning())
        let stats = makeStats(clock)
        stats.record(.paused(.lowPowerMode))
        clock.advance(45)
        #expect(stats.recentDays().first?.pausedSeconds(for: .lowPowerMode) == 45)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)), "no writes without a transition")
    }

    @Test func splitsTimeAtMidnight() {
        let lateEvening = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 23, minute: 50))!
        let clock = Clock(lateEvening)
        let stats = makeStats(clock)
        stats.record(.playing)
        clock.advance(20 * 60)
        stats.record(nil)

        let days = stats.recentDays()
        #expect(days.map(\.day) == ["2026-09-24", "2026-09-25"])
        #expect(days[0].playedSeconds == 600)
        #expect(days[1].playedSeconds == 600)
    }

    @Test func persistsAcrossLaunches() {
        let clock = Clock(morning())
        let stats = makeStats(clock)
        stats.record(.playing)
        clock.advance(90)
        stats.record(.paused(.screenAsleep))
        clock.advance(10)
        stats.record(nil)

        let reloaded = makeStats(clock).recentDays()
        #expect(reloaded == stats.recentDays())
        #expect(reloaded.first?.playedSeconds == 90)
        #expect(reloaded.first?.pausedSeconds(for: .screenAsleep) == 10)
    }

    @Test func dropsDaysOlderThanThirtyDays() {
        let clock = Clock(morning(day: 1))
        let stats = makeStats(clock)
        stats.record(.playing)
        clock.advance(100)
        stats.record(nil)

        // 29 days later the first day is still within the window of 30.
        clock.date = calendar.date(byAdding: .day, value: 29, to: morning(day: 1))!
        #expect(stats.recentDays().map(\.day) == ["2026-09-01"])

        // A day later it has aged out, both from reads and from the file.
        clock.date = calendar.date(byAdding: .day, value: 30, to: morning(day: 1))!
        #expect(stats.recentDays().isEmpty)
        stats.record(.playing)
        clock.advance(5)
        stats.record(nil)
        #expect(makeStats(clock).recentDays().map(\.day) == ["2026-10-01"])
    }

    @Test func aClockGoingBackwardsAddsNothing() {
        let clock = Clock(morning())
        let stats = makeStats(clock)
        stats.record(.playing)
        clock.advance(-60)
        stats.record(nil)
        #expect(stats.recentDays().isEmpty)
    }

    @Test func managerRecordsItsTransitions() {
        let clock = Clock(morning())
        let stats = makeStats(clock)
        let signals = FakeSignals()
        let manager = WallpaperManager(
            restorer: DesktopRestorer(desktop: InertDesktop(), directory: .temporaryDirectory),
            presenter: FakePresenter(),
            signals: signals,
            stats: stats,
            makeEngine: { FakeEngine(url: $0) }
        )

        manager.start(with: URL(filePath: "/tmp/imported/rain.mp4"))
        clock.advance(100)
        signals.signals.isDesktopVisible = false
        clock.advance(40)
        signals.signals.isDesktopVisible = true
        clock.advance(10)
        manager.pause()
        clock.advance(3)
        manager.stop()
        clock.advance(500)

        let today = stats.recentDays().first
        #expect(today?.playedSeconds == 110)
        #expect(today?.pausedSeconds(for: .desktopCovered) == 40)
        #expect(today?.pausedSeconds(for: .user) == 3)
    }
}
