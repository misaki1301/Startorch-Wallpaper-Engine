import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

/// Captures the last scheduled date/handler instead of using a real `Timer`, so tests fire a
/// boundary by calling `fire()` deterministically.
@MainActor
final class FakeSchedulingTimer: SchedulingTimer {
    private(set) var scheduledDate: Date?
    private var handler: (() -> Void)?

    func schedule(at date: Date?, _ handler: @escaping () -> Void) {
        scheduledDate = date
        self.handler = date == nil ? nil : handler
    }

    /// Simulates the timer firing; does nothing if nothing is scheduled.
    func fire() {
        handler?()
    }
}

@MainActor
private func makeLibrary(directory: URL) -> WallpaperLibrary {
    let service = CatalogService(cacheURL: directory.appending(path: "none.json"), bundledURL: nil)
    return WallpaperLibrary(directory: directory, defaults: makeDefaults(), catalogService: service)
}

/// Plain mutable storage a closure can capture directly, so `ScheduleServiceHarness.init` never
/// captures `self` before it's fully initialized (Swift flags that as a definite-initialization
/// error, since `self` would escape through the `ScheduleService` it hands off to).
@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
final class ScheduleServiceHarness {
    let manager = WallpaperManager(
        restorer: DesktopRestorer(desktop: InertDesktop(), directory: .temporaryDirectory),
        presenter: FakePresenter(),
        signals: FakeSignals(),
        makeEngine: { FakeEngine(url: $0) }
    )
    let library: WallpaperLibrary
    let settings: AppSettings
    let boundaryTimer = FakeSchedulingTimer()
    let shuffleTimer = FakeSchedulingTimer()
    private let isDarkBox: Box<Bool>
    private let currentDateBox: Box<Date>
    let service: ScheduleService

    var isDark: Bool {
        get { isDarkBox.value }
        set { isDarkBox.value = newValue }
    }

    var currentDate: Date {
        get { currentDateBox.value }
        set { currentDateBox.value = newValue }
    }

    init(now: Date = Date()) {
        let dir = try! makeTempDirectory()
        library = makeLibrary(directory: dir)
        settings = AppSettings(defaults: makeDefaults())
        let isDarkBox = Box(false)
        let currentDateBox = Box(now)
        self.isDarkBox = isDarkBox
        self.currentDateBox = currentDateBox
        service = ScheduleService(
            manager: manager,
            library: library,
            settings: settings,
            calendar: { .current },
            now: { currentDateBox.value },
            isDarkAppearance: { isDarkBox.value },
            boundaryTimer: boundaryTimer,
            shuffleTimer: shuffleTimer,
            shuffler: CollectionShuffler(randomElement: { $0.first }),
            observeSystemEvents: false
        )
    }
}

@MainActor
struct ScheduleServiceTests {
    let a = URL(string: "https://example.com/a.mp4")!
    let b = URL(string: "https://example.com/b.mp4")!

    @Test func rearmSchedulesTheNextSlotBoundaryWhenEnabled() {
        let harness = ScheduleServiceHarness()
        harness.service.schedule.isEnabled = true
        harness.service.schedule.slots = [ScheduleSlot(name: "Only", startHour: 0, startMinute: 0, target: .wallpaper(a))]
        #expect(harness.boundaryTimer.scheduledDate != nil)
    }

    @Test func boundaryFiringStartsTheSlotsWallpaper() {
        let harness = ScheduleServiceHarness()
        harness.service.schedule.isEnabled = true
        harness.service.schedule.slots = [ScheduleSlot(name: "Only", startHour: 0, startMinute: 0, target: .wallpaper(a))]
        harness.boundaryTimer.fire()
        #expect(harness.manager.currentURL == a)
    }

    @Test func boundaryFiringDoesNothingWhileTheUserHasPaused() {
        let harness = ScheduleServiceHarness()
        harness.manager.start(with: b)
        harness.manager.pause()
        harness.service.schedule.isEnabled = true
        harness.service.schedule.slots = [ScheduleSlot(name: "Only", startHour: 0, startMinute: 0, target: .wallpaper(a))]
        harness.boundaryTimer.fire()
        #expect(harness.manager.currentURL == b) // unchanged
        #expect(harness.manager.isPaused)
    }

    /// `ScheduleService`'s manual-pick detection observes `manager.currentURL` the same way
    /// `WallpaperManager.followPauseRules` observes settings: `withObservationTracking`'s
    /// `onChange` fires before the new value is stored, so both hop to the next run-loop turn to
    /// read it — hence waiting here, exactly like `PauseSettingsTests.settle`.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
    }

    @Test func manualPickSuspendsTheScheduleUntilTheNextBoundary() async {
        let harness = ScheduleServiceHarness()
        harness.service.schedule.isEnabled = true
        harness.service.schedule.slots = [ScheduleSlot(name: "Only", startHour: 0, startMinute: 0, target: .wallpaper(a))]
        harness.boundaryTimer.fire()
        await settle { harness.manager.currentURL == a }
        #expect(!harness.service.isSuspendedByManualPick)

        // The user picks something else entirely, not through the schedule.
        harness.manager.start(with: b)
        await settle { harness.service.isSuspendedByManualPick }
        #expect(harness.service.isSuspendedByManualPick)

        // The next boundary lifts the suspension again by applying its own target.
        harness.boundaryTimer.fire()
        await settle { !harness.service.isSuspendedByManualPick }
        #expect(!harness.service.isSuspendedByManualPick)
        #expect(harness.manager.currentURL == a)
    }

    @Test func appearanceVariantAppliesOnlyWhenTheModeActuallyChanges() {
        let harness = ScheduleServiceHarness()
        harness.service.schedule.appearance.light = .wallpaper(a)
        harness.service.schedule.appearance.dark = .wallpaper(b)

        // Already light at construction time (isDark starts false); a spurious refresh with no
        // change must not start anything.
        harness.service.refreshAppearance()
        #expect(harness.manager.currentURL == nil)

        harness.isDark = true
        harness.service.refreshAppearance()
        #expect(harness.manager.currentURL == b)

        harness.isDark = false
        harness.service.refreshAppearance()
        #expect(harness.manager.currentURL == a)
    }

    @Test func appearanceChangeIsANoOpWhenNoVariantsAreConfigured() {
        let harness = ScheduleServiceHarness()
        harness.isDark = true
        harness.service.refreshAppearance()
        #expect(harness.manager.currentURL == nil)
    }

    @Test func appearanceChangeRespectsUserPause() {
        let harness = ScheduleServiceHarness()
        harness.manager.start(with: a)
        harness.manager.pause()
        harness.service.schedule.appearance.dark = .wallpaper(b)
        harness.isDark = true
        harness.service.refreshAppearance()
        #expect(harness.manager.currentURL == a) // unchanged, still paused
    }

    @Test func playCollectionStartsAPickAndArmsShuffle() {
        let harness = ScheduleServiceHarness()
        let collection = harness.library.createCollection(name: "Mix")
        harness.library.addItem(a, to: collection.id)
        harness.library.addItem(b, to: collection.id)
        harness.library.setShuffle(ShuffleSettings(interval: .minutes(5), isEnabled: true), for: collection.id)

        harness.service.playCollection(collection.id)
        #expect(harness.manager.currentURL != nil)
        #expect(harness.shuffleTimer.scheduledDate != nil)
    }

    @Test func shuffleTickAvoidsImmediatelyRepeatingTheCurrentPick() {
        let harness = ScheduleServiceHarness()
        let collection = harness.library.createCollection(name: "Mix")
        harness.library.addItem(a, to: collection.id)
        harness.library.addItem(b, to: collection.id)
        harness.library.setShuffle(ShuffleSettings(interval: .minutes(5), isEnabled: true), for: collection.id)

        harness.service.playCollection(collection.id)
        let first = harness.manager.currentURL
        harness.shuffleTimer.fire()
        let second = harness.manager.currentURL
        #expect(second != nil)
        #expect(second != first)
    }

    @Test func stopShufflingCancelsThePendingTick() {
        let harness = ScheduleServiceHarness()
        let collection = harness.library.createCollection(name: "Mix")
        harness.library.addItem(a, to: collection.id)
        harness.library.setShuffle(ShuffleSettings(interval: .minutes(5), isEnabled: true), for: collection.id)

        harness.service.playCollection(collection.id)
        #expect(harness.shuffleTimer.scheduledDate != nil)
        harness.service.stopShuffling()
        #expect(harness.shuffleTimer.scheduledDate == nil)
    }

    @Test func disablingTheScheduleCancelsTheBoundaryTimer() {
        let harness = ScheduleServiceHarness()
        harness.service.schedule.isEnabled = true
        harness.service.schedule.slots = [ScheduleSlot(name: "Only", startHour: 0, startMinute: 0, target: .wallpaper(a))]
        #expect(harness.boundaryTimer.scheduledDate != nil)

        harness.service.schedule.isEnabled = false
        #expect(harness.boundaryTimer.scheduledDate == nil)
    }
}
