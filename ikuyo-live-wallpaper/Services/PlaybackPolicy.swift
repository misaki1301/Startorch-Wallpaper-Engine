import Foundation

/// What the system currently says about whether anyone can see, or would want, the wallpaper.
nonisolated struct PlaybackSignals: Equatable, Sendable {
    /// At least one wallpaper window is at least partly visible.
    var isDesktopVisible = true
    /// The displays are asleep.
    var isScreenAsleep = false
    /// False while the screen is locked or another user is switched in.
    var isSessionActive = true
    var isLowPowerMode = false
    var isOnBattery = false
    /// Every display is covered by a full-screen app.
    var hasFullScreenApp = false
    /// Displays (by UUID) whose wallpaper window is at least partly visible, when known.
    var visibleDisplays: Set<String>?
    /// Displays (by UUID) covered by a full-screen app, when known.
    var fullScreenDisplays: Set<String>?

    /// The signals as seen by a wallpaper shown only on `displays`: it counts as visible if any
    /// of its displays is, and as hidden by full-screen apps only if all of them are covered.
    /// Without per-display information the global values are kept.
    func restricted(to displays: Set<String>) -> PlaybackSignals {
        guard !displays.isEmpty else { return self }
        var signals = self
        if let visibleDisplays {
            signals.isDesktopVisible = !displays.isDisjoint(with: visibleDisplays)
        }
        if let fullScreenDisplays {
            signals.hasFullScreenApp = displays.isSubset(of: fullScreenDisplays)
        }
        return signals
    }
}

/// The pause rules the user can turn on or off. Screen sleep and a locked or inactive
/// session always pause, since nobody can see the wallpaper then.
nonisolated struct PauseRules: Equatable, Sendable {
    var whenDesktopCovered = true
    var inLowPowerMode = true
    var onBattery = false
    var forFullScreenApps = true
}

/// Why the wallpaper is paused. Cases are declared in priority order: when several apply,
/// the earliest one is reported.
nonisolated enum PauseReason: String, CaseIterable, Codable, Sendable {
    case user
    case screenAsleep
    case sessionInactive
    case fullScreenApp
    case desktopCovered
    case lowPowerMode
    case onBattery

    /// A short, plain-language explanation for the UI.
    var label: String {
        switch self {
        case .user: String(localized: "pauseReason.user", defaultValue: "Paused by you")
        case .screenAsleep: String(localized: "pauseReason.screenAsleep", defaultValue: "Display is asleep")
        case .sessionInactive: String(localized: "pauseReason.sessionInactive", defaultValue: "Screen is locked")
        case .fullScreenApp: String(localized: "pauseReason.fullScreenApp", defaultValue: "A full-screen app is open")
        case .desktopCovered: String(localized: "pauseReason.desktopCovered", defaultValue: "Desktop is covered")
        case .lowPowerMode: String(localized: "pauseReason.lowPowerMode", defaultValue: "Low Power Mode is on")
        case .onBattery: String(localized: "pauseReason.onBattery", defaultValue: "Running on battery")
        }
    }
}

nonisolated enum PlaybackDecision: Equatable, Sendable {
    case play
    case pause(reason: PauseReason)

    var pauseReason: PauseReason? {
        if case .pause(let reason) = self { reason } else { nil }
    }
}

/// Decides whether the wallpaper should play. Pure and deterministic, so every rule is testable
/// without AppKit.
nonisolated struct PlaybackPolicy: Equatable, Sendable {
    var rules: PauseRules

    init(rules: PauseRules = PauseRules()) {
        self.rules = rules
    }

    func decision(for signals: PlaybackSignals, userPaused: Bool) -> PlaybackDecision {
        let reason = PauseReason.allCases.first { applies($0, signals: signals, userPaused: userPaused) }
        return reason.map { .pause(reason: $0) } ?? .play
    }

    private func applies(_ reason: PauseReason, signals: PlaybackSignals, userPaused: Bool) -> Bool {
        switch reason {
        case .user: userPaused
        case .screenAsleep: signals.isScreenAsleep
        case .sessionInactive: !signals.isSessionActive
        case .fullScreenApp: rules.forFullScreenApps && signals.hasFullScreenApp
        case .desktopCovered: rules.whenDesktopCovered && !signals.isDesktopVisible
        case .lowPowerMode: rules.inLowPowerMode && signals.isLowPowerMode
        case .onBattery: rules.onBattery && signals.isOnBattery
        }
    }
}
