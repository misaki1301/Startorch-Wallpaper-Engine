import Foundation
import ObjectiveC
import os

// ╔══════════════════════════════════════════════════════════════════════════════════════════╗
// ║ PRIVATE / REVERSE-ENGINEERED (see the notice in WallpaperHostBridge.swift).               ║
// ║                                                                                            ║
// ║ WallpaperAgent asks the extension for its "settings view models": the group and choices   ║
// ║ System Settings › Wallpaper lists. The reply must be the private                          ║
// ║ `WallpaperSettingsViewModelsXPC`. The Codable types below mirror the private               ║
// ║ WallpaperTypes model's *key layout*; they are archived under a shim class name, then      ║
// ║ unarchived with that name remapped to the real class, so the real class decodes our keys. ║
// ║ A macOS update that renames a key makes the host reject or ignore the reply.              ║
// ║                                                                                            ║
// ║ Ported from the owner's prototype (WallpaperAppWallpaperExtension/SettingsModels.swift);   ║
// ║ changed: one fixed "StarTorch" choice instead of a folder scan, a video badge, Swift 6.   ║
// ╚══════════════════════════════════════════════════════════════════════════════════════════╝

private let payloadLog = Logger(subsystem: "com.shibuyaxpress.ikuyo-live-wallpaper.WallpaperExtension", category: "settings-payload")

nonisolated enum WallpaperSettingsPayload {
    /// The one choice StarTorch offers: "whatever the app exported last".
    static let choiceIdentifier = "startorch.current"
    static let groupIdentifier = "startorch"

    /// A `WallpaperSettingsViewModelsXPC` listing the StarTorch choice for the desktop (which is
    /// also what the lock screen shows). `thumbnailURL` is the exported poster, or nil for the
    /// bundled placeholder.
    static func makeViewModels(thumbnailURL: URL?) -> AnyObject? {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.shibuyaxpress.ikuyo-live-wallpaper.WallpaperExtension"
        let provider = ChoiceProviderID(rawValue: bundleID)
        let choiceID = ChoiceID(
            id: choiceIdentifier,
            descriptor: ChoiceIDDescriptor(
                provider: provider,
                identifier: choiceIdentifier,
                files: [],
                configuration: Data(choiceIdentifier.utf8)
            )
        )
        let placeholder = Bundle.main.url(forResource: "Thumbnail", withExtension: "png") ?? URL(filePath: "/")
        let thumbnail = Thumbnail.image(url: thumbnailURL ?? placeholder)
        let name = String(localized: "StarTorch")
        let item = SettingsItem(
            id: choiceID,
            localizedName: name,
            thumbnail: thumbnail,
            choice: ChoiceDescriptor(
                id: choiceID,
                provider: provider,
                identifier: choiceIdentifier,
                name: name,
                localizedDescription: String(localized: "The wallpaper exported from StarTorch"),
                thumbnail: thumbnail,
                isDownloaded: true,
                options: []
            ),
            contentBadge: .video,
            showInTopLevel: true,
            sortOrder: 0,
            // As in the prototype, whose payload the host is known to accept.
            disposability: .removable
        )
        let group = SettingsGroup(
            id: GroupID(id: groupIdentifier),
            items: [item],
            localizedName: name,
            disposability: .none,
            sortOrder: -100,
            sortID: GroupSortID(id: "com.apple.wallpaper.aerials"),
            allChoiceID: nil,
            shouldHideItemLabels: false,
            contextMenu: nil,
            thumbnail: nil
        )
        let models = SettingsViewModels(
            desktop: SettingsViewModel(groups: [group], refreshPolicy: .default, isModificationDisabled: false),
            screenSaver: nil
        )
        return remapToRealXPC(models)
    }

    /// Archives `models` through `ShimViewModelsXPC`, then unarchives it as the real class.
    ///
    /// Secure coding is off on purpose: the archive is produced and consumed inside this one
    /// function, so there is no untrusted input; the result goes straight back to WallpaperAgent.
    private static func remapToRealXPC(_ models: SettingsViewModels) -> AnyObject? {
        guard let realClass = objc_getClass("WallpaperSettingsViewModelsXPC") as? AnyClass else {
            payloadLog.error("WallpaperSettingsViewModelsXPC class not found")
            return nil
        }
        let data: Data
        do {
            data = try NSKeyedArchiver.archivedData(withRootObject: ShimViewModelsXPC(value: models), requiringSecureCoding: false)
        } catch {
            payloadLog.error("Archiving the settings view models failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        unarchiver.setClass(realClass, forClassName: "ShimViewModelsXPC")
        let result = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        if let error = unarchiver.error {
            payloadLog.error("Unarchiving as WallpaperSettingsViewModelsXPC failed: \(error.localizedDescription, privacy: .public)")
        }
        unarchiver.finishDecoding()
        return result as AnyObject?
    }
}

// MARK: - Codable mirror of the private WallpaperTypes model

nonisolated struct SettingsViewModels: Codable {
    var desktop: SettingsViewModel?
    var screenSaver: SettingsViewModel?
}

nonisolated struct SettingsViewModel: Codable {
    var groups: [SettingsGroup]
    var refreshPolicy: RefreshPolicy
    var isModificationDisabled: Bool
}

nonisolated struct SettingsGroup: Codable {
    var id: GroupID
    var items: [SettingsItem]
    var localizedName: String
    var disposability: Disposability
    var sortOrder: Int
    var sortID: GroupSortID?
    var allChoiceID: ChoiceID?
    var shouldHideItemLabels: Bool?
    var contextMenu: ContextMenu?
    var thumbnail: Data?
}

nonisolated struct GroupID: Codable { var id: String }
nonisolated struct GroupSortID: Codable { var id: String }

nonisolated struct ChoiceID: Codable {
    var id: String
    var descriptor: ChoiceIDDescriptor
}

/// `WallpaperChoiceID`'s nested descriptor: which provider, and what to hand it back on acquire.
nonisolated struct ChoiceIDDescriptor: Codable {
    var provider: ChoiceProviderID
    var identifier: String
    var files: [URL]
    var configuration: Data
}

nonisolated struct SettingsItem: Codable {
    var id: ChoiceID
    var localizedName: String
    var thumbnail: Thumbnail
    var choice: ChoiceDescriptor
    var contentBadge: ContentBadge
    var showInTopLevel: Bool
    var sortOrder: Int
    var disposability: Disposability
}

nonisolated struct ChoiceDescriptor: Codable {
    var id: ChoiceID
    var provider: ChoiceProviderID
    var identifier: String
    var name: String?
    var localizedDescription: String
    var thumbnail: Thumbnail
    var isDownloaded: Bool
    var options: [WallpaperOption]
}

/// Placeholder for `WallpaperOption`; StarTorch offers no options.
nonisolated struct WallpaperOption: Codable {}

nonisolated struct ContextMenu: Codable { var items: [ContextMenuItem] }
nonisolated struct ContextMenuItem: Codable {
    var identifier: String
    var name: String
}

/// Encodes as a bare string (single-value container), like the real provider ID.
nonisolated struct ChoiceProviderID: Codable {
    var rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated enum EmptyCodingKeys: CodingKey {}

/// Payload-less Swift enums encode as `{ "<case>": {} }`; this writes and reads that shape.
protocol CaseKeyedCodable: Codable, CaseIterable, RawRepresentable where RawValue == String {}

extension CaseKeyedCodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        self = Self.allCases.first { container.contains(AnyKey($0.rawValue)) } ?? Self.allCases.first!
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        _ = container.nestedContainer(keyedBy: EmptyCodingKeys.self, forKey: AnyKey(rawValue))
    }
}

nonisolated struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// `WallpaperTypes.WallpaperDisposability`.
nonisolated enum Disposability: String, CaseKeyedCodable {
    case none, removable, purgeable
}

/// `WallpaperSettingsItem.ContentBadge`.
nonisolated enum ContentBadge: String, CaseKeyedCodable {
    case none, video, dynamic
}

nonisolated enum RefreshPolicy: String, CaseKeyedCodable {
    case `default`
}

/// `WallpaperThumbnail`; only the `.image(url:)` case is used.
nonisolated enum Thumbnail: Codable {
    case image(url: URL)

    private enum CodingKeys: String, CodingKey { case image }
    private enum ImageCodingKeys: String, CodingKey { case url }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .image)
        self = .image(url: try nested.decode(URL.self, forKey: .url))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .image(let url):
            var nested = container.nestedContainer(keyedBy: ImageCodingKeys.self, forKey: .image)
            try nested.encode(url, forKey: .url)
        }
    }
}

/// An NSObject that encodes `SettingsViewModels` under the real XPC class's archive key.
@objc(ShimViewModelsXPC)
final class ShimViewModelsXPC: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    let value: SettingsViewModels

    init(value: SettingsViewModels) {
        self.value = value
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func encode(with coder: NSCoder) {
        guard let archiver = coder as? NSKeyedArchiver else { return }
        do {
            try archiver.encodeEncodable(value, forKey: "WallpaperSettingsViewModels")
        } catch {
            payloadLog.error("Encoding the settings view models failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
