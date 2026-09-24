import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

struct EnergyScoreTests {
    @Test func a720pClipAt30FpsAndModestBitrateIsLow() {
        let score = EnergyScore.score(width: 1_280, height: 720, fps: 30, bitrate: 4_000_000)
        #expect(score == .low)
    }

    @Test func missingMetadataIsTreatedGenerouslyAsLow() {
        #expect(EnergyScore.score(width: nil, height: nil, fps: nil, bitrate: nil) == .low)
    }

    @Test func a1080pClipAt30FpsIsMedium() {
        let score = EnergyScore.score(width: 1_920, height: 1_080, fps: 30, bitrate: 4_000_000)
        #expect(score == .medium)
    }

    @Test func a4KClipAt60FpsAndHighBitrateIsHigh() {
        let score = EnergyScore.score(width: 3_840, height: 2_160, fps: 60, bitrate: 40_000_000)
        #expect(score == .high)
    }

    @Test func highFrameRateAloneCanPushA720pClipToMedium() {
        let score = EnergyScore.score(width: 1_280, height: 720, fps: 60, bitrate: 4_000_000)
        #expect(score == .medium)
    }

    @Test func highBitrateAloneCanPushA720pClipToMedium() {
        let score = EnergyScore.score(width: 1_280, height: 720, fps: 30, bitrate: 20_000_000)
        #expect(score == .medium)
    }

    @Test func resolutionAtExactBoundariesRoundsDown() {
        // Exactly 720p: still the cheapest tier.
        #expect(EnergyScore.score(width: 1_280, height: 720, fps: 30, bitrate: 0) == .low)
        // One pixel over 720p: the next tier up.
        #expect(EnergyScore.score(width: 1_281, height: 720, fps: 0, bitrate: 0) == .medium)
    }

    @Test func scoreOrdering() {
        #expect(EnergyScore.low < EnergyScore.medium)
        #expect(EnergyScore.medium < EnergyScore.high)
    }
}

/// A plain, un-synchronized counter. Safe here because every increment happens on the actor
/// while the test `await`s the call that triggers it, so there's never real concurrent access —
/// `@unchecked` just tells the compiler what the `await` already guarantees.
private final class CallCounter: @unchecked Sendable {
    private(set) var count = 0
    func increment() { count += 1 }
}

@MainActor
struct EnergyScoreResolverTests {
    @Test func usesCatalogMetadataWithoutProbing() async {
        let calls = CallCounter()
        let resolver = EnergyScoreResolver { _ in
            calls.increment()
            return .high
        }
        let item = WallpaperItem(url: URL(string: "https://example.com/a.mp4")!, width: 1_280, height: 720, fps: 30, bitrate: 4_000_000)

        let score = await resolver.score(for: item)
        #expect(score == .low)
        #expect(calls.count == 0)
    }

    @Test func probesFilesWithoutCatalogMetadata() async {
        let calls = CallCounter()
        let resolver = EnergyScoreResolver { _ in
            calls.increment()
            return .high
        }
        let item = WallpaperItem(url: URL(filePath: "/tmp/imported/rain.mp4"))

        let score = await resolver.score(for: item)
        #expect(score == .high)
        #expect(calls.count == 1)
    }

    @Test func cachesTheResultPerURL() async {
        let calls = CallCounter()
        let resolver = EnergyScoreResolver { _ in
            calls.increment()
            return .medium
        }
        let item = WallpaperItem(url: URL(filePath: "/tmp/imported/snow.mp4"))

        _ = await resolver.score(for: item)
        _ = await resolver.score(for: item)
        #expect(calls.count == 1)
    }
}
