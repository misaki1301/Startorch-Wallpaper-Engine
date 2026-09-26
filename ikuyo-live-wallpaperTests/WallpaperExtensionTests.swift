import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

// Covers the public-API half of Route A (the system wallpaper extension): the hand-off format the
// app writes and the extension reads, the playback rules the extension applies to the host's
// presentation signals, and the app-side exporter. The private host bridge can only be exercised
// by WallpaperAgent itself (see docs/wallpaper-extension.md for the manual test plan).

struct SystemWallpaperManifestTests {
    @Test func roundTripsThroughTheStore() throws {
        let store = SystemWallpaperStore(root: try makeTempDirectory())
        let manifest = SystemWallpaperManifest(
            title: "Rainy Window", clipFileName: "abc.mp4", posterFileName: "abc.jpg",
            sourceURL: "https://example.com/rain.mp4", dim: 0.3, vignette: true, speed: 0.75,
            exportedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try store.writeManifest(manifest)
        #expect(store.readManifest() == manifest)
        #expect(store.clipURL(for: manifest) == store.clipsDirectory.appending(path: "abc.mp4"))
        #expect(store.posterURL(for: manifest) == store.postersDirectory.appending(path: "abc.jpg"))
    }

    @Test func clampsReadabilityValues() {
        let manifest = SystemWallpaperManifest(
            title: "x", clipFileName: "a.mp4", posterFileName: nil, sourceURL: "", dim: 5, vignette: false, speed: 0.1
        )
        #expect(manifest.dim == 0.6)
        #expect(manifest.speed == 0.5)
    }

    @Test func rejectsFileNamesThatEscapeTheirFolder() throws {
        let store = SystemWallpaperStore(root: try makeTempDirectory())
        for name in ["../secret.mp4", "a/b.mp4", "..", ".hidden.mp4", ""] {
            try store.writeManifest(SystemWallpaperManifest(
                title: "x", clipFileName: name, posterFileName: nil, sourceURL: "", dim: 0, vignette: false, speed: 1
            ))
            #expect(store.readManifest() == nil, "\(name) must be rejected")
        }
        try store.writeManifest(SystemWallpaperManifest(
            title: "x", clipFileName: "ok.mp4", posterFileName: "../poster.jpg", sourceURL: "", dim: 0, vignette: false, speed: 1
        ))
        #expect(store.readManifest() == nil)
    }

    @Test func ignoresAnUnknownVersionAndGarbage() throws {
        let store = SystemWallpaperStore(root: try makeTempDirectory())
        #expect(store.readManifest() == nil)
        var manifest = SystemWallpaperManifest(
            title: "x", clipFileName: "a.mp4", posterFileName: nil, sourceURL: "", dim: 0, vignette: false, speed: 1
        )
        manifest.version = 99
        try store.writeManifest(manifest)
        #expect(store.readManifest() == nil)
        try Data("not json".utf8).write(to: store.manifestURL)
        #expect(store.readManifest() == nil)
    }

    @Test func usesTheTeamPrefixedAppGroup() {
        // Must match both targets' entitlements; team-prefixed so macOS 15+ doesn't prompt.
        #expect(SystemWallpaperStore.appGroupIdentifier == "B97JTSGWZ2.com.shibuyaxpress.ikuyo-live-wallpaper")
    }
}

struct SystemWallpaperPresentationTests {
    @Test func parsesTheHostsCaseNames() {
        #expect(SystemWallpaperPresentation(modeName: "default", activityName: "active") == .init(mode: .desktop, activity: .active))
        #expect(SystemWallpaperPresentation(modeName: "locked", activityName: "active").mode == .locked)
        #expect(SystemWallpaperPresentation(modeName: "idle", activityName: "suspended") == .init(mode: .idle, activity: .suspended))
    }

    @Test func missingFieldsKeepThePreviousState() {
        let previous = SystemWallpaperPresentation(mode: .locked, activity: .suspended)
        let next = SystemWallpaperPresentation(modeName: nil, activityName: "active", default: previous)
        #expect(next == .init(mode: .locked, activity: .active))
    }

    @Test func unknownCasesStillPlay() {
        let future = SystemWallpaperPresentation(modeName: "ambient", activityName: "dozing")
        #expect(future.mode == .unknown)
        #expect(future.activity == .unknown)
        #expect(future.wantsPlayback)
    }

    @Test func onlySuspendedStopsPlayback() {
        #expect(SystemWallpaperPresentation(mode: .desktop, activity: .active).wantsPlayback)
        #expect(SystemWallpaperPresentation(mode: .locked, activity: .active).wantsPlayback)
        #expect(!SystemWallpaperPresentation(mode: .desktop, activity: .suspended).wantsPlayback)
        #expect(!SystemWallpaperPresentation(mode: .locked, activity: .suspended).wantsPlayback)
    }

    @Test func theLockScreenKeepsAMinimumDim() {
        let locked = SystemWallpaperPresentation(mode: .locked)
        #expect(locked.overlay(dim: 0, vignette: false).dim == SystemWallpaperPresentation.lockScreenMinimumDim)
        let lockedDim = locked.overlay(dim: 0.4, vignette: true)
        #expect(lockedDim.dim == 0.4 && lockedDim.vignette)
        // The desktop shows exactly the user's settings.
        let desktop = SystemWallpaperPresentation(mode: .desktop).overlay(dim: 0, vignette: false)
        #expect(desktop.dim == 0 && !desktop.vignette)
        let idle = SystemWallpaperPresentation(mode: .idle).overlay(dim: 0.2, vignette: true)
        #expect(idle.dim == 0.2 && idle.vignette)
    }
}

struct SystemWallpaperPlaybackTests {
    private typealias Demand = SystemWallpaperPlayback.Demand
    private let desktop = SystemWallpaperPresentation(mode: .desktop, activity: .active)
    private let hidden = SystemWallpaperPresentation(mode: .desktop, activity: .suspended)

    @Test func previewsNeverGetADecoder() {
        let demands = [Demand(isPreview: true, presentation: desktop), Demand(isPreview: true, presentation: desktop)]
        #expect(!SystemWallpaperPlayback.needsPlayer(demands))
        #expect(!SystemWallpaperPlayback.shouldPlay(demands))
    }

    @Test func pausesWhenEverySurfaceIsSuspended() {
        let demands = [Demand(isPreview: false, presentation: hidden), Demand(isPreview: false, presentation: hidden)]
        #expect(SystemWallpaperPlayback.needsPlayer(demands))
        #expect(!SystemWallpaperPlayback.shouldPlay(demands))
    }

    @Test func playsWhileAnyDisplayShowsIt() {
        let demands = [Demand(isPreview: false, presentation: hidden), Demand(isPreview: false, presentation: desktop)]
        #expect(SystemWallpaperPlayback.shouldPlay(demands))
    }

    @Test func nothingOnScreenNeedsNothing() {
        #expect(!SystemWallpaperPlayback.needsPlayer([]))
        #expect(!SystemWallpaperPlayback.shouldPlay([]))
    }
}

@MainActor
struct WallpaperExtensionExporterTests {
    @Test func exportsClipPosterAndManifest() async throws {
        let root = try makeTempDirectory()
        let video = try await makeTinyTestVideo(at: try makeTempDirectory().appending(path: "clip.mp4"))
        let exporter = WallpaperExtensionExporter(directory: root)
        exporter.refreshStatus()
        #expect(exporter.status == .notExported)

        let ok = await exporter.export(
            sourceURL: video, playbackURL: video, title: "Tiny",
            readability: ReadabilitySettings(dim: 0.25, blur: 4, vignette: true, speed: 0.8)
        )
        #expect(ok)
        #expect(exporter.lastError == nil)

        let store = SystemWallpaperStore(root: root)
        let manifest = try #require(store.readManifest())
        #expect(exporter.status == .exported(manifest))
        #expect(manifest.title == "Tiny")
        #expect(manifest.dim == 0.25)
        #expect(manifest.vignette)
        #expect(manifest.speed == 0.8)
        #expect(manifest.clipFileName.hasSuffix(".mp4"))
        let clip = store.clipURL(for: manifest)
        #expect(FileManager.default.contentsEqual(atPath: clip.path(percentEncoded: false), andPath: video.path(percentEncoded: false)))
        let poster = try #require(store.posterURL(for: manifest))
        #expect(FileManager.default.fileExists(atPath: poster.path(percentEncoded: false)))

        // A fresh exporter sees the same export.
        let other = WallpaperExtensionExporter(directory: root)
        other.refreshStatus()
        #expect(other.status == .exported(manifest))
    }

    @Test func reExportingTheSameClipReusesItAndANewOneReplacesIt() async throws {
        let root = try makeTempDirectory()
        let source = try makeTempDirectory()
        let first = try await makeTinyTestVideo(at: source.appending(path: "first.mov"))
        let second = try await makeTinyTestVideo(at: source.appending(path: "second.mp4"), frames: 5)
        let store = SystemWallpaperStore(root: root)
        let exporter = WallpaperExtensionExporter(directory: root) { _, destination in
            (try? Data([0xFF, 0xD8]).write(to: destination)) != nil
        }

        #expect(await exporter.export(sourceURL: first, playbackURL: first, title: "One", readability: ReadabilitySettings()))
        let one = try #require(store.readManifest())
        #expect(await exporter.export(sourceURL: first, playbackURL: first, title: "One", readability: ReadabilitySettings(dim: 0.1)))
        let again = try #require(store.readManifest())
        #expect(again.clipFileName == one.clipFileName)
        #expect(again.revision != one.revision)

        #expect(await exporter.export(sourceURL: second, playbackURL: second, title: "Two", readability: ReadabilitySettings()))
        let two = try #require(store.readManifest())
        #expect(two.clipFileName != one.clipFileName)
        let clips = try FileManager.default.contentsOfDirectory(atPath: store.clipsDirectory.path(percentEncoded: false))
        let posters = try FileManager.default.contentsOfDirectory(atPath: store.postersDirectory.path(percentEncoded: false))
        #expect(clips == [two.clipFileName])
        #expect(posters == [try #require(two.posterFileName)])
    }

    @Test func aFailedPosterStillExports() async throws {
        let root = try makeTempDirectory()
        let video = try await makeTinyTestVideo(at: try makeTempDirectory().appending(path: "clip.mov"))
        let exporter = WallpaperExtensionExporter(directory: root) { _, _ in false }
        #expect(await exporter.export(sourceURL: video, playbackURL: video, title: "x", readability: ReadabilitySettings()))
        let manifest = try #require(SystemWallpaperStore(root: root).readManifest())
        #expect(manifest.posterFileName == nil)
        #expect(manifest.clipFileName.hasSuffix(".mov"))
    }

    @Test func aRemoteWallpaperMustBeDownloadedFirst() async throws {
        let root = try makeTempDirectory()
        let remote = try #require(URL(string: "https://example.com/rain.mp4"))
        let exporter = WallpaperExtensionExporter(directory: root)
        let ok = await exporter.export(sourceURL: remote, playbackURL: remote, title: "Rain", readability: ReadabilitySettings())
        #expect(!ok)
        #expect(exporter.lastError == WallpaperExtensionExportError.notDownloaded.localizedDescription)
        #expect(SystemWallpaperStore(root: root).readManifest() == nil)
    }

    @Test func clipNamesFollowTheSourceAndFileIdentity() {
        let url = URL(filePath: "/tmp/a.mp4")
        let date = Date(timeIntervalSince1970: 1)
        let name = WallpaperExtensionExporter.clipBaseName(source: url, size: 10, modified: date)
        #expect(name.count == 24)
        #expect(name == WallpaperExtensionExporter.clipBaseName(source: url, size: 10, modified: date))
        #expect(name != WallpaperExtensionExporter.clipBaseName(source: url, size: 11, modified: date))
        #expect(WallpaperExtensionExporter.clipExtension(for: URL(filePath: "/x/y.MOV")) == "mov")
        #expect(WallpaperExtensionExporter.clipExtension(for: URL(filePath: "/x/y.webm")) == "mp4")
    }
}
