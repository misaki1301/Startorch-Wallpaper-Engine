import Foundation

/// How much paused time a `PauseReason` accounts for in a summary window.
nonisolated struct PauseReasonShare: Equatable, Sendable, Identifiable {
    var reason: PauseReason
    var seconds: TimeInterval
    var id: PauseReason { reason }
}

/// An aggregate of `PlaybackStats.recentDays()` for the energy summary: how much of the time
/// StarTorch could have played it was actually paused, and why.
nonisolated struct EnergyWeeklySummary: Equatable, Sendable {
    var totalPlayedSeconds: TimeInterval
    var totalPausedSeconds: TimeInterval
    /// 0–100. 0 when there's no recorded time at all.
    var percentPaused: Double
    /// Reasons with any paused time, largest first.
    var topPauseReasons: [PauseReasonShare]

    static let empty = EnergyWeeklySummary(totalPlayedSeconds: 0, totalPausedSeconds: 0, percentPaused: 0, topPauseReasons: [])

    var hasData: Bool { totalPlayedSeconds > 0 || totalPausedSeconds > 0 }

    /// `days` is normally `PlaybackStats.recentDays()`, or a shorter slice for a "this week" view.
    static func summarize(_ days: [DailyPlayback], topCount: Int = 3) -> EnergyWeeklySummary {
        guard !days.isEmpty else { return .empty }

        let played = days.reduce(0) { $0 + $1.playedSeconds }
        var byReason: [PauseReason: TimeInterval] = [:]
        for day in days {
            for (rawReason, seconds) in day.pausedSecondsByReason where seconds > 0 {
                guard let reason = PauseReason(rawValue: rawReason) else { continue }
                byReason[reason, default: 0] += seconds
            }
        }
        let paused = byReason.values.reduce(0, +)
        let total = played + paused
        let percent = total > 0 ? (paused / total) * 100 : 0
        let top = byReason
            .sorted { $0.value > $1.value }
            .prefix(topCount)
            .map { PauseReasonShare(reason: $0.key, seconds: $0.value) }

        return EnergyWeeklySummary(
            totalPlayedSeconds: played,
            totalPausedSeconds: paused,
            percentPaused: percent,
            topPauseReasons: Array(top)
        )
    }
}
