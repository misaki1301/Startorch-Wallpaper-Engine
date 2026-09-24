import CoreGraphics
import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

private func isClose(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.001) -> Bool {
    abs(a - b) <= tolerance
}

struct FocalPointTests {
    @Test func valuesAreClampedToTheUnitSquare() {
        let point = FocalPoint(x: -0.5, y: 1.7)
        #expect(point == FocalPoint(x: 0, y: 1))
        #expect(FocalPoint(x: .nan, y: .infinity) == .center)
    }

    @Test func mapsViewLocationsToVideoCoordinatesAndBack() {
        let videoRect = CGRect(x: 100, y: 50, width: 400, height: 200)
        let point = FocalPoint(location: CGPoint(x: 200, y: 100), in: videoRect)
        #expect(point == FocalPoint(x: 0.25, y: 0.25))
        #expect(point.location(in: videoRect) == CGPoint(x: 200, y: 100))

        // Clicks in the letterbox clamp to the video's edge.
        #expect(FocalPoint(location: CGPoint(x: 0, y: 400), in: videoRect) == FocalPoint(x: 0, y: 1))
    }

    @Test func roundTripsThroughJSON() throws {
        let point = FocalPoint(x: 0.3, y: 0.8)
        let decoded = try JSONDecoder().decode(FocalPoint.self, from: JSONEncoder().encode(point))
        #expect(decoded == point)
    }
}

struct FocalPointLayoutTests {
    private let landscape = CGSize(width: 1920, height: 1080)
    private let square = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    @Test func centeredFocalPointMatchesPlainAspectFill() {
        let frame = FocalPointLayout.aspectFillFrame(contentSize: landscape, in: square)
        #expect(isClose(frame.height, 1000))
        #expect(isClose(frame.width, 1777.778))
        #expect(isClose(frame.midX, square.midX))
        #expect(isClose(frame.minY, 0))
    }

    @Test func focalPointShiftsTheCropButNeverExposesAnEdge() {
        let left = FocalPointLayout.aspectFillFrame(contentSize: landscape, in: square, focalPoint: FocalPoint(x: 0, y: 0.5))
        #expect(isClose(left.minX, 0))

        let right = FocalPointLayout.aspectFillFrame(contentSize: landscape, in: square, focalPoint: FocalPoint(x: 1, y: 0.5))
        #expect(isClose(right.maxX, 1000))

        // 40% across: the focal point lands in the middle of the screen.
        let inside = FocalPointLayout.aspectFillFrame(contentSize: landscape, in: square, focalPoint: FocalPoint(x: 0.4, y: 0.5))
        #expect(isClose(inside.minX + 0.4 * inside.width, 500))

        for frame in [left, right, inside] {
            #expect(frame.minX <= 0.001 && frame.maxX >= 999.999)
            #expect(frame.minY <= 0.001 && frame.maxY >= 999.999)
        }
    }

    @Test func verticalFocalPointAppliesToTallContent() {
        // A portrait phone clip on a 16:10 display crops top and bottom.
        let portrait = CGSize(width: 1080, height: 1920)
        let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let top = FocalPointLayout.aspectFillFrame(contentSize: portrait, in: screen, focalPoint: FocalPoint(x: 0.5, y: 0.1))

        #expect(isClose(top.width, 1600))
        #expect(isClose(top.minX, 0))
        #expect(isClose(top.minY, 0))
    }

    @Test func matchingAspectRatioIgnoresTheFocalPoint() {
        let frame = FocalPointLayout.aspectFillFrame(
            contentSize: landscape,
            in: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            focalPoint: FocalPoint(x: 0, y: 1)
        )
        #expect(frame == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    @Test func visibleRegionIsTheCroppedPartOfTheVideo() {
        let centered = FocalPointLayout.visibleRegion(contentSize: landscape, screenAspect: 1, focalPoint: .center)
        #expect(isClose(centered.width, 0.5625))
        #expect(isClose(centered.height, 1))
        #expect(isClose(centered.midX, 0.5))

        let left = FocalPointLayout.visibleRegion(contentSize: landscape, screenAspect: 1, focalPoint: FocalPoint(x: 0, y: 0.5))
        #expect(isClose(left.minX, 0))
    }

    @Test func degenerateInputsFallBackSafely() {
        #expect(FocalPointLayout.aspectFillFrame(contentSize: .zero, in: square) == square)
        #expect(FocalPointLayout.visibleRegion(contentSize: landscape, screenAspect: 0, focalPoint: .center)
            == CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
