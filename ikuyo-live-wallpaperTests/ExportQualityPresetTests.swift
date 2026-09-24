import CoreGraphics
import Testing
@testable import StarTorch_Wallpaper_Engine

struct ExportQualityPresetTests {
    private let uhd60 = (size: CGSize(width: 3840, height: 2160), fps: Float(60), bitrate: Float(60_000_000))

    @Test func batterySaverCapsAt1080pAnd24fps() {
        let settings = ExportQualityPreset.batterySaver.outputSettings(
            sourceSize: uhd60.size, sourceFrameRate: uhd60.fps, sourceBitrate: uhd60.bitrate
        )
        #expect(settings.renderSize == CGSize(width: 1920, height: 1080))
        #expect(settings.frameRate == 24)
        // 1920 × 1080 × 24 × 0.04 bpp
        #expect(settings.bitrate == 1_990_656)
    }

    @Test func balancedKeeps4KButCapsAt30fps() {
        let settings = ExportQualityPreset.balanced.outputSettings(
            sourceSize: uhd60.size, sourceFrameRate: uhd60.fps, sourceBitrate: uhd60.bitrate
        )
        #expect(settings.renderSize == CGSize(width: 3840, height: 2160))
        #expect(settings.frameRate == 30)
        // 3840 × 2160 × 30 × 0.07 bpp = 17.4 Mb/s, under half the source's 60 Mb/s.
        #expect(settings.bitrate == 17_418_240)
    }

    @Test func balancedScalesDownLargerThan4K() {
        let settings = ExportQualityPreset.balanced.outputSettings(
            sourceSize: CGSize(width: 7680, height: 4320), sourceFrameRate: 30, sourceBitrate: 0
        )
        #expect(settings.renderSize == CGSize(width: 3840, height: 2160))
    }

    @Test func bestKeepsSourceResolutionAndFrameRate() {
        let settings = ExportQualityPreset.best.outputSettings(
            sourceSize: CGSize(width: 5120, height: 2880), sourceFrameRate: 60, sourceBitrate: 0
        )
        #expect(settings.renderSize == CGSize(width: 5120, height: 2880))
        #expect(settings.frameRate == 60)
        #expect(settings.bitrate == Int((5120.0 * 2880 * 60 * 0.12).rounded()))
    }

    @Test func bitrateNeverExceedsAFractionOfTheSource() {
        let settings = ExportQualityPreset.best.outputSettings(
            sourceSize: CGSize(width: 1920, height: 1080), sourceFrameRate: 30, sourceBitrate: 5_000_000
        )
        #expect(settings.bitrate == 4_000_000)
    }

    @Test func bitrateHasAFloor() {
        let settings = ExportQualityPreset.batterySaver.outputSettings(
            sourceSize: CGSize(width: 320, height: 240), sourceFrameRate: 30, sourceBitrate: 100_000
        )
        #expect(settings.bitrate == ExportQualityPreset.minimumBitrate)
    }

    @Test(arguments: ExportQualityPreset.allCases)
    func presetsNeverUpscaleOrSpeedUp(_ preset: ExportQualityPreset) {
        let settings = preset.outputSettings(
            sourceSize: CGSize(width: 1280, height: 720), sourceFrameRate: 23.976, sourceBitrate: 3_000_000
        )
        #expect(settings.renderSize == CGSize(width: 1280, height: 720))
        #expect(settings.frameRate == 23.976)
    }

    @Test func portraitSourceFitsThePortraitBox() {
        let settings = ExportQualityPreset.batterySaver.outputSettings(
            sourceSize: CGSize(width: 2160, height: 3840), sourceFrameRate: 30, sourceBitrate: 0
        )
        #expect(settings.renderSize == CGSize(width: 1080, height: 1920))
    }

    @Test func unknownFrameRateFallsBack() {
        let settings = ExportQualityPreset.best.outputSettings(
            sourceSize: CGSize(width: 1920, height: 1080), sourceFrameRate: 0, sourceBitrate: 0
        )
        #expect(settings.frameRate == VideoConverter.fallbackFrameRate)
    }

    @Test func fittedSizesAreEven() {
        // 1921×1081 scaled into 1920×1080 must still give encoder-friendly even sizes.
        let size = ExportQualityPreset.fittedSize(CGSize(width: 1921, height: 1081), within: (1920, 1080))
        #expect(size.width.truncatingRemainder(dividingBy: 2) == 0)
        #expect(size.height.truncatingRemainder(dividingBy: 2) == 0)
        #expect(size.width <= 1920 && size.height <= 1080)

        let odd = ExportQualityPreset.fittedSize(CGSize(width: 641, height: 359), within: nil)
        #expect(odd == CGSize(width: 640, height: 358))
    }

    @Test func estimatedFileSizeFollowsBitrateAndDuration() {
        let settings = ExportOutputSettings(renderSize: .zero, frameRate: 30, bitrate: 8_000_000)
        #expect(settings.estimatedFileSize(seconds: 10) == 10_000_000)
        #expect(settings.estimatedFileSize(seconds: 0) == 0)
        #expect(settings.estimatedFileSize(seconds: .nan) == 0)
    }
}
