import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

@MainActor
struct PauseSettingsTests {
    @Test func defaultsMatchTheRoadmap() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.pauseWhenDesktopCovered)
        #expect(settings.pauseInLowPowerMode)
        #expect(!settings.pauseOnBattery)
        #expect(settings.pauseForFullScreenApps)
        #expect(settings.pauseRules == PauseRules())
    }

    @Test func togglesPersistAndMapToRules() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.pauseWhenDesktopCovered = false
        settings.pauseInLowPowerMode = false
        settings.pauseOnBattery = true
        settings.pauseForFullScreenApps = false

        let expected = PauseRules(whenDesktopCovered: false, inLowPowerMode: false, onBattery: true, forFullScreenApps: false)
        #expect(settings.pauseRules == expected)
        #expect(AppSettings(defaults: defaults).pauseRules == expected)
    }

    /// Waits for the manager's observation of the settings to catch up.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
    }

    @Test func togglingASettingAppliesImmediately() async {
        let settings = AppSettings(defaults: makeDefaults())
        let signals = FakeSignals()
        var engine: FakeEngine?
        let manager = WallpaperManager(
            restorer: DesktopRestorer(desktop: InertDesktop(), directory: .temporaryDirectory),
            settings: settings,
            presenter: FakePresenter(),
            signals: signals,
            makeEngine: { url in
                let made = FakeEngine(url: url)
                engine = made
                return made
            }
        )
        manager.start(with: URL(filePath: "/tmp/imported/rain.mp4"))
        signals.signals.isOnBattery = true
        #expect(manager.isPlaying)

        settings.pauseOnBattery = true
        await settle { manager.pauseReason == .onBattery }
        #expect(manager.pauseReason == .onBattery)
        #expect(engine?.isPlaying == false)

        settings.pauseOnBattery = false
        await settle { manager.isPlaying }
        #expect(manager.isPlaying)
        #expect(engine?.isPlaying == true)

        // Still following after more than one change.
        signals.signals.isDesktopVisible = false
        #expect(manager.pauseReason == .desktopCovered)
        settings.pauseWhenDesktopCovered = false
        await settle { manager.isPlaying }
        #expect(manager.isPlaying)
    }
}
