import Foundation

/// What a running wallpaper is doing, for the statistics.
nonisolated enum PlaybackState: Equatable, Sendable {
    case playing
    case paused(PauseReason)
}

/// One day of wallpaper time: how long it played and how long it was paused, by reason.
nonisolated struct DailyPlayback: Codable, Equatable, Sendable {
    /// `yyyy-MM-dd` in the local calendar.
    var day: String
    var playedSeconds: TimeInterval = 0
    /// Keyed by `PauseReason.rawValue`, so the file stays readable if reasons are added.
    var pausedSecondsByReason: [String: TimeInterval] = [:]

    func pausedSeconds(for reason: PauseReason) -> TimeInterval {
        pausedSecondsByReason[reason.rawValue] ?? 0
    }

    var pausedSeconds: TimeInterval {
        pausedSecondsByReason.values.reduce(0, +)
    }
}

/// Per-day counters of played and paused time, kept for the energy summary.
///
/// Nothing ticks: time is added only when the playback state changes (play, pause, stop), and the
/// small JSON file is written then. Days older than `retentionDays` are dropped.
final class PlaybackStats {
    let fileURL: URL
    private let calendar: Calendar
    private let now: () -> Date
    private let retentionDays: Int

    private var days: [String: DailyPlayback]
    private var current: (state: PlaybackState, since: Date)?

    init(
        fileURL: URL = URL.applicationSupportDirectory.appending(path: "StarTorch/playback-stats.json"),
        calendar: Calendar = .current,
        retentionDays: Int = 30,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.calendar = calendar
        self.retentionDays = retentionDays
        self.now = now
        let saved = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([DailyPlayback].self, from: $0) } ?? []
        days = Dictionary(saved.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Records a change of state; `nil` means no wallpaper is running. Repeating the current
    /// state does nothing.
    func record(_ state: PlaybackState?) {
        let date = now()
        guard state != current?.state else { return }
        if let current {
            add(current.state, from: current.since, to: date)
            save(at: date)
        }
        current = state.map { ($0, date) }
    }

    /// The last `retentionDays` days that have any time, oldest first, including the state that
    /// is still running.
    func recentDays() -> [DailyPlayback] {
        let date = now()
        var snapshot = days
        if let current {
            Self.add(current.state, from: current.since, to: date, into: &snapshot, calendar: calendar)
        }
        let cutoff = oldestKeptDay(at: date)
        return snapshot.values.filter { $0.day >= cutoff }.sorted { $0.day < $1.day }
    }

    // MARK: - Private

    private func add(_ state: PlaybackState, from start: Date, to end: Date) {
        Self.add(state, from: start, to: end, into: &days, calendar: calendar)
    }

    /// Adds `start..<end` to `state`'s counter, split at midnight.
    private static func add(
        _ state: PlaybackState,
        from start: Date,
        to end: Date,
        into days: inout [String: DailyPlayback],
        calendar: Calendar
    ) {
        var time = start
        while time < end {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: time)) ?? end
            let segmentEnd = min(nextDay, end)
            let key = dayKey(for: time, calendar: calendar)
            let seconds = segmentEnd.timeIntervalSince(time)
            var day = days[key] ?? DailyPlayback(day: key)
            switch state {
            case .playing: day.playedSeconds += seconds
            case .paused(let reason): day.pausedSecondsByReason[reason.rawValue, default: 0] += seconds
            }
            days[key] = day
            time = segmentEnd
        }
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func oldestKeptDay(at date: Date) -> String {
        let today = calendar.startOfDay(for: date)
        let oldest = calendar.date(byAdding: .day, value: -(retentionDays - 1), to: today) ?? today
        return Self.dayKey(for: oldest, calendar: calendar)
    }

    private func save(at date: Date) {
        let cutoff = oldestKeptDay(at: date)
        days = days.filter { $0.key >= cutoff }
        let sorted = days.values.sorted { $0.day < $1.day }
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
