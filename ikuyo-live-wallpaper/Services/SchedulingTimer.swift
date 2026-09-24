import Combine
import Foundation

/// A single one-shot timer to a specific date, so a caller never has to poll. Scheduling a new
/// date replaces any pending fire; scheduling `nil` cancels it. Injectable so tests can control
/// firing directly instead of waiting on `RunLoop`.
protocol SchedulingTimer: AnyObject {
    func schedule(at date: Date?, _ handler: @escaping () -> Void)
    func cancel()
}

extension SchedulingTimer {
    func cancel() { schedule(at: nil) {} }
}

/// The real implementation, backed by a delayed Combine publisher on the main run loop (the same
/// `Timer.publish`-family approach `SystemStatsService` uses, rather than `Timer`'s own
/// `@Sendable`-closure initializer). Its owner (`ScheduleService`) lives for the app's whole run,
/// so — like `WallpaperManager`'s notification observer — there's no teardown path;
/// `schedule(at:)` always cancels the previous pending fire before arming the next one, which is
/// the only cleanup ever needed.
final class RunLoopSchedulingTimer: SchedulingTimer {
    private var cancellable: AnyCancellable?

    func schedule(at date: Date?, _ handler: @escaping () -> Void) {
        cancellable?.cancel()
        cancellable = nil
        guard let date else { return }
        let interval = max(0, date.timeIntervalSinceNow)
        cancellable = Just(())
            .delay(for: .seconds(interval), scheduler: RunLoop.main)
            .sink { _ in handler() }
    }
}
