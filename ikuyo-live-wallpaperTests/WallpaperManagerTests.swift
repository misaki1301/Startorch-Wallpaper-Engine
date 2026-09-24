import AppKit
import AVFoundation
import Testing
@testable import StarTorch_Wallpaper_Engine

/// Records play/pause instead of decoding video.
@MainActor
final class FakeEngine: WallpaperPlayback {
    let url: URL
    let player = AVPlayer()
    private(set) var isPlaying = false
    private(set) var isTornDown = false

    init(url: URL) { self.url = url }

    func play() { if !isTornDown { isPlaying = true } }
    func pause() { isPlaying = false }
    func tearDown() { isPlaying = false; isTornDown = true }
}

/// Keeps track of what would be on screen, without windows or the desktop picture.
@MainActor
final class FakePresenter: WallpaperPresenting {
    var connectedDisplays = ["MAIN"]
    var windowsByDisplay: [String: NSWindow] = [:]
    var onDisplaysChange: (() -> Void)?
    /// Every layout presented, as display → wallpaper.
    private(set) var layouts: [[String: URL]] = []
    /// The players of the last layout, by display.
    private(set) var players: [String: AVPlayer] = [:]
    private(set) var isShowing = false
    private(set) var restoreCount = 0
    /// When set, completions wait for `finishTransitions()` instead of running at once, like a
    /// crossfade or fade-out in progress.
    var defersCompletions = false
    private var pendingCompletions: [() -> Void] = []

    /// The distinct wallpapers presented over time, in order.
    var presented: [URL] {
        var result: [URL] = []
        for layout in layouts {
            for url in Set(layout.values).sorted(by: { $0.absoluteString < $1.absoluteString }) where result.last != url {
                result.append(url)
            }
        }
        return result
    }

    var currentLayout: [String: URL] { layouts.last ?? [:] }

    func present(_ layout: [String: PresentedWallpaper], completion: @escaping () -> Void) {
        layouts.append(layout.mapValues(\.url))
        players = layout.mapValues(\.player)
        isShowing = !layout.isEmpty
        finish(completion)
    }

    func dismiss(animated: Bool, completion: @escaping () -> Void) {
        isShowing = false
        players = [:]
        finish(completion)
    }

    func restoreOriginalDesktops() { restoreCount += 1 }

    func finishTransitions() {
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        for completion in completions { completion() }
    }

    private func finish(_ completion: @escaping () -> Void) {
        if defersCompletions { pendingCompletions.append(completion) } else { completion() }
    }

    /// What `WallpaperController` does after a display is plugged in or out.
    func simulateScreenChange() { onDisplaysChange?() }
}

@MainActor
final class FakeSignals: PlaybackSignalSource {
    var signals = PlaybackSignals() {
        didSet { onChange?(signals) }
    }
    var onChange: ((PlaybackSignals) -> Void)?
    private(set) var monitoredWindowUpdates = 0

    func monitorWallpaperWindows(_ windows: [String: NSWindow]) { monitoredWindowUpdates += 1 }
}

@MainActor
struct WallpaperManagerTests {
    let presenter = FakePresenter()
    let signals = FakeSignals()
    let video = URL(filePath: "/tmp/imported/rain.mp4")
    let other = URL(filePath: "/tmp/imported/snow.mp4")
    private let box = EngineBox()

    /// Every engine the manager created, in order.
    final class EngineBox {
        var engines: [FakeEngine] = []
    }

    var engines: [FakeEngine] { box.engines }
    var engine: FakeEngine? { box.engines.last }

    func makeManager(settings: AppSettings? = nil) -> WallpaperManager {
        let box = box
        return WallpaperManager(
            restorer: DesktopRestorer(desktop: InertDesktop(), directory: .temporaryDirectory),
            settings: settings,
            presenter: presenter,
            signals: signals,
            makeEngine: { url in
                let engine = FakeEngine(url: url)
                box.engines.append(engine)
                return engine
            }
        )
    }

    @Test func startPlaysAndShowsTheWallpaper() {
        let manager = makeManager()
        manager.start(with: video)
        #expect(manager.isActive)
        #expect(manager.isPlaying)
        #expect(!manager.isPaused)
        #expect(manager.pauseReason == nil)
        #expect(manager.currentURL == video)
        #expect(presenter.presented == [video])
        #expect(engine?.isPlaying == true)
        #expect(signals.monitoredWindowUpdates > 0)
    }

    @Test func coveringTheDesktopPausesAutomaticallyAndUncoveringResumes() {
        let manager = makeManager()
        manager.start(with: video)

        signals.signals.isDesktopVisible = false
        #expect(engine?.isPlaying == false)
        #expect(manager.pauseReason == .desktopCovered)
        #expect(!manager.isPaused, "an automatic pause is not a user pause")

        signals.signals.isDesktopVisible = true
        #expect(engine?.isPlaying == true)
        #expect(manager.pauseReason == nil)
    }

    @Test func automaticResumeNeverOverridesAUserPause() {
        let manager = makeManager()
        manager.start(with: video)
        manager.pause()
        #expect(manager.pauseReason == .user)

        signals.signals.isDesktopVisible = false
        signals.signals.isDesktopVisible = true
        signals.signals.isScreenAsleep = true
        signals.signals.isScreenAsleep = false

        #expect(manager.isPaused)
        #expect(manager.pauseReason == .user)
        #expect(engine?.isPlaying == false)
    }

    @Test func resumingWhileCoveredStaysPausedUntilUncovered() {
        let manager = makeManager()
        manager.start(with: video)
        manager.pause()
        signals.signals.isDesktopVisible = false

        manager.resume()
        #expect(!manager.isPaused)
        #expect(manager.pauseReason == .desktopCovered)
        #expect(engine?.isPlaying == false)

        signals.signals.isDesktopVisible = true
        #expect(engine?.isPlaying == true)
    }

    @Test func startingWhileTheScreenIsLockedStartsPaused() {
        signals.signals.isSessionActive = false
        let manager = makeManager()
        manager.start(with: video)
        #expect(manager.isActive)
        #expect(manager.pauseReason == .sessionInactive)
        #expect(engine?.isPlaying == false)
    }

    @Test func changingThePolicyAppliesImmediately() {
        let manager = makeManager()
        manager.start(with: video)
        signals.signals.isOnBattery = true
        #expect(manager.isPlaying, "battery rule is off by default")

        manager.policy.rules.onBattery = true
        #expect(manager.pauseReason == .onBattery)
        #expect(engine?.isPlaying == false)

        manager.policy.rules.onBattery = false
        #expect(engine?.isPlaying == true)
    }

    @Test func screenChangesDoNotRestartPlayback() {
        let manager = makeManager()
        manager.start(with: video)
        let updatesBefore = signals.monitoredWindowUpdates

        presenter.simulateScreenChange()
        presenter.simulateScreenChange()

        #expect(engines.count == 1)
        #expect(engine?.isPlaying == true)
        #expect(!(engine?.isTornDown ?? true))
        #expect(presenter.presented == [video])
        #expect(signals.monitoredWindowUpdates == updatesBefore + 2, "new windows are watched for occlusion")
        #expect(presenter.players["MAIN"] === engine?.player)
    }

    @Test func switchingWallpapersReplacesTheEngineWithoutRestoringTheDesktop() {
        let manager = makeManager()
        manager.start(with: video)
        manager.pause()
        manager.start(with: other)

        #expect(engines.count == 2)
        #expect(engines[0].isTornDown)
        #expect(engines[1].isPlaying)
        #expect(!manager.isPaused, "a new wallpaper starts playing")
        #expect(manager.currentURL == other)
        #expect(presenter.restoreCount == 0)
    }

    @Test func stopTearsDownAndRestoresTheDesktop() {
        let settings = AppSettings(defaults: makeDefaults())
        let manager = makeManager(settings: settings)
        manager.start(with: video)
        #expect(settings.wallpaperWasActive)
        #expect(settings.lastWallpaperURL == video)

        manager.stop()
        #expect(!manager.isActive)
        #expect(manager.pauseReason == nil)
        #expect(manager.currentURL == nil)
        #expect(engine?.isTornDown == true)
        #expect(!presenter.isShowing)
        #expect(presenter.restoreCount == 1)
        #expect(!settings.wallpaperWasActive)
    }

    @Test func signalsWhileStoppedDoNothing() {
        let manager = makeManager()
        signals.signals.isDesktopVisible = false
        signals.signals.isDesktopVisible = true
        #expect(!manager.isActive)
        #expect(manager.pauseReason == nil)
        #expect(engines.isEmpty)
        manager.pause()
        #expect(!manager.isPaused, "nothing to pause")
    }

    @Test func playStartsTheLastWallpaperOrResumes() {
        let manager = makeManager()
        manager.play(orStart: nil)
        #expect(!manager.isActive)

        manager.play(orStart: video)
        #expect(manager.currentURL == video)
        manager.pause()
        manager.play(orStart: other)
        #expect(manager.currentURL == video, "resumes rather than switching")
        #expect(manager.isPlaying)
    }

    @Test func recoveryOnlyRestoresWhileStopped() {
        let manager = makeManager()
        manager.recoverDesktopFromPreviousSession()
        #expect(presenter.restoreCount == 1)
        manager.start(with: video)
        manager.recoverDesktopFromPreviousSession()
        #expect(presenter.restoreCount == 1)
    }
}

struct ScreenLayoutChangesTests {
    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)

    @Test func unchangedScreensNeedNoWork() {
        let changes = ScreenLayoutChanges(windows: ["1": builtIn, "2": external], screens: ["1": builtIn, "2": external])
        #expect(changes.isEmpty)
    }

    @Test func pluggingInADisplayOnlyAddsIt() {
        let changes = ScreenLayoutChanges(windows: ["1": builtIn], screens: ["1": builtIn, "2": external])
        #expect(changes == ScreenLayoutChanges(added: ["2"]))
    }

    @Test func unpluggingADisplayOnlyRemovesIt() {
        let changes = ScreenLayoutChanges(windows: ["1": builtIn, "2": external], screens: ["1": builtIn])
        #expect(changes == ScreenLayoutChanges(removed: ["2"]))
    }

    @Test func aResolutionOrArrangementChangeResizesInPlace() {
        let moved = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let changes = ScreenLayoutChanges(windows: ["1": builtIn, "2": external], screens: ["1": builtIn, "2": moved])
        #expect(changes == ScreenLayoutChanges(resized: ["2"]))
    }
}

@MainActor
struct PlaybackEngineTests {
    /// Nothing is decoded: the file doesn't exist and no layer is attached.
    private let missing = URL(filePath: "/tmp/StarTorchTests/missing.mp4")

    @Test func startsPausedMutedAndLetsTheDisplaySleep() {
        let engine = PlaybackEngine(url: missing)
        #expect(!engine.isPlaying)
        #expect(engine.player.isMuted)
        #expect(!engine.player.preventsDisplaySleepDuringVideoPlayback)
    }

    @Test func playAndPauseAreIdempotent() {
        let engine = PlaybackEngine(url: missing)
        engine.play()
        engine.play()
        #expect(engine.isPlaying)
        engine.pause()
        engine.pause()
        #expect(!engine.isPlaying)
        #expect(engine.player.rate == 0)
    }

    @Test func aTornDownEngineStaysStopped() {
        let engine = PlaybackEngine(url: missing)
        engine.play()
        engine.tearDown()
        engine.play()
        #expect(!engine.isPlaying)
        #expect(engine.player.rate == 0)
    }
}
