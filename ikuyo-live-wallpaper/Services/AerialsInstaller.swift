import CryptoKit
import Foundation

// Research prototype (Phase L1): puts a StarTorch clip into macOS's Aerials pipeline so the
// system's own wallpaper extension plays it on the lock screen. This relies on undocumented,
// per-user files that macOS owns; see docs/lockscreen-aerials.md for the evidence and the risks.
//
// Nothing here has a default location. Every path is injected, so tests only ever touch a
// temporary copy of a synthetic store, and the app has to opt in to the real one explicitly.

/// The per-user Aerials store: `~/Library/Application Support/com.apple.wallpaper/aerials`.
nonisolated struct AerialsStore: Sendable, Equatable {
    /// The `aerials` directory itself.
    let root: URL

    var manifestTar: URL { root.appending(path: "manifest.tar") }
    var manifestDirectory: URL { root.appending(path: "manifest", directoryHint: .isDirectory) }
    var entries: URL { manifestDirectory.appending(path: "entries.json") }
    var videos: URL { root.appending(path: "videos", directoryHint: .isDirectory) }
    var thumbnails: URL { root.appending(path: "thumbnails", directoryHint: .isDirectory) }

    /// The extension stores each asset's video as `videos/<asset id>.mov`.
    func video(for assetID: String) -> URL { videos.appending(path: "\(assetID).mov") }

    /// Asset and subcategory thumbnails are both `thumbnails/<id>.png`.
    func thumbnail(for id: String) -> URL { thumbnails.appending(path: "\(id).png") }

    /// Where the store lives for `home`. Only for callers that really mean the live store;
    /// nothing in this file falls back to it.
    static func live(home: URL) -> AerialsStore {
        AerialsStore(root: home.appending(path: "Library/Application Support/com.apple.wallpaper/aerials"))
    }
}

/// The asset, category and subcategory StarTorch adds to the manifest. The IDs are our own
/// UUIDs, never Apple's, so the entries can't collide with a real Aerial.
nonisolated struct AerialsCustomAsset: Codable, Equatable, Sendable {
    var assetID: String
    var categoryID: String
    var subcategoryID: String
    /// Shown in System Settings. The extension looks names up in Apple's string table and falls
    /// back to the key itself, so the key is the display name.
    var title: String
    var categoryTitle: String

    /// Fixed IDs shared with scripts/aerials-dev.sh, so re-applying keeps the user's selection.
    static let starTorch = AerialsCustomAsset(
        assetID: "5E64385F-BDBF-488A-9C03-CF8745BA45B4",
        categoryID: "35EB7A9E-3873-4E3F-9657-FC2E713D5B51",
        subcategoryID: "28A3A684-EAD9-456A-94B8-262CC0687481",
        title: "StarTorch",
        categoryTitle: "StarTorch"
    )
}

/// Why an applied install no longer matches what was written.
nonisolated enum AerialsDrift: String, Codable, Sendable, CaseIterable {
    /// `manifest.tar` changed (new ETag, size or date): the extension downloaded a new manifest
    /// and re-extracted `entries.json` over ours.
    case manifestRefreshed
    /// Our asset or category is gone from `entries.json`.
    case entriesMissing
    /// The video was removed, e.g. purged by CacheDelete under storage pressure.
    case videoMissing
    /// The video is there but isn't the file we placed (size differs).
    case videoChanged
    case thumbnailMissing
}

nonisolated enum AerialsInstallStatus: Equatable, Sendable {
    case notApplied
    case applied
    /// Applied once, but macOS has since changed something; `apply` again to fix it.
    case needsReapply([AerialsDrift])
}

nonisolated enum AerialsRevertOutcome: Equatable, Sendable {
    /// `entries.json` was put back byte for byte from the backup.
    case restoredOriginalManifest
    /// macOS had already replaced the manifest; our entries were removed from the new one.
    case removedEntriesFromRefreshedManifest
    /// macOS had already replaced the manifest and ours were gone; it was left untouched.
    case keptRefreshedManifest
}

nonisolated enum AerialsInstallerError: LocalizedError, Equatable {
    case storeNotFound(String)
    case unexpectedManifestSchema(String)
    case missingInput(String)
    case notApplied
    case backupMissing(String)

    var errorDescription: String? {
        switch self {
        case .storeNotFound(let path): "No Aerials manifest at \(path)."
        case .unexpectedManifestSchema(let detail): "The Aerials manifest doesn't look as expected: \(detail)"
        case .missingInput(let path): "Missing input file \(path)."
        case .notApplied: "Nothing to revert: no StarTorch Aerial is installed."
        case .backupMissing(let path): "The backup at \(path) is incomplete."
        }
    }
}

/// Size, modification date and the `LastETag` extended attribute the extension keeps on
/// `manifest.tar`. Any change means the manifest was downloaded again.
nonisolated struct AerialsFileFingerprint: Codable, Equatable, Sendable {
    var size: UInt64
    /// Whole seconds since 1970, so the value survives a JSON round trip unchanged.
    var modified: Int64
    var etag: String?

    init(size: UInt64, modified: Int64, etag: String?) {
        self.size = size
        self.modified = modified
        self.etag = etag
    }

    init?(of url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attributes[.size] as? UInt64,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        self.init(
            size: size,
            modified: Int64(modified.timeIntervalSince1970.rounded(.down)),
            etag: ExtendedAttributes.string(named: "LastETag", of: url)
        )
    }
}

/// Everything needed to undo an apply, saved next to the backups.
nonisolated struct AerialsInstallRecord: Codable, Equatable, Sendable {
    nonisolated struct TouchedFile: Codable, Equatable, Sendable {
        /// Relative to the store root.
        var path: String
        var existedBefore: Bool
        /// File name inside the backup folder, when `existedBefore`.
        var backupName: String?
    }

    var formatVersion = 1
    var appliedAt: Date
    var backupFolder: String
    var asset: AerialsCustomAsset
    var entriesSHA256Before: String
    var entriesSHA256After: String
    var manifestTar: AerialsFileFingerprint?
    var videoSize: UInt64
    var files: [TouchedFile]
}

/// Edits to `entries.json`, kept free of file I/O so they're easy to test.
nonisolated enum AerialsManifest {
    /// Keys every real asset carries (164 of 164 on macOS 27.0). `variant`, `videoGravity` and
    /// `group` only appear on some, so they're left out.
    static let requiredAssetKeys: Set<String> = [
        "accessibilityLabel", "categories", "id", "includeInShuffle", "localizedNameKey",
        "pointsOfInterest", "preferredOrder", "previewImage", "shotID", "showInTopLevel",
        "subcategories", "url-4K-SDR-240FPS",
    ]
    static let requiredCategoryKeys: Set<String> = [
        "id", "localizedDescriptionKey", "localizedNameKey", "preferredOrder", "previewImage",
        "representativeAssetID", "subcategories",
    ]
    static let requiredSubcategoryKeys: Set<String> = [
        "id", "localizedDescriptionKey", "localizedNameKey", "preferredOrder", "previewImage",
        "representativeAssetID",
    ]

    /// Matches the look of Apple's `entries.json` (pretty, sorted keys, " : ", escaped slashes).
    /// It isn't byte-identical: Foundation sorts numeric-looking keys (in `pointsOfInterest`)
    /// numerically where Apple's file sorts them as text. The content is the same, and `revert`
    /// restores the original bytes from the backup anyway.
    static let writingOptions: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]

    /// Returns `json` with `asset`'s asset and category (re)inserted. Existing entries with the
    /// same IDs are replaced, so applying twice doesn't duplicate anything.
    static func inserting(
        _ asset: AerialsCustomAsset,
        into json: Data,
        videoURL: URL,
        thumbnailURL: URL
    ) throws -> Data {
        var root = try decode(json)
        var assets = try array("assets", in: root)
        var categories = try array("categories", in: root)
        assets.removeAll { $0["id"] as? String == asset.assetID }
        categories.removeAll { $0["id"] as? String == asset.categoryID }

        let preview = thumbnailURL.absoluteString
        assets.append([
            "accessibilityLabel": asset.title,
            "categories": [asset.categoryID],
            "id": asset.assetID,
            "includeInShuffle": false,
            "localizedNameKey": asset.title,
            "pointsOfInterest": [String: Any](),
            "preferredOrder": 0,
            "previewImage": preview,
            "shotID": "STARTORCH_\(asset.assetID.prefix(8))",
            "showInTopLevel": true,
            "subcategories": [asset.subcategoryID],
            "url-4K-SDR-240FPS": videoURL.absoluteString,
        ])
        let nextOrder = (categories.compactMap { $0["preferredOrder"] as? Int }.max() ?? -1) + 1
        categories.append([
            "id": asset.categoryID,
            "localizedDescriptionKey": asset.categoryTitle,
            "localizedNameKey": asset.categoryTitle,
            "preferredOrder": nextOrder,
            "previewImage": preview,
            "representativeAssetID": asset.assetID,
            "subcategories": [[
                "id": asset.subcategoryID,
                "localizedDescriptionKey": asset.title,
                "localizedNameKey": asset.title,
                "preferredOrder": 0,
                "previewImage": preview,
                "representativeAssetID": asset.assetID,
            ] as [String: Any]],
        ])

        root["assets"] = assets
        root["categories"] = categories
        try validate(root)
        return try JSONSerialization.data(withJSONObject: root, options: writingOptions)
    }

    /// Returns `json` without `asset`'s asset and category.
    static func removing(_ asset: AerialsCustomAsset, from json: Data) throws -> Data {
        var root = try decode(json)
        root["assets"] = try array("assets", in: root).filter { $0["id"] as? String != asset.assetID }
        root["categories"] = try array("categories", in: root).filter { $0["id"] as? String != asset.categoryID }
        return try JSONSerialization.data(withJSONObject: root, options: writingOptions)
    }

    /// Whether both our asset and our category are in `json`.
    static func contains(_ asset: AerialsCustomAsset, in json: Data) -> Bool {
        guard let root = try? decode(json),
              let assets = try? array("assets", in: root),
              let categories = try? array("categories", in: root)
        else { return false }
        return assets.contains { $0["id"] as? String == asset.assetID }
            && categories.contains { $0["id"] as? String == asset.categoryID }
    }

    /// Checks that every asset, category and subcategory has the keys real ones have, and that
    /// every category an asset names exists. The extension decodes the whole manifest at once,
    /// so one bad entry would lose every Aerial, not just ours.
    static func validate(_ root: [String: Any]) throws {
        let assets = try array("assets", in: root)
        let categories = try array("categories", in: root)
        for asset in assets {
            let missing = requiredAssetKeys.subtracting(asset.keys)
            guard missing.isEmpty else {
                throw AerialsInstallerError.unexpectedManifestSchema("asset \(asset["id"] ?? "?") lacks \(missing.sorted())")
            }
        }
        var subcategoryIDs = Set<String>()
        for category in categories {
            let missing = requiredCategoryKeys.subtracting(category.keys)
            guard missing.isEmpty else {
                throw AerialsInstallerError.unexpectedManifestSchema("category \(category["id"] ?? "?") lacks \(missing.sorted())")
            }
            for sub in category["subcategories"] as? [[String: Any]] ?? [] {
                let missing = requiredSubcategoryKeys.subtracting(sub.keys)
                guard missing.isEmpty else {
                    throw AerialsInstallerError.unexpectedManifestSchema("subcategory \(sub["id"] ?? "?") lacks \(missing.sorted())")
                }
                if let id = sub["id"] as? String { subcategoryIDs.insert(id) }
            }
        }
        let categoryIDs = Set(categories.compactMap { $0["id"] as? String })
        for asset in assets {
            let named = Set(asset["categories"] as? [String] ?? [])
            guard named.isSubset(of: categoryIDs) else {
                throw AerialsInstallerError.unexpectedManifestSchema("asset \(asset["id"] ?? "?") names an unknown category")
            }
            let subs = Set(asset["subcategories"] as? [String] ?? [])
            guard subs.isSubset(of: subcategoryIDs) else {
                throw AerialsInstallerError.unexpectedManifestSchema("asset \(asset["id"] ?? "?") names an unknown subcategory")
            }
        }
    }

    private static func decode(_ json: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw AerialsInstallerError.unexpectedManifestSchema("the top level isn't an object")
        }
        return root
    }

    private static func array(_ key: String, in root: [String: Any]) throws -> [[String: Any]] {
        guard let value = root[key] as? [[String: Any]] else {
            throw AerialsInstallerError.unexpectedManifestSchema("no \"\(key)\" array")
        }
        return value
    }
}

/// Adds, checks and removes the StarTorch Aerial in an injected store, backing up every file it
/// touches first. Not thread-safe; callers run one operation at a time.
nonisolated struct AerialsInstaller: Sendable {
    let store: AerialsStore
    /// Where backups and the install record go. Owned by StarTorch, never inside the store.
    let backupRoot: URL

    init(store: AerialsStore, backupRoot: URL) {
        self.store = store
        self.backupRoot = backupRoot
    }

    var recordURL: URL { backupRoot.appending(path: "current-install.json") }

    func loadRecord() throws -> AerialsInstallRecord? {
        guard fileExists(recordURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AerialsInstallRecord.self, from: Data(contentsOf: recordURL))
    }

    /// Puts `video` and `thumbnail` (a PNG) in the store and adds `asset` to `entries.json`.
    /// If an install is already there it's reverted first, so this is also how to re-apply
    /// after macOS refreshes the manifest.
    @discardableResult
    func apply(
        _ asset: AerialsCustomAsset,
        video: URL,
        thumbnail: URL,
        now: Date = Date()
    ) throws -> AerialsInstallRecord {
        guard fileExists(store.entries) else { throw AerialsInstallerError.storeNotFound(store.entries.path) }
        for input in [video, thumbnail] where !fileExists(input) {
            throw AerialsInstallerError.missingInput(input.path)
        }
        if try loadRecord() != nil { try revert() }

        let original = try Data(contentsOf: store.entries)
        let videoTarget = store.video(for: asset.assetID)
        let assetThumb = store.thumbnail(for: asset.assetID)
        let subcategoryThumb = store.thumbnail(for: asset.subcategoryID)
        let updated = try AerialsManifest.inserting(asset, into: original, videoURL: videoTarget, thumbnailURL: assetThumb)

        // 1. Back up everything we're about to touch.
        let folderName = Self.backupFolderName(for: now)
        let backupFolder = backupRoot.appending(path: folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        var touched: [AerialsInstallRecord.TouchedFile] = []
        for (index, target) in [store.entries, videoTarget, assetThumb, subcategoryThumb].enumerated() {
            let relative = relativePath(of: target)
            if fileExists(target) {
                let name = "\(index)-\(target.lastPathComponent)"
                // copyItem keeps the bytes, dates and extended attributes (quarantine, ETag).
                try FileManager.default.copyItem(at: target, to: backupFolder.appending(path: name))
                touched.append(.init(path: relative, existedBefore: true, backupName: name))
            } else {
                touched.append(.init(path: relative, existedBefore: false, backupName: nil))
            }
        }

        let videoSize = try Self.size(of: video)
        let record = AerialsInstallRecord(
            appliedAt: now,
            backupFolder: folderName,
            asset: asset,
            entriesSHA256Before: Self.sha256(original),
            entriesSHA256After: Self.sha256(updated),
            manifestTar: AerialsFileFingerprint(of: store.manifestTar),
            videoSize: videoSize,
            files: touched
        )
        // The record is written before the store changes, so a failure half way can be reverted.
        try save(record)

        // 2. Media first, manifest last: the extension never sees an entry without its files.
        try FileManager.default.createDirectory(at: store.videos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.thumbnails, withIntermediateDirectories: true)
        try placeAtomically(video, at: videoTarget)
        // The extension tags downloads with their URL and re-downloads selected videos whose
        // manifest URL no longer matches, so ours carries the URL the manifest gives it.
        try ExtendedAttributes.setString(videoTarget.absoluteString, named: "SourceURL", of: videoTarget)
        try placeAtomically(thumbnail, at: assetThumb)
        try placeAtomically(thumbnail, at: subcategoryThumb)
        try updated.write(to: store.entries, options: .atomic)
        return record
    }

    /// Where the install stands against the files on disk now.
    func status() throws -> AerialsInstallStatus {
        guard let record = try loadRecord() else { return .notApplied }
        var drift: [AerialsDrift] = []
        if AerialsFileFingerprint(of: store.manifestTar) != record.manifestTar {
            drift.append(.manifestRefreshed)
        }
        let entries = (try? Data(contentsOf: store.entries)) ?? Data()
        if !AerialsManifest.contains(record.asset, in: entries) {
            drift.append(.entriesMissing)
        }
        let video = store.video(for: record.asset.assetID)
        if !fileExists(video) {
            drift.append(.videoMissing)
        } else if (try? Self.size(of: video)) != record.videoSize {
            drift.append(.videoChanged)
        }
        if !fileExists(store.thumbnail(for: record.asset.assetID))
            || !fileExists(store.thumbnail(for: record.asset.subcategoryID)) {
            drift.append(.thumbnailMissing)
        }
        return drift.isEmpty ? .applied : .needsReapply(drift)
    }

    /// Undoes the last `apply`: restores every file that existed before from its backup and
    /// removes every file that didn't. If macOS has already replaced `entries.json` with a newer
    /// manifest, that newer file is kept (minus our entries) rather than rolled back.
    @discardableResult
    func revert() throws -> AerialsRevertOutcome {
        guard let record = try loadRecord() else { throw AerialsInstallerError.notApplied }
        let backupFolder = backupRoot.appending(path: record.backupFolder, directoryHint: .isDirectory)
        var outcome = AerialsRevertOutcome.restoredOriginalManifest

        for file in record.files {
            let target = store.root.appending(path: file.path)
            if target == store.entries {
                outcome = try revertEntries(file, record: record, backupFolder: backupFolder)
            } else if file.existedBefore {
                try restore(file, to: target, from: backupFolder)
            } else if fileExists(target) {
                try FileManager.default.removeItem(at: target)
            }
        }
        try FileManager.default.removeItem(at: recordURL)
        return outcome
    }

    // MARK: - Helpers

    private func revertEntries(
        _ file: AerialsInstallRecord.TouchedFile,
        record: AerialsInstallRecord,
        backupFolder: URL
    ) throws -> AerialsRevertOutcome {
        let current = (try? Data(contentsOf: store.entries)) ?? Data()
        if Self.sha256(current) == record.entriesSHA256After || current.isEmpty {
            try restore(file, to: store.entries, from: backupFolder)
            return .restoredOriginalManifest
        }
        guard AerialsManifest.contains(record.asset, in: current) else { return .keptRefreshedManifest }
        try AerialsManifest.removing(record.asset, from: current).write(to: store.entries, options: .atomic)
        return .removedEntriesFromRefreshedManifest
    }

    private func restore(_ file: AerialsInstallRecord.TouchedFile, to target: URL, from folder: URL) throws {
        guard let name = file.backupName else { throw AerialsInstallerError.backupMissing(folder.path) }
        let backup = folder.appending(path: name)
        guard fileExists(backup) else { throw AerialsInstallerError.backupMissing(backup.path) }
        if fileExists(target) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: backup, to: target)
    }

    /// Copies to a temporary name in the destination folder, then renames over the target, so
    /// a reader never sees a half-written file and an open file handle keeps the old inode.
    private func placeAtomically(_ source: URL, at target: URL) throws {
        let temporary = target.deletingLastPathComponent()
            .appending(path: ".\(target.lastPathComponent).startorch-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: temporary)
        do {
            if fileExists(target) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func save(_ record: AerialsInstallRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        try encoder.encode(record).write(to: recordURL, options: .atomic)
    }

    private func relativePath(of url: URL) -> String {
        let rootPath = store.root.standardizedFileURL.path(percentEncoded: false)
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    static func size(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes[.size] as? UInt64 ?? 0
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func backupFolderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "backup-\(formatter.string(from: date))"
    }
}

/// Plain string extended attributes, stored as raw UTF-8 like the extension's `SourceURL` and
/// `LastETag`.
nonisolated enum ExtendedAttributes {
    static func string(named name: String, of url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let length = getxattr(path, name, nil, 0, 0, 0)
            guard length > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: length)
            let read = getxattr(path, name, &buffer, length, 0, 0)
            guard read == length else { return nil }
            return String(decoding: buffer, as: UTF8.self)
        }
    }

    static func setString(_ value: String, named name: String, of url: URL) throws {
        let bytes = Array(value.utf8)
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return setxattr(path, name, bytes, bytes.count, 0, 0)
        }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
