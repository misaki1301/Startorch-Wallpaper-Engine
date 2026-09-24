import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

struct DisplayTransitionTests {
    @Test func samePlayerOnlyUpdates() {
        #expect(DisplayTransition.plan(current: ["A": 1], target: ["A": 1]) == ["A": .update])
    }

    @Test func aDifferentPlayerCrossfades() {
        #expect(DisplayTransition.plan(current: ["A": 1, "B": 1], target: ["A": 2, "B": 1]) == ["A": .crossfade, "B": .update])
    }

    @Test func newDisplaysFadeInAndDroppedOnesAreRemoved() {
        let plan = DisplayTransition.plan(current: ["A": 1], target: ["B": 1])
        #expect(plan == ["A": .remove, "B": .fadeIn])
    }

    @Test func reduceMotionMakesEverythingInstant() {
        #expect(DisplayTransition.duration(reduceMotion: true) == .zero)
        #expect(DisplayTransition.duration(reduceMotion: false) == .milliseconds(600))
    }

    @Test func durationsConvertToSeconds() {
        #expect(Duration.milliseconds(600).timeInterval == 0.6)
        #expect(Duration.seconds(2).timeInterval == 2)
        #expect(Duration.zero.timeInterval == 0)
    }
}

@MainActor
struct CrossfadeManagerTests {
    private let rain = URL(filePath: "/tmp/imported/rain.mp4")
    private let snow = URL(filePath: "/tmp/imported/snow.mp4")

    private func makeManager(presenter: FakePresenter, engines: WallpaperManagerTests.EngineBox) throws -> WallpaperManager {
        WallpaperManager(
            restorer: DesktopRestorer(desktop: InertDesktop(), directory: .temporaryDirectory),
            assignments: DisplayAssignmentStore(fileURL: try makeTempDirectory().appending(path: "a.json")),
            presenter: presenter,
            signals: FakeSignals(),
            makeEngine: { url in
                let engine = FakeEngine(url: url)
                engines.engines.append(engine)
                return engine
            }
        )
    }

    @Test func stoppingFadesOutBeforeTearingDownAndRestoring() throws {
        let presenter = FakePresenter()
        let box = WallpaperManagerTests.EngineBox()
        let manager = try makeManager(presenter: presenter, engines: box)
        manager.start(with: rain)
        presenter.defersCompletions = true

        manager.stop()
        #expect(!manager.isActive, "the UI reflects the stop at once")
        #expect(box.engines.first?.isTornDown == false, "the video keeps going while it fades")
        #expect(presenter.restoreCount == 0, "the still frame shows until the fade ends")

        presenter.finishTransitions()
        #expect(box.engines.first?.isTornDown == true)
        #expect(presenter.restoreCount == 1)
    }

    @Test func switchingKeepsTheOldVideoPlayingUntilTheCrossfadeEnds() throws {
        let presenter = FakePresenter()
        let box = WallpaperManagerTests.EngineBox()
        let manager = try makeManager(presenter: presenter, engines: box)
        manager.start(with: rain)
        presenter.defersCompletions = true

        manager.start(with: snow)
        let old = try #require(box.engines.first)
        #expect(!old.isTornDown)
        #expect(presenter.currentLayout == ["MAIN": snow])
        #expect(manager.currentURL == snow)

        presenter.finishTransitions()
        #expect(old.isTornDown)
        #expect(box.engines.last?.isPlaying == true)
    }
}
