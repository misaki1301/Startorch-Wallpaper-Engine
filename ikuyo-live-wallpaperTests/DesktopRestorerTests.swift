import AppKit
import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

/// An in-memory desktop. Nothing here ever reaches NSWorkspace.
@MainActor
private final class FakeDesktop: DesktopImageSetting {
    struct Picture: Equatable {
        var url: URL
        var options: DesktopImageOptions
    }

    var pictures: [String: Picture]
    var connectedDisplayIDs: [String]
    var failingDisplays: Set<String> = []
    private(set) var setCalls: [(url: URL, displayID: String)] = []

    init(_ pictures: [String: Picture]) {
        self.pictures = pictures
        connectedDisplayIDs = pictures.keys.sorted()
    }

    func desktopImageURL(for displayID: String) -> URL? {
        connectedDisplayIDs.contains(displayID) ? pictures[displayID]?.url : nil
    }

    func desktopImageOptions(for displayID: String) -> DesktopImageOptions {
        pictures[displayID]?.options ?? DesktopImageOptions()
    }

    func setDesktopImageURL(_ url: URL, for displayID: String, options: DesktopImageOptions) throws {
        if failingDisplays.contains(displayID) { throw CocoaError(.fileWriteNoPermission) }
        setCalls.append((url, displayID))
        pictures[displayID] = Picture(url: url, options: options)
    }
}

private let beach = URL(filePath: "/System/Library/Desktop Pictures/Beach.heic")
private let mountains = URL(filePath: "/Users/me/Pictures/Mountains.jpg")
@MainActor private let centered = DesktopImageOptions(imageScaling: NSImageScaling.scaleNone.rawValue, allowClipping: false, fillColor: [0, 0, 0, 1])

@MainActor
struct DesktopRestorerTests {
    private let directory: URL
    private let desktop: FakeDesktop
    private let restorer: DesktopRestorer

    init() throws {
        directory = try makeTempDirectory()
        desktop = FakeDesktop([
            "DISPLAY-A": .init(url: beach, options: .fill),
            "DISPLAY-B": .init(url: mountains, options: centered),
        ])
        restorer = DesktopRestorer(desktop: desktop, directory: directory)
    }

    private func makeFrame(_ name: String = "frame.png") throws -> URL {
        try FileManager.default.createDirectory(at: restorer.framesDirectory, withIntermediateDirectories: true)
        let url = restorer.framesDirectory.appending(path: name)
        try Data("png".utf8).write(to: url)
        return url
    }

    @Test func showingAFrameRecordsOriginalsFirst() throws {
        let frame = try makeFrame()
        restorer.showFrame(frame)

        #expect(restorer.savedDesktops["DISPLAY-A"] == .init(imageURL: beach, options: .fill))
        #expect(restorer.savedDesktops["DISPLAY-B"] == .init(imageURL: mountains, options: centered))
        #expect(desktop.pictures.values.allSatisfy { $0.url == frame })
    }

    @Test func stopRestoresEveryDisplayAndDeletesTheRecord() throws {
        restorer.showFrame(try makeFrame())
        restorer.restoreOriginalDesktops()

        #expect(desktop.pictures["DISPLAY-A"] == .init(url: beach, options: .fill))
        #expect(desktop.pictures["DISPLAY-B"] == .init(url: mountains, options: centered))
        #expect(!FileManager.default.fileExists(atPath: restorer.recordURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: restorer.framesDirectory.path(percentEncoded: false)))
    }

    @Test func switchingWallpapersKeepsTheRealOriginal() throws {
        restorer.showFrame(try makeFrame("first.png"))
        let second = try makeFrame("second.png")
        restorer.showFrame(second)

        #expect(restorer.savedDesktops["DISPLAY-A"]?.imageURL == beach)
        #expect(desktop.pictures["DISPLAY-A"]?.url == second)
        // The previous frame is no longer referenced by any display.
        #expect(!FileManager.default.fileExists(atPath: restorer.framesDirectory.appending(path: "first.png").path(percentEncoded: false)))
    }

    @Test func relaunchAfterCrashRestoresFromDisk() throws {
        restorer.showFrame(try makeFrame())
        // Simulate `kill -9`: the process dies without restoring; a new one starts.
        let relaunched = DesktopRestorer(desktop: desktop, directory: directory)

        #expect(relaunched.hasSavedDesktops)
        relaunched.restoreOriginalDesktops()

        #expect(desktop.pictures["DISPLAY-A"]?.url == beach)
        #expect(desktop.pictures["DISPLAY-B"]?.url == mountains)
        #expect(!relaunched.hasSavedDesktops)
    }

    @Test func disconnectedDisplaysAreRestoredWhenTheyReturn() throws {
        restorer.showFrame(try makeFrame())
        desktop.connectedDisplayIDs = ["DISPLAY-A"]

        restorer.restoreOriginalDesktops()
        #expect(desktop.pictures["DISPLAY-A"]?.url == beach)
        #expect(Array(restorer.savedDesktops.keys) == ["DISPLAY-B"])

        desktop.connectedDisplayIDs = ["DISPLAY-A", "DISPLAY-B"]
        restorer.restoreOriginalDesktops()
        #expect(desktop.pictures["DISPLAY-B"]?.url == mountains)
        #expect(!restorer.hasSavedDesktops)
    }

    @Test func failedRestoresAreKeptForTheNextAttempt() throws {
        let frame = try makeFrame()
        restorer.showFrame(frame)
        desktop.failingDisplays = ["DISPLAY-B"]

        restorer.restoreOriginalDesktops()

        #expect(Array(restorer.savedDesktops.keys) == ["DISPLAY-B"])
        // DISPLAY-B still shows the frame, so the file must survive.
        #expect(FileManager.default.fileExists(atPath: frame.path(percentEncoded: false)))
    }

    @Test func neverRecordsOurOwnFrameAsTheOriginal() throws {
        let frame = try makeFrame()
        // e.g. the record file was lost while a frame was showing.
        desktop.pictures["DISPLAY-A"] = .init(url: frame, options: .fill)

        restorer.saveOriginalDesktops()

        #expect(restorer.savedDesktops["DISPLAY-A"] == nil)
        #expect(restorer.savedDesktops["DISPLAY-B"]?.imageURL == mountains)
    }

    @Test func displaysWhoseOriginalIsUnknownAreLeftAlone() throws {
        desktop.connectedDisplayIDs = ["DISPLAY-A", "DISPLAY-C"] // C reports no picture
        restorer.showFrame(try makeFrame())

        #expect(!desktop.setCalls.contains { $0.displayID == "DISPLAY-C" })
    }

    @Test func aPictureChosenMidSessionBecomesTheOneToRestore() throws {
        restorer.showFrame(try makeFrame("first.png"))
        desktop.pictures["DISPLAY-A"] = .init(url: mountains, options: centered) // user changed it
        restorer.showFrame(try makeFrame("second.png"))

        restorer.restoreOriginalDesktops()
        #expect(desktop.pictures["DISPLAY-A"] == .init(url: mountains, options: centered))
    }

    @Test func restoringWithNothingSavedDoesNothing() {
        restorer.restoreOriginalDesktops()
        #expect(desktop.setCalls.isEmpty)
    }
}

@MainActor
struct DesktopImageOptionsTests {
    @Test func roundTripsThroughWorkspaceOptions() throws {
        let options = DesktopImageOptions(
            imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
            allowClipping: false,
            fillColor: [0.25, 0.5, 0.75, 1]
        )
        let roundTripped = DesktopImageOptions(options.workspaceOptions)
        #expect(roundTripped.imageScaling == options.imageScaling)
        #expect(roundTripped.allowClipping == false)
        let color = try #require(roundTripped.fillColor)
        #expect(zip(color, [0.25, 0.5, 0.75, 1]).allSatisfy { abs($0 - $1) < 0.001 })
    }

    @Test func emptyOptionsStayEmpty() {
        #expect(DesktopImageOptions([:]) == DesktopImageOptions())
        #expect(DesktopImageOptions().workspaceOptions.isEmpty)
    }
}

struct AppEnvironmentTests {
    @Test func detectsTheTestHost() {
        // The app launched to host these tests must skip its launch-time desktop changes.
        #expect(AppEnvironment.isHostingTests)
    }
}
