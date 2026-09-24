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
        case .user: "Paused by you"
        case .screenAsleep: "Display is asleep"
        case .sessionInactive: "Screen is locked"
        case .fullScreenApp: "A full-screen app is open"
        case .desktopCovered: "Desktop is covered"
        case .lowPowerMode: "Low Power Mode is on"
        case .onBattery: "Running on battery"
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
