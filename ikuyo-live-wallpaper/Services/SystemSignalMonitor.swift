import AppKit
import CoreGraphics
import IOKit.ps

/// Publishes the `PlaybackSignals` the playback policy decides on. The real source is
/// `SystemSignalMonitor`; tests and previews use a fixed one.
protocol PlaybackSignalSource: AnyObject {
    var signals: PlaybackSignals { get }
    /// Called on the main actor whenever `signals` changes.
    var onChange: ((PlaybackSignals) -> Void)? { get set }
    /// The wallpaper windows whose visibility decides `isDesktopVisible`. Empty while no
    /// wallpaper is running, which also stops the full-screen checks.
    func monitorWallpaperWindows(_ windows: [NSWindow])
}

/// Signals that never change. Used when hosting unit tests and in previews.
final class FixedSignalSource: PlaybackSignalSource {
    var signals: PlaybackSignals
    var onChange: ((PlaybackSignals) -> Void)?

    init(_ signals: PlaybackSignals = PlaybackSignals()) {
        self.signals = signals
    }

    func monitorWallpaperWindows(_ windows: [NSWindow]) {}
}

/// Watches the system for anything that decides whether the wallpaper is worth playing.
///
/// Everything is event driven — notifications, window occlusion and an IOKit power-source run
/// loop source. Nothing polls. The only query that costs anything, the full-screen check, runs
/// debounced after an app activation, a Space change or a display change, and only while a
/// wallpaper is running.
@Observable
final class SystemSignalMonitor: PlaybackSignalSource {
    private(set) var signals = PlaybackSignals() {
        didSet {
            if signals != oldValue { onChange?(signals) }
        }
    }

    @ObservationIgnored var onChange: ((PlaybackSignals) -> Void)?

    @ObservationIgnored private var wallpaperWindows: [NSWindow] = []
    @ObservationIgnored private var windowObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    @ObservationIgnored nonisolated(unsafe) private var powerSourceLoopSource: CFRunLoopSource?
    @ObservationIgnored private var fullScreenCheck: Task<Void, Never>?
    @ObservationIgnored private var isSessionActive = true
    @ObservationIgnored private var isScreenLocked = false

    init() {
        signals.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        signals.isOnBattery = Self.isOnBatteryPower()
        startObserving()
    }

    deinit {
        if let powerSourceLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceLoopSource, .defaultMode)
        }
    }

    /// Removes every observer and the power-source run loop source.
    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        monitorWallpaperWindows([])
        if let powerSourceLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceLoopSource, .defaultMode)
            self.powerSourceLoopSource = nil
        }
    }

    func monitorWallpaperWindows(_ windows: [NSWindow]) {
        for token in windowObservers { NotificationCenter.default.removeObserver(token) }
        windowObservers = windows.map { window in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDesktopVisibility() }
            }
        }
        wallpaperWindows = windows
        updateDesktopVisibility()
        scheduleFullScreenCheck()
    }

    // MARK: - Observing

    private func startObserving() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.signals.isScreenAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.signals.isScreenAsleep = false }
        // Fast user switching.
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.setSession(active: false) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.setSession(active: true) }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.scheduleFullScreenCheck() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.scheduleFullScreenCheck() }

        // The lock screen isn't a session change; loginwindow announces it instead.
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.setScreen(locked: true) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.setScreen(locked: false) }

        // Posted on an arbitrary thread; the `.main` queue brings it back.
        observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange) {
            $0.signals.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) {
            $0.scheduleFullScreenCheck()
        }

        startObservingPowerSource()
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ handler: @escaping @MainActor (SystemSignalMonitor) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    private func startObservingPowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        // The callback runs on the run loop the source is added to: the main one.
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<SystemSignalMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.signals.isOnBattery = SystemSignalMonitor.isOnBatteryPower() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSourceLoopSource = source
    }

    // MARK: - Updating

    private func setSession(active: Bool) {
        isSessionActive = active
        signals.isSessionActive = isSessionActive && !isScreenLocked
    }

    private func setScreen(locked: Bool) {
        isScreenLocked = locked
        signals.isSessionActive = isSessionActive && !isScreenLocked
    }

    private func updateDesktopVisibility() {
        // With no wallpaper windows there is nothing to cover.
        signals.isDesktopVisible = wallpaperWindows.isEmpty
            || wallpaperWindows.contains { $0.occlusionState.contains(.visible) }
    }

    /// Checks for full-screen apps shortly after things settle: activating an app or entering a
    /// full-screen Space fires several notifications and animates for a moment.
    private func scheduleFullScreenCheck() {
        fullScreenCheck?.cancel()
        guard !wallpaperWindows.isEmpty else {
            signals.hasFullScreenApp = false
            return
        }
        fullScreenCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.signals.hasFullScreenApp = FullScreenDetector.everyDisplayIsCovered(
                windows: FullScreenDetector.onScreenWindows(),
                displays: NSScreen.screens.compactMap(\.displayID).map(CGDisplayBounds)
            )
        }
    }

    private nonisolated static func isOnBatteryPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}

/// Decides from the window server's window list whether full-screen apps hide the wallpaper.
nonisolated enum FullScreenDetector {
    /// On-screen windows as reported by `CGWindowListCopyWindowInfo`. Needs no Screen Recording
    /// permission: only bounds, layer, alpha and owner are read, never titles or contents.
    static func onScreenWindows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
    }

    /// True when every display is covered by an opaque, normal-level window. The wallpaper is one
    /// player shared by all displays, so it keeps playing while any display still shows it.
    ///
    /// - Parameters:
    ///   - windows: Window info dictionaries (`kCGWindow…` keys), in any order.
    ///   - displays: Display bounds in the same global, top-left-origin coordinates
    ///     (`CGDisplayBounds`).
    static func everyDisplayIsCovered(windows: [[String: Any]], displays: [CGRect]) -> Bool {
        guard !displays.isEmpty else { return false }
        let fullScreenBounds = windows.compactMap(fullScreenCandidateBounds)
        return displays.allSatisfy { display in
            fullScreenBounds.contains { covers($0, display) }
        }
    }

    /// Bounds of a normal-level (layer 0), visible window; nil for anything else (menu bar,
    /// Dock, overlays, panels, transparent windows).
    static func fullScreenCandidateBounds(_ info: [String: Any]) -> CGRect? {
        guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
        if let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0 { return nil }
        guard let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
        return bounds
    }

    /// Whether `window` covers the whole of `display`, allowing a point of rounding.
    static func covers(_ window: CGRect, _ display: CGRect) -> Bool {
        window.insetBy(dx: -1, dy: -1).contains(display)
    }
}

extension NSScreen {
    /// The display's current `CGDirectDisplayID`.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
