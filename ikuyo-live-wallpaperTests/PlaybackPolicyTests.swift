import Testing
@testable import StarTorch_Wallpaper_Engine

struct PlaybackPolicyTests {
    private let allOn = PauseRules(whenDesktopCovered: true, inLowPowerMode: true, onBattery: true, forFullScreenApps: true)
    private let allOff = PauseRules(whenDesktopCovered: false, inLowPowerMode: false, onBattery: false, forFullScreenApps: false)

    private func decide(_ signals: PlaybackSignals, rules: PauseRules, userPaused: Bool = false) -> PlaybackDecision {
        PlaybackPolicy(rules: rules).decision(for: signals, userPaused: userPaused)
    }

    @Test func defaultRulesMatchTheSettingsDefaults() {
        let rules = PauseRules()
        #expect(rules.whenDesktopCovered)
        #expect(rules.inLowPowerMode)
        #expect(!rules.onBattery)
        #expect(rules.forFullScreenApps)
    }

    @Test func playsWhenNothingApplies() {
        #expect(decide(PlaybackSignals(), rules: allOn) == .play)
    }

    @Test func userPauseAlwaysWins() {
        #expect(decide(PlaybackSignals(), rules: allOff, userPaused: true) == .pause(reason: .user))
        var everything = PlaybackSignals()
        everything.isScreenAsleep = true
        everything.isSessionActive = false
        everything.isDesktopVisible = false
        #expect(decide(everything, rules: allOn, userPaused: true) == .pause(reason: .user))
    }

    @Test func screenSleepPausesEvenWithEveryRuleOff() {
        var signals = PlaybackSignals()
        signals.isScreenAsleep = true
        #expect(decide(signals, rules: allOff) == .pause(reason: .screenAsleep))
    }

    @Test func inactiveSessionPausesEvenWithEveryRuleOff() {
        var signals = PlaybackSignals()
        signals.isSessionActive = false
        #expect(decide(signals, rules: allOff) == .pause(reason: .sessionInactive))
    }

    /// Sets the signal that triggers an optional rule, and switches the rule on or off.
    private func trigger(_ reason: PauseReason, signals: inout PlaybackSignals, rules: inout PauseRules, enabled: Bool) {
        switch reason {
        case .fullScreenApp: signals.hasFullScreenApp = true; rules.forFullScreenApps = enabled
        case .desktopCovered: signals.isDesktopVisible = false; rules.whenDesktopCovered = enabled
        case .lowPowerMode: signals.isLowPowerMode = true; rules.inLowPowerMode = enabled
        case .onBattery: signals.isOnBattery = true; rules.onBattery = enabled
        case .user, .screenAsleep, .sessionInactive: Issue.record("\(reason) is not optional")
        }
    }

    @Test(arguments: [PauseReason.fullScreenApp, .desktopCovered, .lowPowerMode, .onBattery])
    func optionalRulePausesOnlyWhenEnabled(reason: PauseReason) {
        var signals = PlaybackSignals()
        var enabled = allOff
        trigger(reason, signals: &signals, rules: &enabled, enabled: true)
        #expect(decide(signals, rules: enabled) == .pause(reason: reason))

        var disabledSignals = PlaybackSignals()
        var disabled = allOn
        trigger(reason, signals: &disabledSignals, rules: &disabled, enabled: false)
        #expect(decide(disabledSignals, rules: disabled) == .play)
    }

    @Test func reasonsFollowTheDeclaredPriority() {
        #expect(PauseReason.allCases == [
            .user, .screenAsleep, .sessionInactive, .fullScreenApp, .desktopCovered, .lowPowerMode, .onBattery,
        ])
        var signals = PlaybackSignals(
            isDesktopVisible: false, isScreenAsleep: false, isSessionActive: true,
            isLowPowerMode: true, isOnBattery: true, hasFullScreenApp: true
        )
        #expect(decide(signals, rules: allOn) == .pause(reason: .fullScreenApp))
        signals.hasFullScreenApp = false
        #expect(decide(signals, rules: allOn) == .pause(reason: .desktopCovered))
        signals.isDesktopVisible = true
        #expect(decide(signals, rules: allOn) == .pause(reason: .lowPowerMode))
        signals.isLowPowerMode = false
        #expect(decide(signals, rules: allOn) == .pause(reason: .onBattery))
    }

    /// Every combination of signals, user pause and rules, against an independent reference.
    @Test func everyCombinationMatchesTheReference() {
        for bits in 0..<(1 << 11) {
            func bit(_ n: Int) -> Bool { bits & (1 << n) != 0 }
            let signals = PlaybackSignals(
                isDesktopVisible: bit(0), isScreenAsleep: bit(1), isSessionActive: bit(2),
                isLowPowerMode: bit(3), isOnBattery: bit(4), hasFullScreenApp: bit(5)
            )
            let userPaused = bit(6)
            let rules = PauseRules(
                whenDesktopCovered: bit(7), inLowPowerMode: bit(8), onBattery: bit(9), forFullScreenApps: bit(10)
            )

            let expected: PlaybackDecision =
                if userPaused { .pause(reason: .user) }
                else if signals.isScreenAsleep { .pause(reason: .screenAsleep) }
                else if !signals.isSessionActive { .pause(reason: .sessionInactive) }
                else if rules.forFullScreenApps && signals.hasFullScreenApp { .pause(reason: .fullScreenApp) }
                else if rules.whenDesktopCovered && !signals.isDesktopVisible { .pause(reason: .desktopCovered) }
                else if rules.inLowPowerMode && signals.isLowPowerMode { .pause(reason: .lowPowerMode) }
                else if rules.onBattery && signals.isOnBattery { .pause(reason: .onBattery) }
                else { .play }

            #expect(decide(signals, rules: rules, userPaused: userPaused) == expected, "combination \(bits)")
        }
    }

    @Test func everyReasonHasALabel() {
        for reason in PauseReason.allCases {
            #expect(!reason.label.isEmpty)
        }
        #expect(PlaybackDecision.play.pauseReason == nil)
        #expect(PlaybackDecision.pause(reason: .onBattery).pauseReason == .onBattery)
    }
}
