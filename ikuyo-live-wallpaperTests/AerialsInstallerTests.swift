import Foundation
import Testing
@testable import StarTorch_Wallpaper_Engine

/// A minimal store with the same layout and schema as macOS 27's per-user Aerials store: two
/// made-up assets in one category, written the way Apple writes `entries.json`. None of it is
/// Apple's data.
private struct SyntheticAerialsStore {
    let store: AerialsStore
    let backups: URL
    let inputs: URL

    static let assetA = "00000000-0000-4000-8000-00000000000A"
    static let assetB = "00000000-0000-4000-8000-00000000000B"
    static let category = "00000000-0000-4000-8000-0000000000C1"
    static let subcategory = "00000000-0000-4000-8000-0000000000D1"

    static func make() throws -> SyntheticAerialsStore {
        let base = try makeTempDirectory()
        let store = AerialsStore(root: base.appending(path: "com.apple.wallpaper/aerials"))
        let fm = FileManager.default
        for dir in [store.manifestDirectory, store.videos, store.thumbnails] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data(manifestJSON().utf8).write(to: store.entries)
        try Data("tar bytes".utf8).write(to: store.manifestTar)
        try ExtendedAttributes.setString("\"ETAG-1\"", named: "LastETag", of: store.manifestTar)
        try Data("apple video A".utf8).write(to: store.video(for: assetA))
        try Data("apple thumb A".utf8).write(to: store.thumbnail(for: assetA))
        try Data("apple thumb B".utf8).write(to: store.thumbnail(for: assetB))
        try Data("apple thumb D1".utf8).write(to: store.thumbnail(for: subcategory))

        let inputs = base.appending(path: "inputs")
        try fm.createDirectory(at: inputs, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: inputs.appending(path: "clip.mov"))
        try Data("png bytes".utf8).write(to: inputs.appending(path: "thumb.png"))
        return SyntheticAerialsStore(store: store, backups: base.appending(path: "backups"), inputs: inputs)
    }

    var installer: AerialsInstaller { AerialsInstaller(store: store, backupRoot: backups) }
    var clip: URL { inputs.appending(path: "clip.mov") }
    var thumb: URL { inputs.appending(path: "thumb.png") }

    static func asset(_ id: String, order: Int) -> [String: Any] {
        [
            "accessibilityLabel": "Asset \(order)",
            "categories": [category],
            "id": id,
            "includeInShuffle": true,
            "localizedNameKey": "ASSET_\(order)_NAME",
            "pointsOfInterest": [String: Any](),
            "preferredOrder": order,
            "previewImage": "https://example.invalid/thumb-\(order).png",
            "shotID": "SHOT_\(order)",
            "showInTopLevel": true,
            "subcategories": [subcategory],
            "url-4K-SDR-240FPS": "https://example.invalid/video-\(order).mov",
            // A key only some real assets have; it must survive our edits.
            "group": "21J-1",
        ]
    }

    static func manifestJSON(extraAsset: Bool = false) -> String {
        var assets = [asset(assetA, order: 0), asset(assetB, order: 1)]
        if extraAsset { assets.append(asset("00000000-0000-4000-8000-00000000000E", order: 2)) }
        let root: [String: Any] = [
            "assets": assets,
            "categories": [[
                "id": category,
                "localizedDescriptionKey": "CategoryDescription",
                "localizedNameKey": "CategoryName",
                "preferredOrder": 0,
                "previewImage": "https://example.invalid/category.png",
                "representativeAssetID": assetA,
                "subcategories": [[
                    "id": subcategory,
                    "localizedDescriptionKey": "SubDescription",
                    "localizedNameKey": "SubName",
                    "preferredOrder": 0,
                    "previewImage": "https://example.invalid/sub.png",
                    "representativeAssetID": assetA,
                ]],
            ]],
            "initialAssetCount": 1,
            "localizationVersion": "TEST-1",
            "version": 1,
        ]
        let data = try! JSONSerialization.data(withJSONObject: root, options: AerialsManifest.writingOptions)
        return String(decoding: data, as: UTF8.self)
    }

    /// Every file under the store with its bytes, for before/after comparisons.
    func snapshot() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let rootPath = store.root.path(percentEncoded: false)
        let enumerator = FileManager.default.enumerator(atPath: rootPath)
        while let relative = enumerator?.nextObject() as? String {
            let url = store.root.appending(path: relative)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            if !isDirectory.boolValue { result[relative] = try Data(contentsOf: url) }
        }
        return result
    }

    func entries() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: store.entries)) as? [String: Any] ?? [:]
    }

    /// What the extension does when a new manifest arrives: new tar, re-extracted entries.json.
    func simulateManifestRefresh() throws {
        try Data("new tar bytes!".utf8).write(to: store.manifestTar)
        try ExtendedAttributes.setString("\"ETAG-2\"", named: "LastETag", of: store.manifestTar)
        try Data(Self.manifestJSON(extraAsset: true).utf8).write(to: store.entries)
    }
}

struct AerialsManifestTests {
    private let asset = AerialsCustomAsset.starTorch

    @Test func insertingAddsAValidAssetAndCategoryAndKeepsEverythingElse() throws {
        let original = Data(SyntheticAerialsStore.manifestJSON().utf8)
        let video = URL(filePath: "/tmp/aerials/videos/\(asset.assetID).mov")
        let thumb = URL(filePath: "/tmp/aerials/thumbnails/\(asset.assetID).png")

        let updated = try AerialsManifest.inserting(asset, into: original, videoURL: video, thumbnailURL: thumb)
        let root = try #require(try JSONSerialization.jsonObject(with: updated) as? [String: Any])
        try AerialsManifest.validate(root)

        let assets = try #require(root["assets"] as? [[String: Any]])
        let categories = try #require(root["categories"] as? [[String: Any]])
        #expect(assets.count == 3)
        #expect(categories.count == 2)
        #expect(root["localizationVersion"] as? String == "TEST-1")
        #expect(root["version"] as? Int == 1)
        #expect(assets[0]["group"] as? String == "21J-1")

        let ours = try #require(assets.first { $0["id"] as? String == asset.assetID })
        #expect(Set(ours.keys) == AerialsManifest.requiredAssetKeys)
        #expect(ours["url-4K-SDR-240FPS"] as? String == video.absoluteString)
        #expect(ours["previewImage"] as? String == thumb.absoluteString)
        #expect(ours["categories"] as? [String] == [asset.categoryID])
        #expect(ours["subcategories"] as? [String] == [asset.subcategoryID])

        let category = try #require(categories.first { $0["id"] as? String == asset.categoryID })
        #expect(category["preferredOrder"] as? Int == 1)
        #expect(category["representativeAssetID"] as? String == asset.assetID)
        #expect(AerialsManifest.contains(asset, in: updated))
    }

    @Test func insertingTwiceDoesNotDuplicate() throws {
        let original = Data(SyntheticAerialsStore.manifestJSON().utf8)
        let url = URL(filePath: "/tmp/x.mov")
        let once = try AerialsManifest.inserting(asset, into: original, videoURL: url, thumbnailURL: url)
        let twice = try AerialsManifest.inserting(asset, into: once, videoURL: url, thumbnailURL: url)
        #expect(once == twice)
    }

    @Test func removingRestoresTheOriginalBytes() throws {
        let original = Data(SyntheticAerialsStore.manifestJSON().utf8)
        let url = URL(filePath: "/tmp/x.mov")
        let updated = try AerialsManifest.inserting(asset, into: original, videoURL: url, thumbnailURL: url)
        #expect(try AerialsManifest.removing(asset, from: updated) == original)
    }

    @Test func editsKeepApplesFormatting() throws {
        // Apple's file is JSONSerialization's pretty, sorted output: " : " and escaped slashes.
        let original = Data(SyntheticAerialsStore.manifestJSON().utf8)
        let text = String(decoding: original, as: UTF8.self)
        #expect(text.contains("\"version\" : 1"))
        #expect(text.contains("https:\\/\\/example.invalid"))
    }

    @Test func unexpectedSchemaIsRejected() {
        let url = URL(filePath: "/tmp/x.mov")
        #expect(throws: AerialsInstallerError.self) {
            try AerialsManifest.inserting(self.asset, into: Data("{\"assets\": 3}".utf8), videoURL: url, thumbnailURL: url)
        }
        #expect(throws: AerialsInstallerError.self) {
            try AerialsManifest.validate(["assets": [["id": "x"]], "categories": []])
        }
    }
}

struct AerialsInstallerTests {
    private let asset = AerialsCustomAsset.starTorch

    @Test func statusIsNotAppliedOnAFreshStore() throws {
        let fixture = try SyntheticAerialsStore.make()
        #expect(try fixture.installer.status() == .notApplied)
    }

    @Test func applyPlacesMediaAddsEntriesAndBacksUpFirst() throws {
        let fixture = try SyntheticAerialsStore.make()
        let originalEntries = try Data(contentsOf: fixture.store.entries)

        let record = try fixture.installer.apply(asset, video: fixture.clip, thumbnail: fixture.thumb)

        let video = fixture.store.video(for: asset.assetID)
        #expect(try Data(contentsOf: video) == Data(contentsOf: fixture.clip))
        #expect(try Data(contentsOf: fixture.store.thumbnail(for: asset.assetID)) == Data(contentsOf: fixture.thumb))
        #expect(try Data(contentsOf: fixture.store.thumbnail(for: asset.subcategoryID)) == Data(contentsOf: fixture.thumb))
        #expect(ExtendedAttributes.string(named: "SourceURL", of: video) == video.absoluteString)

        let entries = try Data(contentsOf: fixture.store.entries)
        #expect(AerialsManifest.contains(asset, in: entries))
        #expect(record.entriesSHA256Before == AerialsInstaller.sha256(originalEntries))
        #expect(record.entriesSHA256After == AerialsInstaller.sha256(entries))
        #expect(record.manifestTar?.etag == "\"ETAG-1\"")

        // The backup holds the untouched manifest; files that didn't exist are only recorded.
        let backupFolder = fixture.backups.appending(path: record.backupFolder)
        let entriesBackup = try #require(record.files.first { $0.path == "manifest/entries.json" })
        #expect(entriesBackup.existedBefore)
        #expect(try Data(contentsOf: backupFolder.appending(path: try #require(entriesBackup.backupName))) == originalEntries)
        #expect(record.files.filter { !$0.existedBefore }.count == 3)
        #expect(try fixture.installer.status() == .applied)
    }

    @Test func revertRestoresTheStoreExactly() throws {
        let fixture = try SyntheticAerialsStore.make()
        let before = try fixture.snapshot()
        let entriesDate = try FileManager.default.attributesOfItem(
            atPath: fixture.store.entries.path(percentEncoded: false)
        )[.modificationDate] as? Date

        try fixture.installer.apply(asset, video: fixture.clip, thumbnail: fixture.thumb)
        #expect(try fixture.snapshot() != before)

        #expect(try fixture.installer.revert() == .restoredOriginalManifest)
        #expect(try fixture.snapshot() == before)
        let restoredDate = try FileManager.default.attributesOfItem(
            atPath: fixture.store.entries.path(percentEncoded: false)
        )[.modificationDate] as? Date
        #expect(restoredDate == entriesDate)
        #expect(try fixture.installer.status() == .notApplied)
    }

    @Test func applyOverAnExistingFileRestoresThatFileOnRevert() throws {
        let fixture = try SyntheticAerialsStore.make()
        // Something (an earlier experiment) already sits where our thumbnail goes.
        try Data("stale".utf8).write(to: fixture.store.thumbnail(for: asset.assetID))
        let before = try fixture.snapshot()

        try fixture.installer.apply(asset, video: fixture.clip, thumbnail: fixture.thumb)
        try fixture.installer.revert()

        #expect(try fixture.snapshot() == before)
    }

    @Test func manifestRefreshIsDetected() throws {
        let fixture = try SyntheticAerialsStore.make()
        try fixture.installer.apply(asset, video: fixture.clip, thumbnail: fixture.thumb)

        try fixture.simulateManifestRefresh()

        #expect(try fixture.installer.status() == .needsReapply([.manifestRefreshed, .entriesMissing]))
    }

    @Test func purgedVideoIsDetected() throws {
        let fixture = try SyntheticAerialsStore.make()
        try fixture.installer.apply(asset, video: fixture.clip, thumbnail: fixture.thumb)

        try FileManager.default.removeItem(at: fixture.store.video(for: asset.assetID))
        #expect(try fixture.installer.status() == .needsReapply([.videoMissing]))

        try Data("other".utf8).write(to: fixture.store.video(for: asset.assetID))
        #expect(try fixture.installer.status() == .needsReapply([.videoChanged]))
    }

    @Test func reapplyAfterRefreshKeepsApplesNewManifest() throws {
        let fixture = try SyntheticAerialsStore.make()
        try fixture.installer.apply(asset, video: fixture.clip, thumbnail: fixture.thumb)
        try fixture.simulateManifestRefresh()

        let record = try fixture.installer.apply(asset, video: fixture.clip, thumbnail: fixture.thumb)

        #expect(try fixture.installer.status() == .applied)
        #expect(record.manifestTar?.etag == "\"ETAG-2\"")
        let assets = try #require(try fixture.entries()["assets"] as? [[String: Any]])
        #expect(assets.count == 4) // Apple's three plus ours: the refresh wasn't rolled back.

        // And reverting now goes back to the refreshed manifest, not the first one.
        try fixture.installer.revert()
        #expect(try String(contentsOf: fixture.store.entries, encoding: .utf8)
            == SyntheticAerialsStore.manifestJSON(extraAsset: true))
    }

    @Test func revertAfterRefreshDoesNotRollBackTheNewManifest() throws {
        let fixture = try SyntheticAerialsStore.make()
        try fixture.installer.apply(asset, video: fixture.clip, thumbnail: fixture.thumb)
        try fixture.simulateManifestRefresh()
        let refreshed = try Data(contentsOf: fixture.store.entries)

        #expect(try fixture.installer.revert() == .keptRefreshedManifest)
        #expect(try Data(contentsOf: fixture.store.entries) == refreshed)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.video(for: asset.assetID).path(percentEncoded: false)))
    }

    @Test func revertRemovesOurEntriesIfTheManifestWasRewrittenWithThem() throws {
        let fixture = try SyntheticAerialsStore.make()
        try fixture.installer.apply(asset, video: fixture.clip, thumbnail: fixture.thumb)
        // Same content, different bytes (e.g. re-serialized by someone else).
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store.entries))
        try JSONSerialization.data(withJSONObject: object).write(to: fixture.store.entries)

        #expect(try fixture.installer.revert() == .removedEntriesFromRefreshedManifest)
        #expect(!AerialsManifest.contains(asset, in: try Data(contentsOf: fixture.store.entries)))
    }

    @Test func missingStoreOrInputsFailWithoutTouchingAnything() throws {
        let base = try makeTempDirectory()
        let empty = AerialsInstaller(
            store: AerialsStore(root: base.appending(path: "aerials")),
            backupRoot: base.appending(path: "backups")
        )
        let fixture = try SyntheticAerialsStore.make()
        #expect(throws: AerialsInstallerError.self) {
            try empty.apply(self.asset, video: fixture.clip, thumbnail: fixture.thumb)
        }
        #expect(!FileManager.default.fileExists(atPath: base.appending(path: "backups").path(percentEncoded: false)))

        let before = try fixture.snapshot()
        #expect(throws: AerialsInstallerError.self) {
            try fixture.installer.apply(self.asset, video: fixture.inputs.appending(path: "nope.mov"), thumbnail: fixture.thumb)
        }
        #expect(try fixture.snapshot() == before)
        #expect(throws: AerialsInstallerError.notApplied) { try fixture.installer.revert() }
    }

    @Test func testsNeverPointAtTheLiveStore() throws {
        let fixture = try SyntheticAerialsStore.make()
        let live = AerialsStore.live(home: FileManager.default.homeDirectoryForCurrentUser)
        #expect(fixture.store.root != live.root)
        #expect(fixture.store.root.path(percentEncoded: false)
            .hasPrefix(FileManager.default.temporaryDirectory.path(percentEncoded: false)))
    }
}
