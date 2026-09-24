import Foundation
import ServiceManagement
import Testing
@testable import StarTorch_Wallpaper_Engine

@MainActor
struct ResumeOnLaunchTests {
    private let video = URL(filePath: "/tmp/imported/rain.mp4")

    private func makeSettings(resume: Bool = true, wasActive: Bool = true, last: URL?) -> AppSettings {
        let settings = AppSettings(defaults: makeDefaults())
        settings.resumeWallpaperOnLaunch = resume
        settings.wallpaperWasActive = wasActive
        settings.lastWallpaperURL = last
        return settings
    }

    @Test func resumeIsOnByDefaultButNothingWasPlaying() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.resumeWallpaperOnLaunch)
        #expect(!settings.wallpaperWasActive)
        #expect(settings.wallpaperToResume() == nil)
    }

    @Test func resumesTheLastWallpaperWhenItWasPlaying() {
        let settings = makeSettings(last: video)
        #expect(settings.wallpaperToResume(fileExists: { _ in true }) == video)
    }

    @Test func doesNotResumeWhenTheSettingIsOff() {
        let settings = makeSettings(resume: false, last: video)
        #expect(settings.wallpaperToResume(fileExists: { _ in true }) == nil)
    }

    @Test func doesNotResumeAfterTheUserStoppedIt() {
        let settings = makeSettings(wasActive: false, last: video)
        #expect(settings.wallpaperToResume(fileExists: { _ in true }) == nil)
    }

    @Test func skipsLocalFilesThatNoLongerExist() {
        let settings = makeSettings(last: video)
        #expect(settings.wallpaperToResume(fileExists: { _ in false }) == nil)
    }

    @Test func remoteURLsDoNotNeedToExistLocally() {
        let remote = URL(string: "https://example.com/rain.mp4")!
        let settings = makeSettings(last: remote)
        #expect(settings.wallpaperToResume(fileExists: { _ in false }) == remote)
    }

    @Test func playIsNotOfferedForATrashedLastWallpaper() {
        let settings = makeSettings(wasActive: false, last: video)
        #expect(settings.availableLastWallpaperURL(fileExists: { _ in true }) == video)
        #expect(settings.availableLastWallpaperURL(fileExists: { _ in false }) == nil)
    }

    @Test func persistsResumeSettings() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.resumeWallpaperOnLaunch = false
        settings.wallpaperWasActive = true

        let reloaded = AppSettings(defaults: defaults)
        #expect(!reloaded.resumeWallpaperOnLaunch)
        #expect(reloaded.wallpaperWasActive)
    }
}

/// Records calls instead of touching the real login items.
@MainActor
private final class FakeLoginItem: LoginItemControlling {
    var status: SMAppService.Status = .notRegistered
    var statusAfterRegister: SMAppService.Status = .enabled
    var error: (any Error)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    func register() throws {
        registerCount += 1
        if let error { throw error }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCount += 1
        if let error { throw error }
        status = .notRegistered
    }
}

@MainActor
struct LaunchAtLoginTests {
    @Test func reflectsTheSystemStatus() {
        let fake = FakeLoginItem()
        fake.status = .enabled
        #expect(LaunchAtLogin(service: fake).isEnabled)
    }

    @Test func enablingRegistersTheApp() {
        let fake = FakeLoginItem()
        let launchAtLogin = LaunchAtLogin(service: fake)

        launchAtLogin.setEnabled(true)

        #expect(fake.registerCount == 1)
        #expect(launchAtLogin.isEnabled)
    }

    @Test func disablingUnregistersTheApp() {
        let fake = FakeLoginItem()
        fake.status = .enabled
        let launchAtLogin = LaunchAtLogin(service: fake)

        launchAtLogin.setEnabled(false)

        #expect(fake.unregisterCount == 1)
        #expect(!launchAtLogin.isEnabled)
    }

    @Test func pendingApprovalCountsAsOnAndIsSurfaced() {
        let fake = FakeLoginItem()
        fake.statusAfterRegister = .requiresApproval
        let launchAtLogin = LaunchAtLogin(service: fake)

        launchAtLogin.setEnabled(true)

        #expect(launchAtLogin.isEnabled)
        #expect(launchAtLogin.needsApproval)
    }

    @Test func failuresAreReportedAndStateStaysTruthful() {
        let fake = FakeLoginItem()
        fake.error = CocoaError(.featureUnsupported)
        let launchAtLogin = LaunchAtLogin(service: fake)

        launchAtLogin.setEnabled(true)

        #expect(!launchAtLogin.isEnabled)
        #expect(launchAtLogin.errorMessage != nil)
    }

    @Test func refreshPicksUpChangesMadeInSystemSettings() {
        let fake = FakeLoginItem()
        let launchAtLogin = LaunchAtLogin(service: fake)
        fake.status = .enabled

        launchAtLogin.refresh()

        #expect(launchAtLogin.isEnabled)
    }
}
