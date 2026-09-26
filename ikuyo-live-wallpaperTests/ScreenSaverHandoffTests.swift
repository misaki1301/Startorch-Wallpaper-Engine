import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

/// The parts of `StarTorchShared` both the app and StarTorch.saver compile: manifest format,
/// handoff paths and what the saver shows.
struct ScreenSaverManifestTests {
    let manifest = ScreenSaverManifest(
        videoFileName: "clip-abc.mp4",
        posterFileName: "poster-abc.jpg",
        dim: 0.3,
        vignette: true,
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        source: "file:///tmp/rain.mp4",
        sourceFingerprint: "123-456"
    )

    @Test func roundTripsThroughJSON() throws {
        let decoded = try ScreenSaverManifest.decode(manifest.encoded())
        #expect(decoded == manifest)
        #expect(decoded.version == ScreenSaverManifest.currentVersion)
    }

    @Test func encodesReadableKeys() throws {
        let json = try #require(String(data: manifest.encoded(), encoding: .utf8))
        for key in ["\"version\"", "\"videoFileName\"", "\"posterFileName\"", "\"dim\"", "\"vignette\"", "\"updatedAt\""] {
            #expect(json.contains(key))
        }
        #expect(json.contains("2027-01-15T08:00:00Z"))
    }

    @Test func rejectsNewerVersions() throws {
        let json = #"{"version": 2, "videoFileName": "clip.mp4", "dim": 0, "vignette": false}"#
        #expect(throws: ScreenSaverManifestError.unsupportedVersion(2)) {
            try ScreenSaverManifest.decode(Data(json.utf8))
        }
    }

    @Test func requiresAVersion() {
        #expect(throws: DecodingError.self) {
            try ScreenSaverManifest.decode(Data(#"{"videoFileName": "clip.mp4"}"#.utf8))
        }
    }

    @Test func missingOptionalFieldsFallBackToDefaults() throws {
        let decoded = try ScreenSaverManifest.decode(Data(#"{"version": 1, "futureKey": [1, 2]}"#.utf8))
        #expect(decoded.videoFileName == nil)
        #expect(decoded.posterFileName == nil)
        #expect(decoded.dim == 0)
        #expect(decoded.vignette == false)
        #expect(decoded.updatedAt == .distantPast)
    }

    @Test(arguments: ["../clip.mp4", "sub/clip.mp4", ".hidden.mp4", ""])
    func rejectsFileNamesOutsideTheFolder(_ name: String) {
        let json = #"{"version": 1, "videoFileName": "\#(name)"}"#
        #expect(throws: ScreenSaverManifestError.unsafeFileName(name)) {
            try ScreenSaverManifest.decode(Data(json.utf8))
        }
    }

    @Test func clampsDim() {
        #expect(ScreenSaverManifest(videoFileName: nil, posterFileName: nil, dim: 5, vignette: false, updatedAt: .now).dim == 0.6)
        #expect(ScreenSaverManifest(videoFileName: nil, posterFileName: nil, dim: -1, vignette: false, updatedAt: .now).dim == 0)
    }

    @Test func vignetteMatchesTheDesktop() {
        #expect(ScreenSaverManifest.vignetteOpacity == ReadabilitySettings.vignetteOpacity)
        #expect(ScreenSaverManifest.vignetteInnerRadius == ReadabilitySettings.vignetteInnerRadius)
        #expect(ReadabilitySettings.dimRange == 0...0.6)
    }

    @Test func readReturnsNilForMissingOrBrokenFiles() throws {
        let dir = try makeTempDirectory()
        #expect(ScreenSaverManifest.read(in: dir) == nil)
        try Data("not json".utf8).write(to: dir.appending(path: ScreenSaverManifest.fileName))
        #expect(ScreenSaverManifest.read(in: dir) == nil)
        try manifest.encoded().write(to: dir.appending(path: ScreenSaverManifest.fileName))
        #expect(ScreenSaverManifest.read(in: dir) == manifest)
    }
}

struct ScreenSaverHandoffPathTests {
    @Test func handoffFolderIsInsideTheHostContainer() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        let dir = ScreenSaverHandoff.directory(inHome: home)
        #expect(dir.path(percentEncoded: false) ==
            "/Users/someone/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/StarTorch/")
    }

    static let entitlements = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "ikuyo-live-wallpaper/ikuyo-live-wallpaper.entitlements")

    /// The app may only write where its temporary-exception entitlement allows. Skipped when the
    /// test host is sandboxed and can't read the source tree.
    @Test(.enabled(if: FileManager.default.isReadableFile(atPath: entitlements.path(percentEncoded: false))))
    func entitlementNamesTheHandoffFolder() throws {
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: Self.entitlements), format: nil)
        let dict = try #require(plist as? [String: Any])
        let paths = try #require(dict["com.apple.security.temporary-exception.files.home-relative-path.read-write"] as? [String])
        #expect(paths == ["/\(ScreenSaverHandoff.homeRelativePath)/"])
        #expect(dict["com.apple.security.network.client"] as? Bool == true)
    }

    @Test func realHomeIsNotTheSandboxContainer() {
        let home = ScreenSaverHandoff.realHomeDirectory.path(percentEncoded: false)
        #expect(!home.contains("/Library/Containers/"))
    }

    @Test func saverLooksInItsOwnContainerFirst() {
        let appSupport = URL(filePath: "/Users/someone/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support")
        let home = URL(filePath: "/Users/someone")
        let candidates = ScreenSaverHandoff.saverCandidateDirectories(applicationSupport: appSupport, realHome: home)
        // Sandboxed, both spellings are the same folder.
        #expect(candidates.count == 1)
        #expect(candidates.first?.lastPathComponent == "StarTorch")

        let unsandboxed = ScreenSaverHandoff.saverCandidateDirectories(
            applicationSupport: URL(filePath: "/Users/someone/Library/Application Support"),
            realHome: home
        )
        #expect(unsandboxed.map { $0.path(percentEncoded: false) } == [
            "/Users/someone/Library/Application Support/StarTorch/",
            ScreenSaverHandoff.directory(inHome: home).path(percentEncoded: false),
        ])
    }
}

struct ScreenSaverContentTests {
    let dir = URL(filePath: "/handoff", directoryHint: .isDirectory)
    let manifest = ScreenSaverManifest(
        videoFileName: "clip-1.mp4", posterFileName: "poster-1.jpg", dim: 0, vignette: false,
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    var video: URL { dir.appending(path: "clip-1.mp4") }
    var poster: URL { dir.appending(path: "poster-1.jpg") }

    @Test func playsTheClipWithItsPoster() {
        let content = ScreenSaverContent.resolve(manifest: manifest, in: dir, isPreview: false) { _ in true }
        #expect(content == .video(video, poster: poster))
    }

    @Test func missingClipFallsBackToThePoster() {
        let content = ScreenSaverContent.resolve(manifest: manifest, in: dir, isPreview: false) { $0 == poster }
        #expect(content == .poster(poster))
    }

    @Test func clipWithoutPoster() {
        let content = ScreenSaverContent.resolve(manifest: manifest, in: dir, isPreview: false) { $0 == video }
        #expect(content == .video(video, poster: nil))
    }

    @Test func nothingOnDiskFallsBackToTheGradient() {
        #expect(ScreenSaverContent.resolve(manifest: manifest, in: dir, isPreview: false) { _ in false } == .gradient)
        #expect(ScreenSaverContent.resolve(manifest: nil, in: dir, isPreview: false) { _ in true } == .gradient)
    }

    @Test func previewsShowTheStillOnly() {
        #expect(ScreenSaverContent.resolve(manifest: manifest, in: dir, isPreview: true) { _ in true } == .poster(poster))
        #expect(ScreenSaverContent.resolve(manifest: manifest, in: dir, isPreview: true) { $0 == video } == .gradient)
    }

    @Test func loadsTheFirstFolderWithAManifest() throws {
        let empty = try makeTempDirectory()
        let full = try makeTempDirectory()
        try manifest.encoded().write(to: full.appending(path: ScreenSaverManifest.fileName))
        try Data().write(to: full.appending(path: "clip-1.mp4"))

        let (content, loaded) = ScreenSaverContent.load(from: [empty, full], isPreview: false)
        #expect(loaded == manifest)
        #expect(content == .video(full.appending(path: "clip-1.mp4"), poster: nil))

        let none = ScreenSaverContent.load(from: [empty], isPreview: false)
        #expect(none.content == .gradient)
        #expect(none.manifest == nil)
    }
}
