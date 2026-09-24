import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

/// A `width` × `height` sRGB image; `top` fills the top `topRows` rows (split into left/right
/// halves when `topRight` is given), `bottom` the rest.
private func makeImage(
    width: Int = 200,
    height: Int = 100,
    topRows: Int = 10,
    top: CGColor,
    topRight: CGColor? = nil,
    bottom: CGColor = CGColor(gray: 0.5, alpha: 1)
) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Core Graphics' origin is the bottom left; the image's top rows are the highest y.
    context.setFillColor(bottom)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let topRect = CGRect(x: 0, y: height - topRows, width: width, height: topRows)
    context.setFillColor(top)
    context.fill(topRect)
    if let topRight {
        context.setFillColor(topRight)
        context.fill(CGRect(x: width / 2, y: height - topRows, width: width - width / 2, height: topRows))
    }
    return context.makeImage()!
}

private func srgb(_ value: Double) -> CGColor {
    CGColor(srgbRed: value, green: value, blue: value, alpha: 1)
}

struct MenuBarContrastTests {
    @Test func luminanceOfKnownColors() {
        #expect(MenuBarContrast.relativeLuminance(red: 0, green: 0, blue: 0) == 0)
        #expect(abs(MenuBarContrast.relativeLuminance(red: 1, green: 1, blue: 1) - 1) < 1e-9)
        // sRGB 50% gray is about 21% as bright as white.
        #expect(abs(MenuBarContrast.relativeLuminance(red: 0.5, green: 0.5, blue: 0.5) - 0.214) < 0.001)
        // Green contributes most, blue least.
        let green = MenuBarContrast.relativeLuminance(red: 0, green: 1, blue: 0)
        let blue = MenuBarContrast.relativeLuminance(red: 0, green: 0, blue: 1)
        #expect(green > 0.7 && blue < 0.08)
    }

    @Test func contrastRatioMatchesWCAG() {
        #expect(abs(MenuBarContrast.contrastRatio(1, 0) - 21) < 1e-9)
        #expect(MenuBarContrast.contrastRatio(0.3, 0.3) == 1)
        #expect(MenuBarContrast.contrastRatio(0, 1) == MenuBarContrast.contrastRatio(1, 0))
    }

    @Test func aDarkStripGetsLightTextAndIsReadable() throws {
        let analysis = try #require(MenuBarContrast.analyze(makeImage(top: srgb(0.05)), screenHeight: 240))
        #expect(!analysis.usesDarkText)
        #expect(analysis.meanLuminance < 0.01)
        #expect(!analysis.isHardToRead)
    }

    @Test func aBrightStripGetsDarkTextAndIsReadable() throws {
        let analysis = try #require(MenuBarContrast.analyze(makeImage(top: srgb(0.95)), screenHeight: 240))
        #expect(analysis.usesDarkText)
        #expect(!analysis.isHardToRead)
    }

    @Test func aStripHalfBlackHalfWhiteIsHardToRead() throws {
        let image = makeImage(top: srgb(0), topRight: srgb(1))
        let analysis = try #require(MenuBarContrast.analyze(image, screenHeight: 240))
        #expect(analysis.isHardToRead)
        #expect(abs(analysis.lowContrastFraction - 0.5) < 0.1)
    }

    @Test func onlyTheTopOfTheImageCounts() throws {
        // A calm top over a busy rest: only the menu bar's height is sampled. With 100 rows for a
        // 240 pt display the strip is the top 10 rows.
        let image = makeImage(topRows: 10, top: srgb(0.05), bottom: srgb(1))
        let analysis = try #require(MenuBarContrast.analyze(image, screenHeight: 240))
        #expect(analysis.meanLuminance < 0.01)
    }

    @Test func dimmingDarkensTheStrip() throws {
        let image = makeImage(top: srgb(1))
        let plain = try #require(MenuBarContrast.analyze(image, screenHeight: 240))
        let dimmed = try #require(MenuBarContrast.analyze(image, screenHeight: 240, dim: 0.6))
        #expect(dimmed.meanLuminance < plain.meanLuminance)
        // 40% sRGB white is about 13% luminance, dark enough for light text.
        #expect(abs(dimmed.meanLuminance - MenuBarContrast.relativeLuminance(red: 0.4, green: 0.4, blue: 0.4)) < 0.01)
        #expect(!dimmed.usesDarkText)
    }

    @Test func degenerateInput() {
        #expect(MenuBarContrast.analyze(makeImage(top: srgb(1)), screenHeight: 0) == nil)
    }
}

struct ReadabilitySettingsTests {
    @Test func valuesAreClampedToTheirRanges() {
        let settings = ReadabilitySettings(dim: 0.9, blur: -3, vignette: true, speed: 0.1)
        #expect(settings.dim == 0.6)
        #expect(settings.blur == 0)
        #expect(settings.speed == 0.5)
        var edited = ReadabilitySettings()
        edited.blur = 50
        #expect(edited.clamped.blur == 20)
    }

    @Test func decodingClampsAndFillsInMissingValues() throws {
        let json = Data(#"{"dim": 2, "speed": 3}"#.utf8)
        let decoded = try JSONDecoder().decode(ReadabilitySettings.self, from: json)
        #expect(decoded == ReadabilitySettings(dim: 0.6, blur: 0, vignette: false, speed: 1))
    }

    @Test func fingerprintOnlyReflectsThePicture() {
        #expect(ReadabilitySettings().imageFingerprint == "plain")
        #expect(ReadabilitySettings(speed: 0.5).imageFingerprint == "plain")
        #expect(!ReadabilitySettings(speed: 0.5).altersImage)
        #expect(ReadabilitySettings(dim: 0.3, blur: 5, vignette: true).imageFingerprint == "d30b50v1")
        #expect(ReadabilitySettings(dim: 0.3).imageFingerprint != ReadabilitySettings(dim: 0.35).imageFingerprint)
    }
}

@MainActor
struct ReadabilityStorageTests {
    private let rain = URL(filePath: "/tmp/imported/rain.mp4")
    private let snow = URL(filePath: "/tmp/imported/snow.mp4")

    @Test func persistsPerWallpaper() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        let custom = ReadabilitySettings(dim: 0.3, blur: 4, vignette: true, speed: 0.75)
        settings.setReadability(custom, for: rain)

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.readability(for: rain) == custom)
        #expect(reloaded.readability(for: snow) == ReadabilitySettings())
    }

    @Test func defaultsAreNotStored() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.setReadability(ReadabilitySettings(dim: 0.2), for: rain)
        settings.setReadability(ReadabilitySettings(), for: rain)
        #expect(settings.readabilityByWallpaper.isEmpty)
    }

    @Test func outOfRangeValuesAreClampedWhenStored() {
        let settings = AppSettings(defaults: makeDefaults())
        var wild = ReadabilitySettings()
        wild.dim = 5
        settings.setReadability(wild, for: rain)
        #expect(settings.readability(for: rain).dim == 0.6)
    }
}

@MainActor
struct ReadabilityPlaybackTests {
    private let rain = URL(filePath: "/tmp/imported/rain.mp4")
    private let snow = URL(filePath: "/tmp/imported/snow.mp4")

    /// Waits for the manager's observation of the settings to catch up.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
    }

    @Test func eachDisplayGetsItsWallpapersSettingsAndSpeed() throws {
        let settings = AppSettings(defaults: makeDefaults())
        let slow = ReadabilitySettings(dim: 0.4, speed: 0.5)
        settings.setReadability(slow, for: snow)
        let presenter = FakePresenter()
        presenter.connectedDisplays = ["A", "B"]
        var engines: [URL: FakeEngine] = [:]
        let manager = WallpaperManager(
            settings: settings,
            assignments: DisplayAssignmentStore(fileURL: try makeTempDirectory().appending(path: "a.json")),
            presenter: presenter,
            signals: FakeSignals(),
            makeEngine: { url in
                let engine = FakeEngine(url: url)
                engines[url] = engine
                return engine
            }
        )
        manager.start(with: rain)
        manager.assign(snow, to: .display("B"))

        #expect(presenter.readabilities["A"] == ReadabilitySettings())
        #expect(presenter.readabilities["B"] == slow)
        #expect(engines[snow]?.rate == 0.5)
        #expect(engines[rain]?.rate == 1)
    }

    @Test func changesApplyLiveWithoutRestartingPlayback() async throws {
        let settings = AppSettings(defaults: makeDefaults())
        let presenter = FakePresenter()
        let signals = FakeSignals()
        var made: [FakeEngine] = []
        let manager = WallpaperManager(
            settings: settings,
            assignments: DisplayAssignmentStore(fileURL: try makeTempDirectory().appending(path: "a.json")),
            presenter: presenter,
            signals: signals,
            makeEngine: { url in
                let engine = FakeEngine(url: url)
                made.append(engine)
                return engine
            }
        )
        manager.start(with: rain)
        let updates = signals.monitoredWindowUpdates

        settings.setReadability(ReadabilitySettings(dim: 0.5, speed: 0.75), for: rain)
        await settle { presenter.readabilities["MAIN"]?.dim == 0.5 }

        #expect(presenter.readabilities["MAIN"]?.dim == 0.5)
        #expect(made.count == 1, "the same engine keeps playing")
        #expect(made.first?.rate == 0.75)
        #expect(made.first?.isPlaying == true)
        #expect(signals.monitoredWindowUpdates == updates, "no windows changed")
        _ = manager
    }
}

@MainActor
struct PlaybackEngineRateTests {
    @Test func speedBecomesThePlayersDefaultRate() {
        let engine = PlaybackEngine(url: URL(filePath: "/tmp/StarTorchTests/missing.mp4"))
        engine.rate = 0.5
        #expect(engine.player.defaultRate == 0.5)
        engine.pause()
        #expect(engine.player.rate == 0)
    }
}

struct StillFrameRendererTests {
    private func centerGray(of image: CGImage) -> Double {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let x = image.width / 2, y = image.height / 2
        let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let data = context.data!.bindMemory(to: UInt8.self, capacity: 4)
        return Double(data[0]) / 255
    }

    @Test func nothingToApplyReturnsTheSameImage() {
        let image = makeImage(top: srgb(1), bottom: srgb(1))
        #expect(StillFrameRenderer.render(image, readability: ReadabilitySettings(speed: 0.5)) === image)
    }

    @Test func dimDarkensTheFrame() {
        let image = makeImage(top: srgb(1), bottom: srgb(1))
        let dimmed = StillFrameRenderer.render(image, readability: ReadabilitySettings(dim: 0.5))
        #expect(dimmed.width == image.width && dimmed.height == image.height)
        #expect(abs(centerGray(of: dimmed) - 0.5) < 0.05)
    }

    @Test func vignetteLeavesTheCenterAlone() {
        let image = makeImage(top: srgb(1), bottom: srgb(1))
        let vignetted = StillFrameRenderer.render(image, readability: ReadabilitySettings(vignette: true))
        #expect(centerGray(of: vignetted) > 0.95)
    }
}
