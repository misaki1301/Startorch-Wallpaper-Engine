import Foundation

/// What a schedule slot or an appearance variant points to.
enum ScheduleTarget: Codable, Hashable {
    case wallpaper(URL)
    case collection(UUID)
}

/// A time-of-day slot: active from `startHour:startMinute` local time until the next slot (in
/// time order) starts, wrapping past midnight back to the last slot of the previous day.
struct ScheduleSlot: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var startHour: Int
    var startMinute: Int
    var target: ScheduleTarget

    init(id: UUID = UUID(), name: String, startHour: Int, startMinute: Int, target: ScheduleTarget) {
        self.id = id
        self.name = name
        self.startHour = startHour
        self.startMinute = startMinute
        self.target = target
    }

    /// Minutes since local midnight; used to order slots and compute boundaries.
    var minuteOfDay: Int { startHour * 60 + startMinute }
}

/// Light/Dark wallpapers that follow the system appearance, independent of the time-of-day slots.
struct AppearanceVariants: Codable, Hashable {
    var light: ScheduleTarget?
    var dark: ScheduleTarget?

    var isEnabled: Bool { light != nil || dark != nil }
}

/// The user's full schedule configuration, persisted by `AppSettings`.
struct Schedule: Codable, Hashable {
    var isEnabled: Bool = false
    var slots: [ScheduleSlot] = []
    var appearance: AppearanceVariants = AppearanceVariants()

    /// Slots in time order, for boundary computation.
    var sortedSlots: [ScheduleSlot] { slots.sorted { $0.minuteOfDay < $1.minuteOfDay } }

    /// Convenience presets for a "Morning/Day/Evening/Night" starting point; the user can rename,
    /// retime or delete any of them, or add fully custom slots instead.
    static func defaultSlots(morning: ScheduleTarget, day: ScheduleTarget, evening: ScheduleTarget, night: ScheduleTarget) -> [ScheduleSlot] {
        [
            ScheduleSlot(name: String(localized: "schedule.morning", defaultValue: "Morning"), startHour: 6, startMinute: 0, target: morning),
            ScheduleSlot(name: String(localized: "schedule.day", defaultValue: "Day"), startHour: 10, startMinute: 0, target: day),
            ScheduleSlot(name: String(localized: "schedule.evening", defaultValue: "Evening"), startHour: 18, startMinute: 0, target: evening),
            ScheduleSlot(name: String(localized: "schedule.night", defaultValue: "Night"), startHour: 22, startMinute: 0, target: night),
        ]
    }
}

/// Pure boundary math for the time-of-day slots — no dates besides what's passed in, so it's
/// exercised directly by tests across midnight and DST without waiting on real timers.
enum ScheduleBoundary {
    /// The next moment the active slot changes, and which slot becomes active then. `nil` when
    /// there are no slots (nothing to schedule).
    static func nextBoundary(after now: Date, slots: [ScheduleSlot], calendar: Calendar) -> (date: Date, slot: ScheduleSlot)? {
        guard !slots.isEmpty else { return nil }
        let candidates = startDates(for: slots, around: now, calendar: calendar)
        return candidates.filter { $0.date > now }.min { $0.date < $1.date }
    }

    /// The slot that is active right now: the most recent slot start at or before `now`, wrapping
    /// to the last (by time-of-day) slot when `now` is before every slot's start today.
    static func activeSlot(at now: Date, slots: [ScheduleSlot], calendar: Calendar) -> ScheduleSlot? {
        guard !slots.isEmpty else { return nil }
        let sorted = slots.sorted { $0.minuteOfDay < $1.minuteOfDay }
        let candidates = startDates(for: sorted, around: now, calendar: calendar)
        if let mostRecent = candidates.filter({ $0.date <= now }).max(by: { $0.date < $1.date }) {
            return mostRecent.slot
        }
        // `now` is before every slot fires today: still in yesterday's last slot.
        return sorted.last
    }

    /// Each slot's start date for the day containing `now`, the day before and the day after —
    /// enough range that a boundary search never misses across a DST shift or the day edge.
    private static func startDates(
        for slots: [ScheduleSlot],
        around now: Date,
        calendar: Calendar
    ) -> [(date: Date, slot: ScheduleSlot)] {
        let startOfToday = calendar.startOfDay(for: now)
        var results: [(date: Date, slot: ScheduleSlot)] = []
        for dayOffset in -1...1 {
            guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { continue }
            for slot in slots {
                var components = DateComponents()
                components.hour = slot.startHour
                components.minute = slot.startMinute
                guard let date = calendar.date(byAdding: components, to: dayStart) else { continue }
                results.append((date, slot))
            }
        }
        return results
    }
}
