import CoreGraphics
import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

struct FullScreenDetectorTests {
    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// An external display to the right, in the same top-left-origin global space.
    private let external = CGRect(x: 1512, y: -200, width: 2560, height: 1440)

    private func window(_ bounds: CGRect, layer: Int = 0, alpha: Double? = 1) -> [String: Any] {
        var info: [String: Any] = [
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowBounds as String: bounds.dictionaryRepresentation,
            kCGWindowOwnerPID as String: NSNumber(value: 42),
        ]
        if let alpha { info[kCGWindowAlpha as String] = NSNumber(value: alpha) }
        return info
    }

    @Test func aFullScreenWindowCoversItsDisplay() {
        #expect(FullScreenDetector.everyDisplayIsCovered(windows: [window(builtIn)], displays: [builtIn]))
    }

    @Test func aMaximizedWindowBelowTheMenuBarDoesNotCount() {
        let maximized = CGRect(x: 0, y: 33, width: 1512, height: 949)
        #expect(!FullScreenDetector.everyDisplayIsCovered(windows: [window(maximized)], displays: [builtIn]))
    }

    @Test func menuBarDockAndOverlayLayersAreIgnored() {
        let windows = [window(builtIn, layer: 24), window(builtIn, layer: 20), window(builtIn, layer: 1000)]
        #expect(!FullScreenDetector.everyDisplayIsCovered(windows: windows, displays: [builtIn]))
    }

    @Test func transparentWindowsAreIgnored() {
        #expect(!FullScreenDetector.everyDisplayIsCovered(windows: [window(builtIn, alpha: 0)], displays: [builtIn]))
        // A missing alpha means opaque.
        #expect(FullScreenDetector.everyDisplayIsCovered(windows: [window(builtIn, alpha: nil)], displays: [builtIn]))
    }

    @Test func toleratesSubpointRounding() {
        let rounded = CGRect(x: 0.5, y: 0, width: 1511.5, height: 982)
        #expect(FullScreenDetector.everyDisplayIsCovered(windows: [window(rounded)], displays: [builtIn]))
    }

    @Test func everyDisplayMustBeCovered() {
        let displays = [builtIn, external]
        #expect(!FullScreenDetector.everyDisplayIsCovered(windows: [window(builtIn)], displays: displays))
        #expect(!FullScreenDetector.everyDisplayIsCovered(windows: [window(external)], displays: displays))
        #expect(FullScreenDetector.everyDisplayIsCovered(windows: [window(external), window(builtIn)], displays: displays))
    }

    @Test func aWindowOnAnotherDisplayDoesNotCover() {
        #expect(!FullScreenDetector.everyDisplayIsCovered(windows: [window(external)], displays: [builtIn]))
    }

    @Test func noDisplaysOrMalformedInfoMeansNotCovered() {
        #expect(!FullScreenDetector.everyDisplayIsCovered(windows: [window(builtIn)], displays: []))
        let malformed: [String: Any] = [kCGWindowLayer as String: NSNumber(value: 0)]
        #expect(FullScreenDetector.fullScreenCandidateBounds(malformed) == nil)
        #expect(!FullScreenDetector.everyDisplayIsCovered(windows: [malformed], displays: [builtIn]))
    }
}
