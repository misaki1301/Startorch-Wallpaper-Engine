import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func laCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
}

private func date(_ iso: String, timeZone: TimeZone = TimeZone(identifier: "UTC")!) -> Date {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    formatter.timeZone = timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.date(from: iso)!
}

@MainActor
struct ScheduleBoundaryTests {
    private let morning = ScheduleSlot(name: "Morning", startHour: 6, startMinute: 0, target: .wallpaper(URL(string: "https://example.com/morning.mp4")!))
    private let day = ScheduleSlot(name: "Day", startHour: 10, startMinute: 0, target: .wallpaper(URL(string: "https://example.com/day.mp4")!))
    private let evening = ScheduleSlot(name: "Evening", startHour: 18, startMinute: 0, target: .wallpaper(URL(string: "https://example.com/evening.mp4")!))
    private let night = ScheduleSlot(name: "Night", startHour: 22, startMinute: 0, target: .wallpaper(URL(string: "https://example.com/night.mp4")!))

    private var allSlots: [ScheduleSlot] { [night, morning, evening, day] } // deliberately unsorted

    @Test func noSlotsYieldsNoBoundaryAndNoActiveSlot() {
        let calendar = utcCalendar()
        let now = date("2026-06-01T12:00:00")
        #expect(ScheduleBoundary.nextBoundary(after: now, slots: [], calendar: calendar) == nil)
        #expect(ScheduleBoundary.activeSlot(at: now, slots: [], calendar: calendar) == nil)
    }

    @Test func activeSlotIsTheMostRecentStartToday() {
        let calendar = utcCalendar()
        let now = date("2026-06-01T11:00:00") // between Day (10:00) and Evening (18:00)
        #expect(ScheduleBoundary.activeSlot(at: now, slots: allSlots, calendar: calendar)?.name == "Day")
    }

    @Test func activeSlotBeforeAnySlotStartsTodayWrapsToYesterdaysLastSlot() {
        let calendar = utcCalendar()
        let now = date("2026-06-01T02:00:00") // before Morning (6:00); still in last night's Night slot
        #expect(ScheduleBoundary.activeSlot(at: now, slots: allSlots, calendar: calendar)?.name == "Night")
    }

    @Test func nextBoundaryIsTheNextSlotLaterToday() {
        let calendar = utcCalendar()
        let now = date("2026-06-01T11:00:00")
        let next = ScheduleBoundary.nextBoundary(after: now, slots: allSlots, calendar: calendar)
        #expect(next?.slot.name == "Evening")
        #expect(next?.date == date("2026-06-01T18:00:00"))
    }

    @Test func nextBoundaryAcrossMidnightIsTomorrowsFirstSlot() {
        let calendar = utcCalendar()
        let now = date("2026-06-01T23:00:00") // after Night (22:00)
        let next = ScheduleBoundary.nextBoundary(after: now, slots: allSlots, calendar: calendar)
        #expect(next?.slot.name == "Morning")
        #expect(next?.date == date("2026-06-02T06:00:00"))
    }

    @Test func nextBoundaryExactlyAtASlotStartIsTheOneAfterIt() {
        let calendar = utcCalendar()
        let now = date("2026-06-01T10:00:00") // exactly Day's start
        let next = ScheduleBoundary.nextBoundary(after: now, slots: allSlots, calendar: calendar)
        #expect(next?.slot.name == "Evening")
    }

    // MARK: DST (America/Los_Angeles springs forward 2026-03-08 02:00 -> 03:00)

    @Test func nextBoundarySpansTheSpringForwardTransitionCorrectly() {
        let calendar = laCalendar()
        let tz = calendar.timeZone
        // 01:00 local on the DST day, with a slot at 06:00 local later that (23-hour) day.
        let now = date("2026-03-08T01:00:00", timeZone: tz)
        let next = ScheduleBoundary.nextBoundary(after: now, slots: [morning], calendar: calendar)
        // 06:00 local on the spring-forward day is still a valid, unambiguous wall-clock time.
        let expected = date("2026-03-08T06:00:00", timeZone: tz)
        #expect(next?.date == expected)
        // 01:00 to 06:00 is 5 hours of wall-clock time, but only 4 hours of elapsed real time,
        // since the clock skipped 02:00-02:59 — proving this used calendar math on wall-clock
        // components, not a flat 5-hour `addingTimeInterval`.
        #expect(expected.timeIntervalSince(now) == 4 * 3600)
    }

    @Test func activeSlotAfterFallBackStillResolvesToTheLatestStart() {
        let calendar = laCalendar()
        let tz = calendar.timeZone
        // Fall back 2026-11-01 02:00 -> 01:00. Just past midnight, only Night (22:00 the day
        // before) has started.
        let now = date("2026-11-01T00:30:00", timeZone: tz)
        #expect(ScheduleBoundary.activeSlot(at: now, slots: allSlots, calendar: calendar)?.name == "Night")
    }

    @Test func sortedSlotsOrdersByTimeOfDayRegardlessOfDeclarationOrder() {
        let schedule = Schedule(isEnabled: true, slots: allSlots)
        #expect(schedule.sortedSlots.map(\.name) == ["Morning", "Day", "Evening", "Night"])
    }
}
