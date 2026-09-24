import AppKit

/// Applies time-of-day slots, Light/Dark appearance variants, and collection shuffle, by
/// scheduling a single timer to the next boundary rather than polling. It only ever calls
/// `WallpaperManager`'s public `start(with:)`/`isPaused` — the same path a manual pick uses — so
/// switches already crossfade.
///
/// **Manual-override rule:** starting a wallpaper from anywhere else in the app (a card, the
/// inspector, a Shortcut, Next Favorite…) suspends the schedule until its next boundary. The
/// schedule does not fight the user's pick back; it simply resumes deciding at the next slot
/// change, appearance change, or shuffle tick. `isSuspendedByManualPick` reflects this for the UI.
///
/// **Pause rule:** a boundary firing while the user has paused the wallpaper (`manager.isPaused`)
/// does nothing — it neither starts nor changes playback. The user's pause always wins.
@MainActor
@Observable
final class ScheduleService {
    @ObservationIgnored private let manager: WallpaperManager
    @ObservationIgnored private let library: WallpaperLibrary
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let calendar: () -> Calendar
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let isDarkAppearance: () -> Bool
    @ObservationIgnored private let boundaryTimer: SchedulingTimer
    @ObservationIgnored private let shuffleTimer: SchedulingTimer
    @ObservationIgnored private let shuffler: CollectionShuffler
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let workspaceNotificationCenter: NotificationCenter
    @ObservationIgnored private let distributedNotificationCenter: DistributedNotificationCenter?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastAppliedURL: URL?
    @ObservationIgnored private var lastKnownIsDark: Bool
    @ObservationIgnored private var activeCollectionID: WallpaperCollection.ID?

    /// Set the moment a wallpaper starts through anything other than this service's own apply
    /// calls; cleared the next time this service applies a boundary, an appearance change or a
    /// shuffle tick. See the manual-override rule above.
    private(set) var isSuspendedByManualPick = false

    var schedule: Schedule {
        get { settings.schedule }
        set {
            settings.schedule = newValue
            rearmBoundary()
        }
    }

    init(
        manager: WallpaperManager,
        library: WallpaperLibrary,
        settings: AppSettings,
        calendar: @escaping () -> Calendar = { .current },
        now: @escaping () -> Date = Date.init,
        isDarkAppearance: @escaping () -> Bool = {
            NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        },
        boundaryTimer: SchedulingTimer = RunLoopSchedulingTimer(),
        shuffleTimer: SchedulingTimer = RunLoopSchedulingTimer(),
        shuffler: CollectionShuffler = CollectionShuffler(),
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributedNotificationCenter: DistributedNotificationCenter? = AppEnvironment.isHostingTests ? nil : .default(),
        observeSystemEvents: Bool = true
    ) {
        self.manager = manager
        self.library = library
        self.settings = settings
        self.calendar = calendar
        self.now = now
        self.isDarkAppearance = isDarkAppearance
        self.boundaryTimer = boundaryTimer
        self.shuffleTimer = shuffleTimer
        self.shuffler = shuffler
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.distributedNotificationCenter = distributedNotificationCenter
        self.lastKnownIsDark = isDarkAppearance()

        observeManualPicks()
        if observeSystemEvents {
            observeSystemNotifications()
        }
        rearmBoundary()
    }

    // `ScheduleService` lives for the app's whole run, so there's no `deinit` cleanup: every
    // notification closure captures `self` weakly (see below), so an observer outliving this
    // instance — which in practice only happens in tests, which pass `observeSystemEvents:
    // false` — just becomes a no-op rather than a dangling reference.

    // MARK: - Time-of-day slots

    /// (Re)arms the single boundary timer to the next slot change, if the schedule is on and has
    /// slots. Called on init, whenever `schedule` is set, and after wake/clock/timezone changes.
    private func rearmBoundary() {
        guard schedule.isEnabled, let next = ScheduleBoundary.nextBoundary(after: now(), slots: schedule.slots, calendar: calendar()) else {
            boundaryTimer.cancel()
            return
        }
        boundaryTimer.schedule(at: next.date) { [weak self] in
            guard let self else { return }
            self.applyActiveSlot()
            self.rearmBoundary()
        }
    }

    private func applyActiveSlot() {
        guard schedule.isEnabled,
              let active = ScheduleBoundary.activeSlot(at: now(), slots: schedule.slots, calendar: calendar())
        else { return }
        apply(active.target)
    }

    // MARK: - Appearance variants

    /// Re-checks the system appearance and applies the matching variant if it changed. Called
    /// from the appearance-change notification, and safe to call speculatively (e.g. on wake).
    func refreshAppearance() {
        let isDark = isDarkAppearance()
        guard isDark != lastKnownIsDark else { return }
        lastKnownIsDark = isDark
        guard schedule.appearance.isEnabled else { return }
        guard let target = isDark ? schedule.appearance.dark : schedule.appearance.light else { return }
        apply(target)
    }

    // MARK: - Collections & shuffle

    /// Starts a collection directly — e.g. "Play Collection" from the sidebar — independent of
    /// the time-of-day schedule. Arms the collection's own shuffle rotation if it has one.
    func playCollection(_ id: WallpaperCollection.ID) {
        activeCollectionID = id
        guard let collection = library.collection(id) else { return }
        applyCollection(collection)
        armShuffle(for: collection)
    }

    /// Stops shuffling (e.g. the collection was deleted, or the user started something else that
    /// isn't this collection); does not touch current playback.
    func stopShuffling() {
        activeCollectionID = nil
        shuffleTimer.cancel()
    }

    /// Called on `NSWorkspace.didWakeNotification` and could be called at launch: fires any
    /// shuffle whose interval is event-driven rather than time-based.
    private func fireEventDrivenShuffles(_ interval: ShuffleSettings.Interval) {
        guard let id = activeCollectionID, let collection = library.collection(id),
              let shuffle = collection.shuffle, shuffle.isEnabled, shuffle.interval == interval
        else { return }
        applyCollection(collection)
    }

    private func armShuffle(for collection: WallpaperCollection) {
        guard let shuffle = collection.shuffle, shuffle.isEnabled, let interval = shuffle.timeInterval else {
            shuffleTimer.cancel()
            return
        }
        let fireDate = now().addingTimeInterval(interval)
        shuffleTimer.schedule(at: fireDate) { [weak self] in
            guard let self, let id = self.activeCollectionID, let latest = self.library.collection(id) else { return }
            self.applyCollection(latest)
            self.armShuffle(for: latest)
        }
    }

    private func applyCollection(_ collection: WallpaperCollection) {
        guard !manager.isPaused else { return }
        guard let url = shuffler.pick(from: collection) else { return }
        manager.start(with: url)
        lastAppliedURL = url
        isSuspendedByManualPick = false
    }

    // MARK: - Applying a target

    private func apply(_ target: ScheduleTarget) {
        guard !manager.isPaused else { return }
        switch target {
        case .wallpaper(let url):
            activeCollectionID = nil
            shuffleTimer.cancel()
            manager.start(with: url)
            lastAppliedURL = url
            isSuspendedByManualPick = false
        case .collection(let id):
            playCollection(id)
        }
    }

    // MARK: - Manual override

    /// Tracks `manager.currentURL` so a pick made anywhere else (not through `apply`/
    /// `applyCollection` above) suspends the schedule until the next boundary. Re-registers after
    /// every change, since `withObservationTracking`'s `onChange` fires once per change.
    private func observeManualPicks() {
        withObservationTracking {
            _ = manager.currentURL
        } onChange: { [weak self] in
            Task { @MainActor in self?.handleCurrentURLChange() }
        }
    }

    private func handleCurrentURLChange() {
        if manager.currentURL != lastAppliedURL {
            isSuspendedByManualPick = true
            activeCollectionID = nil
            shuffleTimer.cancel()
        }
        observeManualPicks()
    }

    // MARK: - System events

    private func observeSystemNotifications() {
        observers.append(workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rearmBoundary()
                self?.refreshAppearance()
                self?.fireEventDrivenShuffles(.onWake)
            }
        })
        observers.append(notificationCenter.addObserver(
            forName: NSNotification.Name.NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rearmBoundary() }
        })
        observers.append(notificationCenter.addObserver(
            forName: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rearmBoundary() }
        })
        if let distributedNotificationCenter {
            observers.append(distributedNotificationCenter.addObserver(
                forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshAppearance() }
            })
        }
    }
}
