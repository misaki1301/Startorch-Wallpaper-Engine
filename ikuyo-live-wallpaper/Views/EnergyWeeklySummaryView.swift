import Charts
import SwiftUI

/// A read-only sheet, opened from Settings, summarizing `PlaybackStats.recentDays()`: how much
/// of the last week was played vs. paused, and the leading pause reasons.
struct EnergyWeeklySummaryView: View {
    let days: [DailyPlayback]
    @Environment(\.dismiss) private var dismiss

    private var lastSevenDays: [DailyPlayback] {
        Array(days.suffix(7))
    }

    private var summary: EnergyWeeklySummary {
        EnergyWeeklySummary.summarize(lastSevenDays)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if summary.hasData {
                        percentPausedRow
                        chart
                        pauseReasonsSection
                    } else {
                        ContentUnavailableView(
                            "No Playback Yet",
                            systemImage: "chart.bar",
                            description: Text("Play a wallpaper for a few days to see a summary here.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 460, height: 480)
    }

    private var header: some View {
        HStack {
            Text("Weekly Energy Summary")
                .font(.title3.weight(.semibold))
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var percentPausedRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Paused \(summary.percentPaused, format: .number.precision(.fractionLength(0)))% of the time")
                .font(.headline)
            Text("Over the last \(lastSevenDays.count == 1 ? "1 day" : "\(lastSevenDays.count) days"), StarTorch played for \(formattedDuration(summary.totalPlayedSeconds)) and paused for \(formattedDuration(summary.totalPausedSeconds)).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        Chart {
            ForEach(lastSevenDays, id: \.day) { day in
                BarMark(
                    x: .value("Day", day.day),
                    y: .value("Hours", day.playedSeconds / 3_600)
                )
                .foregroundStyle(by: .value("State", "Played"))
                BarMark(
                    x: .value("Day", day.day),
                    y: .value("Hours", day.pausedSeconds / 3_600)
                )
                .foregroundStyle(by: .value("State", "Paused"))
            }
        }
        .chartForegroundStyleScale([
            "Played": Color.accentColor,
            "Paused": Color.secondary.opacity(0.4),
        ])
        .chartLegend(position: .bottom, spacing: 8)
        .frame(height: 180)
        .accessibilityElement()
        .accessibilityLabel(Text("Played and paused hours by day"))
        .accessibilityValue(Text(chartAccessibilitySummary))
    }

    /// A plain-language stand-in for the bars, read by VoiceOver instead of the chart's marks.
    private var chartAccessibilitySummary: String {
        lastSevenDays.map { day in
            let played = formattedDuration(day.playedSeconds)
            let paused = formattedDuration(day.pausedSeconds)
            return "\(day.day): played \(played), paused \(paused)"
        }.joined(separator: ". ")
    }

    @ViewBuilder
    private var pauseReasonsSection: some View {
        if !summary.topPauseReasons.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Top Pause Reasons")
                    .font(.headline)
                ForEach(summary.topPauseReasons) { share in
                    HStack {
                        Text(share.reason.label)
                        Spacer()
                        Text(formattedDuration(share.seconds))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "0m"
    }
}

#Preview {
    EnergyWeeklySummaryView(days: [
        DailyPlayback(day: "2026-09-20", playedSeconds: 3_000, pausedSecondsByReason: [PauseReason.desktopCovered.rawValue: 400]),
        DailyPlayback(day: "2026-09-21", playedSeconds: 5_000, pausedSecondsByReason: [PauseReason.screenAsleep.rawValue: 28_000]),
        DailyPlayback(day: "2026-09-22", playedSeconds: 4_200, pausedSecondsByReason: [PauseReason.fullScreenApp.rawValue: 900]),
    ])
}
