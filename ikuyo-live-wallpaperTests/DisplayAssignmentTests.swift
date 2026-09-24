import AppKit
import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

private let rain = URL(filePath: "/tmp/imported/rain.mp4")
private let snow = URL(filePath: "/tmp/imported/snow.mp4")
private let remote = URL(string: "https://example.com/stars.mp4")!

struct DisplayAssignmentsTests {
    @Test func displaysWithoutAnOverrideFollowAllDisplays() {
        let assignments = DisplayAssignments(allDisplays: rain, perDisplay: ["B": snow])
        #expect(assignments.resolved(for: ["A", "B"]) == ["A": rain, "B": snow])
    }

    @Test func displaysWithNothingAssignedAreLeftOut() {
        let assignments = DisplayAssignments(perDisplay: ["B": snow])
        #expect(assignments.resolved(for: ["A", "B"]) == ["B": snow])
    }

    @Test func allDisplaysReplacesEveryOverride() {
        var assignments = DisplayAssignments(allDisplays: rain, perDisplay: ["B": snow, "C": remote])
        assignments.assign(remote, to: .allDisplays)
        #expect(assignments == DisplayAssignments(allDisplays: remote))
    }

    @Test func assigningTheDefaultDropsTheOverride() {
        var assignments = DisplayAssignments(allDisplays: rain, perDisplay: ["B": snow])
        assignments.assign(rain, to: .display("B"))
        #expect(!assignments.hasOverride(forDisplay: "B"))
        assignments.assign(snow, to: .display("B"))
        #expect(assignments.hasOverride(forDisplay: "B"))
        assignments.clearOverride(forDisplay: "B")
        #expect(assignments.wallpaper(forDisplay: "B") == rain)
    }

    @Test func removingAWallpaperForgetsItEverywhere() {
        var assignments = DisplayAssignments(allDisplays: rain, perDisplay: ["B": rain, "C": snow])
        assignments.remove(rain)
        #expect(assignments == DisplayAssignments(perDisplay: ["C": snow]))
        #expect(assignments.allURLs == [snow])
    }

    @Test func missingLocalFilesAreDroppedButRemoteURLsKept() {
        var assignments = DisplayAssignments(allDisplays: remote, perDisplay: ["B": rain, "C": snow])
        assignments.removeMissingFiles { $0 == snow }
        #expect(assignments == DisplayAssignments(allDisplays: remote, perDisplay: ["C": snow]))
    }
}

@MainActor
struct DisplayAssignmentStoreTests {
    @Test func persistsAcrossLaunches() throws {
        let file = try makeTempDirectory().appending(path: "display-assignments.json")
        let store = DisplayAssignmentStore(fileURL: file)
        store.assign(rain, to: .allDisplays)
        store.assign(snow, to: .display("EXTERNAL"))

        let reloaded = DisplayAssignmentStore(fileURL: file)
        #expect(reloaded.assignments == DisplayAssignments(allDisplays: rain, perDisplay: ["EXTERNAL": snow]))
    }

    @Test func startsEmptyWithoutAFileOrWithAGarbledOne() throws {
        let directory = try makeTempDirectory()
        #expect(DisplayAssignmentStore(fileURL: directory.appending(path: "none.json")).assignments.isEmpty)
        let garbled = directory.appending(path: "garbled.json")
        try Data("{".utf8).write(to: garbled)
        #expect(DisplayAssignmentStore(fileURL: garbled).assignments.isEmpty)
    }
}

struct DisplayArrangementTests {
    @Test func sideBySideDisplaysKeepTheirProportions() {
        let builtIn = CGRect(x: 0, y: 0, width: 1500, height: 1000)
        let external = CGRect(x: 1500, y: 0, width: 3000, height: 2000)
        let fitted = DisplayArrangement.fit(["A": builtIn, "B": external], in: CGSize(width: 450, height: 400), spacing: 0)

        // 4500 × 2000 points scaled by 0.1, centered vertically in 400.
        #expect(fitted["A"] == CGRect(x: 0, y: 200, width: 150, height: 100))
        #expect(fitted["B"] == CGRect(x: 150, y: 100, width: 300, height: 200))
    }

    @Test func aDisplayAboveIsDrawnAbove() {
        // AppKit's y axis points up; the view's points down.
        let main = CGRect(x: 0, y: 0, width: 100, height: 100)
        let above = CGRect(x: 0, y: 100, width: 100, height: 100)
        let fitted = DisplayArrangement.fit(["main": main, "above": above], in: CGSize(width: 100, height: 200), spacing: 0)
        #expect(fitted["above"]?.minY == 0)
        #expect(fitted["main"]?.minY == 100)
    }

    @Test func spacingInsetsEachDisplay() {
        let fitted = DisplayArrangement.fit(["A": CGRect(x: 0, y: 0, width: 100, height: 100)], in: CGSize(width: 100, height: 100), spacing: 10)
        #expect(fitted["A"] == CGRect(x: 5, y: 5, width: 90, height: 90))
    }

    @Test func nothingToLayOut() {
        #expect(DisplayArrangement.fit([:], in: CGSize(width: 100, height: 100)).isEmpty)
        #expect(DisplayArrangement.fit(["A": .zero], in: CGSize(width: 100, height: 100)).isEmpty)
        #expect(DisplayArrangement.fit(["A": CGRect(x: 0, y: 0, width: 10, height: 10)], in: .zero).isEmpty)
    }
}

struct WallpaperDragPayloadTests {
    @Test func roundTripsThroughText() {
        for url in [rain, remote, URL(filePath: "/tmp/with space/rain.mp4")] {
            #expect(WallpaperDragPayload(text: WallpaperDragPayload(url: url).text)?.url == url)
        }
    }

    @Test func ignoresOtherText() {
        #expect(WallpaperDragPayload(text: "https://example.com/rain.mp4") == nil)
        #expect(WallpaperDragPayload(text: "startorch-wallpaper:") == nil)
        #expect(WallpaperDragPayload(text: "hello") == nil)
    }
}

struct PerDisplaySignalsTests {
    @Test func aWallpaperIsVisibleIfAnyOfItsDisplaysIs() {
        var signals = PlaybackSignals()
        signals.visibleDisplays = ["B"]
        #expect(!signals.restricted(to: ["A"]).isDesktopVisible)
        #expect(signals.restricted(to: ["A", "B"]).isDesktopVisible)
    }

    @Test func fullScreenOnlyWhenAllOfItsDisplaysAreCovered() {
        var signals = PlaybackSignals()
        signals.fullScreenDisplays = ["A"]
        #expect(signals.restricted(to: ["A"]).hasFullScreenApp)
        #expect(!signals.restricted(to: ["A", "B"]).hasFullScreenApp)
        #expect(!signals.restricted(to: ["B"]).hasFullScreenApp)
    }

    @Test func withoutPerDisplayInformationTheGlobalValuesApply() {
        var signals = PlaybackSignals()
        signals.isDesktopVisible = false
        signals.hasFullScreenApp = true
        #expect(signals.restricted(to: ["A"]) == signals)
        #expect(signals.restricted(to: []) == signals)
    }

    @Test func coveredDisplaysAreReportedOneByOne() {
        let a = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let b = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let window: [String: Any] = [
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowBounds as String: b.dictionaryRepresentation,
            kCGWindowAlpha as String: NSNumber(value: 1),
        ]
        #expect(FullScreenDetector.coveredDisplays(windows: [window], displays: ["A": a, "B": b]) == ["B"])
        #expect(FullScreenDetector.coveredDisplays(windows: [], displays: ["A": a]).isEmpty)
    }
}

@MainActor
struct MultiDisplayManagerTests {
    let presenter = FakePresenter()
    let signals = FakeSignals()
    private let box = WallpaperManagerTests.EngineBox()

    var engines: [FakeEngine] { box.engines }

    init() {
        presenter.connectedDisplays = ["A", "B"]
    }

    func makeManager(settings: AppSettings? = nil, store: DisplayAssignmentStore? = nil) throws -> WallpaperManager {
        let box = box
        return WallpaperManager(
            restorer: DesktopRestorer(desktop: InertDesktop(), directory: .temporaryDirectory),
            settings: settings,
            assignments: try store ?? DisplayAssignmentStore(fileURL: makeTempDirectory().appending(path: "a.json")),
            presenter: presenter,
            signals: signals,
            makeEngine: { url in
                let engine = FakeEngine(url: url)
                box.engines.append(engine)
                return engine
            }
        )
    }

    private func engine(for url: URL) -> FakeEngine? {
        engines.last { $0.url == url && !$0.isTornDown }
    }

    @Test func oneEngineIsSharedByEveryDisplayShowingTheSameWallpaper() throws {
        let manager = try makeManager()
        manager.start(with: rain)
        #expect(engines.count == 1)
        #expect(presenter.currentLayout == ["A": rain, "B": rain])
        #expect(presenter.players["A"] === presenter.players["B"])
        #expect(manager.displayedURLs == ["A": rain, "B": rain])
    }

    @Test func twoDisplaysCanShowDifferentWallpapers() throws {
        let manager = try makeManager()
        manager.start(with: rain)
        manager.assign(snow, to: .display("B"))

        #expect(presenter.currentLayout == ["A": rain, "B": snow])
        #expect(engines.count == 2)
        #expect(engine(for: rain)?.isPlaying == true)
        #expect(engine(for: snow)?.isPlaying == true)
        #expect(presenter.players["A"] !== presenter.players["B"])
        #expect(manager.isShowing(snow))
        #expect(manager.currentURL == rain, "the main display's wallpaper")
    }

    @Test func anEngineNoLongerShownIsTornDown() throws {
        let manager = try makeManager()
        manager.start(with: rain)
        manager.assign(snow, to: .display("B"))
        let snowEngine = try #require(engine(for: snow))

        manager.clearOverride(forDisplay: "B")
        #expect(snowEngine.isTornDown)
        #expect(presenter.currentLayout == ["A": rain, "B": rain])
        #expect(!manager.isShowing(snow))
    }

    @Test func oldEnginesLiveUntilTheTransitionFinishes() throws {
        let manager = try makeManager()
        manager.start(with: rain)
        let rainEngine = try #require(engine(for: rain))
        presenter.defersCompletions = true

        manager.start(with: snow)
        #expect(!rainEngine.isTornDown, "still fading out")
        presenter.finishTransitions()
        #expect(rainEngine.isTornDown)
    }

    @Test func eachEnginePausesOnlyWhenAllOfItsDisplaysAreCovered() throws {
        let manager = try makeManager()
        manager.start(with: rain)
        manager.assign(snow, to: .display("B"))

        signals.signals.fullScreenDisplays = ["B"]
        #expect(engine(for: rain)?.isPlaying == true)
        #expect(engine(for: snow)?.isPlaying == false)
        #expect(manager.pauseReason == nil, "something still plays")
        #expect(manager.isPlaying)

        signals.signals.fullScreenDisplays = ["A", "B"]
        #expect(engine(for: rain)?.isPlaying == false)
        #expect(manager.pauseReason == .fullScreenApp)
    }

    @Test func aSharedEngineKeepsPlayingWhileOneOfItsDisplaysIsVisible() throws {
        let manager = try makeManager()
        manager.start(with: rain)
        signals.signals.visibleDisplays = ["B"]
        #expect(engine(for: rain)?.isPlaying == true)
        signals.signals.visibleDisplays = []
        #expect(engine(for: rain)?.isPlaying == false)
        #expect(manager.pauseReason == .desktopCovered)
    }

    @Test func theUserPausePausesEveryEngine() throws {
        let manager = try makeManager()
        manager.start(with: rain)
        manager.assign(snow, to: .display("B"))
        manager.pause()
        #expect(engines.allSatisfy { !$0.isPlaying })
        #expect(manager.pauseReason == .user)
        manager.resume()
        #expect(engine(for: rain)?.isPlaying == true)
        #expect(engine(for: snow)?.isPlaying == true)
    }

    @Test func assignmentsSurviveADisconnectAndReconnect() throws {
        let manager = try makeManager()
        manager.start(with: rain)
        manager.assign(snow, to: .display("B"))

        presenter.connectedDisplays = ["A"]
        presenter.simulateScreenChange()
        #expect(presenter.currentLayout == ["A": rain])
        #expect(engine(for: snow) == nil, "nothing shows it any more")
        #expect(manager.assignments.assignments.perDisplay["B"] == snow)

        presenter.connectedDisplays = ["A", "B"]
        presenter.simulateScreenChange()
        #expect(presenter.currentLayout == ["A": rain, "B": snow])
        #expect(engine(for: snow)?.isPlaying == true)
    }

    @Test func aDisplayWithTheOnlyAssignmentComesBackOnReconnect() throws {
        let manager = try makeManager()
        manager.assign(snow, to: .display("B"))
        presenter.connectedDisplays = ["A"]
        presenter.simulateScreenChange()
        #expect(presenter.currentLayout.isEmpty)
        #expect(manager.isActive)

        presenter.connectedDisplays = ["A", "B"]
        presenter.simulateScreenChange()
        #expect(presenter.currentLayout == ["B": snow])
    }

    @Test func resumeOnLaunchRestoresEveryDisplay() throws {
        let file = try makeTempDirectory().appending(path: "a.json")
        let saved = DisplayAssignmentStore(fileURL: file)
        saved.assign(rain, to: .allDisplays)
        saved.assign(snow, to: .display("B"))

        let manager = try makeManager(store: DisplayAssignmentStore(fileURL: file))
        manager.resumeLastSession(fallback: remote, fileExists: { _ in true })
        #expect(manager.isActive)
        #expect(presenter.currentLayout == ["A": rain, "B": snow])
    }

    @Test func resumeOnLaunchFallsBackToTheLastWallpaper() throws {
        let manager = try makeManager()
        manager.resumeLastSession(fallback: remote, fileExists: { _ in true })
        #expect(presenter.currentLayout == ["A": remote, "B": remote])
    }

    @Test func resumeOnLaunchSkipsTrashedFiles() throws {
        let manager = try makeManager()
        manager.assignments.assign(rain, to: .allDisplays)
        manager.assignments.assign(snow, to: .display("B"))
        manager.resumeLastSession(fallback: nil, fileExists: { $0 == snow })
        #expect(presenter.currentLayout == ["B": snow])

        let empty = try makeManager()
        empty.resumeLastSession(fallback: nil, fileExists: { _ in false })
        #expect(!empty.isActive)
    }

    @Test func playAfterStopBringsBackEveryDisplay() throws {
        let manager = try makeManager()
        manager.start(with: rain)
        manager.assign(snow, to: .display("B"))
        manager.stop()
        #expect(manager.displayedURLs.isEmpty)
        #expect(engines.allSatisfy { $0.isTornDown })

        manager.play(orStart: remote)
        #expect(presenter.currentLayout == ["A": rain, "B": snow])
    }

    @Test func removingAWallpaperStopsOnlyWhenNothingIsLeft() throws {
        let settings = AppSettings(defaults: makeDefaults())
        let manager = try makeManager(settings: settings)
        manager.start(with: rain)
        manager.assign(snow, to: .display("B"))

        manager.remove(snow)
        #expect(manager.isActive)
        #expect(presenter.currentLayout == ["A": rain, "B": rain])

        manager.remove(rain)
        #expect(!manager.isActive)
        #expect(presenter.restoreCount == 1)
        #expect(settings.lastWallpaperURL == nil)
    }

    @Test func startingDuringTheFadeOutDoesNotRestoreTheDesktop() throws {
        let manager = try makeManager()
        manager.start(with: rain)
        presenter.defersCompletions = true
        manager.stop()
        manager.start(with: snow)
        presenter.finishTransitions()
        #expect(presenter.restoreCount == 0)
        #expect(manager.isActive)
    }
}

@MainActor
struct PerDisplayFramesTests {
    private final class Desktop: DesktopImageSetting {
        var pictures: [String: URL]
        init(_ pictures: [String: URL]) { self.pictures = pictures }
        var connectedDisplayIDs: [String] { pictures.keys.sorted() }
        func desktopImageURL(for displayID: String) -> URL? { pictures[displayID] }
        func desktopImageOptions(for displayID: String) -> DesktopImageOptions { DesktopImageOptions() }
        func setDesktopImageURL(_ url: URL, for displayID: String, options: DesktopImageOptions) throws {
            pictures[displayID] = url
        }
    }

    private let beach = URL(filePath: "/System/Library/Desktop Pictures/Beach.heic")
    private let hills = URL(filePath: "/Users/me/Pictures/Hills.jpg")

    private func frame(_ name: String, in restorer: DesktopRestorer) throws -> URL {
        try FileManager.default.createDirectory(at: restorer.framesDirectory, withIntermediateDirectories: true)
        let url = restorer.framesDirectory.appending(path: name)
        try Data("png".utf8).write(to: url)
        return url
    }

    @Test func eachDisplayGetsItsOwnFrame() throws {
        let desktop = Desktop(["A": beach, "B": hills])
        let restorer = DesktopRestorer(desktop: desktop, directory: try makeTempDirectory())
        let rainFrame = try frame("rain.png", in: restorer)
        let snowFrame = try frame("snow.png", in: restorer)

        restorer.showFrames(["A": rainFrame, "B": snowFrame])
        #expect(desktop.pictures == ["A": rainFrame, "B": snowFrame])

        restorer.restoreOriginalDesktops()
        #expect(desktop.pictures == ["A": beach, "B": hills])
    }

    @Test func aDisplayLeftWithoutAWallpaperGetsItsOriginalBack() throws {
        let desktop = Desktop(["A": beach, "B": hills])
        let restorer = DesktopRestorer(desktop: desktop, directory: try makeTempDirectory())
        let rainFrame = try frame("rain.png", in: restorer)
        let snowFrame = try frame("snow.png", in: restorer)
        restorer.showFrames(["A": rainFrame, "B": snowFrame])

        restorer.showFrames(["A": rainFrame])
        #expect(desktop.pictures == ["A": rainFrame, "B": hills])
        #expect(restorer.savedDesktops["B"] == nil)
        #expect(!FileManager.default.fileExists(atPath: snowFrame.path(percentEncoded: false)))
    }

    @Test func untouchedDisplaysKeepTheirFrame() throws {
        let desktop = Desktop(["A": beach, "B": hills])
        let restorer = DesktopRestorer(desktop: desktop, directory: try makeTempDirectory())
        let rainFrame = try frame("rain.png", in: restorer)
        let snowFrame = try frame("snow.png", in: restorer)
        restorer.showFrames(["A": rainFrame, "B": snowFrame])

        restorer.showFrames(["A": rainFrame], leaving: ["B"])
        #expect(desktop.pictures["B"] == snowFrame)
        #expect(FileManager.default.fileExists(atPath: snowFrame.path(percentEncoded: false)))
    }
}
