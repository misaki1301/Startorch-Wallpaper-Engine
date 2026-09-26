import ExtensionFoundation
import Foundation
import IOSurface
import ObjectiveC
import QuartzCore
import os

// ╔══════════════════════════════════════════════════════════════════════════════════════════╗
// ║ PRIVATE / REVERSE-ENGINEERED SURFACE — together with WallpaperSettingsPayload.swift and  ║
// ║ WallpaperPrivateAPI.h, this is the ONLY code in StarTorch that touches private API.       ║
// ║                                                                                            ║
// ║ What is private here, and how it was learned:                                             ║
// ║  1. The `com.apple.wallpaper` ExtensionKit point itself. Its .appexpt declares            ║
// ║     EXRequiredEntitlements `com.apple.private.wallpaper.extension`; on macOS 27.0 (26A428)║
// ║     that is not enforced for the extension (see docs/wallpaper-extension.md).              ║
// ║  2. WallpaperExtensionKit.framework (dlopen'ed, never linked) and its XPC protocols       ║
// ║     (declared in WallpaperPrivateAPI.h; selectors verified against the runtime).          ║
// ║  3. Its XPC payload classes (WallpaperRemoteContextXPC, WallpaperSnapshotXPC,             ║
// ║     WallpaperCreationRequestXPC, …). Replies are built by writing into their ivars at     ║
// ║     runtime (layouts checked at startup); requests are read by Mirror-walking them.       ║
// ║  4. QuartzCore's private CAContext (a remote layer context WallpaperAgent composites).    ║
// ║                                                                                            ║
// ║ Everything outside these files is public API: the renderer only sees the plain            ║
// ║ `HostSurfaceRequest` / `HostSurfaceUpdate` values and the `RemoteLayerHosting` protocol.  ║
// ║                                                                                            ║
// ║ Ported from the owner's prototype (wallpapermoduleweb/WallpaperApp,                       ║
// ║ WallpaperAppWallpaperExtension: WallpaperWallpaperExtension.swift,                        ║
// ║ WallpaperExtensionConfig.swift, WallpaperXPCHandler.swift, RuntimeHelpers.swift), adapted ║
// ║ for Swift 6 strict concurrency, the video renderer and presentation-mode decoding.       ║
// ╚══════════════════════════════════════════════════════════════════════════════════════════╝

private let bridgeLog = Logger(subsystem: "com.shibuyaxpress.ikuyo-live-wallpaper.WallpaperExtension", category: "host-bridge")

// MARK: - Private framework loading

nonisolated enum WallpaperPrivateRuntime {
    static let frameworkPath = "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"

    /// The payload classes the extension builds or accepts. Missing ones mean an unsupported macOS.
    static let criticalClasses = [
        "WallpaperRemoteContextXPC",
        "WallpaperSnapshotXPC",
        "WallpaperCreationRequestXPC",
        "WallpaperSettingsViewModelsXPC",
        "WallpaperIDXPC",
    ]

    /// Loads WallpaperExtensionKit into the process so its XPC classes exist for NSXPC decoding.
    /// The handle is deliberately never closed: the runtime-built objects point into it.
    static func load() -> Bool {
        guard dlopen(frameworkPath, RTLD_LAZY) != nil else {
            bridgeLog.error("dlopen WallpaperExtensionKit failed: \(String(cString: dlerror()), privacy: .public)")
            return false
        }
        let missing = criticalClasses.filter { objc_getClass($0) == nil }
        if missing.isEmpty {
            bridgeLog.info("WallpaperExtensionKit loaded; all \(criticalClasses.count) critical classes present")
        } else {
            bridgeLog.error("UNSUPPORTED RUNTIME, missing: \(missing.joined(separator: ", "), privacy: .public)")
        }
        return missing.isEmpty
    }
}

// MARK: - Remote layer context (private CAContext)

/// A `CAContext` created with `+remoteContextWithOptions:`; WallpaperAgent draws its layer.
final class PrivateRemoteContext: RemoteLayerHosting {
    private let context: CAContext

    private init(context: CAContext) {
        self.context = context
    }

    static func make(displayID: UInt32?) -> PrivateRemoteContext? {
        var options: [String: Any] = [:]
        if let displayID { options["displayId"] = displayID }
        let made: Any? = options.isEmpty ? CAContext.makeRemoteContext() : CAContext.makeRemoteContext(options: options)
        guard let context = made as? CAContext, context.contextId != 0 else {
            bridgeLog.error("Could not create a remote CAContext")
            return nil
        }
        return PrivateRemoteContext(context: context)
    }

    var contextID: UInt32 { context.contextId }

    var hostedLayer: CALayer? {
        get { context.layer }
        set { context.layer = newValue }
    }
}

// MARK: - Building the private reply objects

nonisolated enum PrivateXPCObjects {
    /// A `WallpaperRemoteContextXPC` wrapping `contextID`: its `box` ivar holds a
    /// `WallpaperExtensionRemoteContext`, a single UInt32 (offset 8, instance size 16 on 26A428).
    static func remoteContext(contextID: UInt32) -> AnyObject? {
        guard let realClass = objc_getClass("WallpaperRemoteContextXPC") as? AnyClass,
              let instance = class_createInstance(realClass, 0) else {
            bridgeLog.error("Could not create WallpaperRemoteContextXPC")
            return nil
        }
        let offset = class_getInstanceVariable(realClass, "box").map(ivar_getOffset) ?? 8
        guard offset >= 8, offset + MemoryLayout<UInt32>.size <= class_getInstanceSize(realClass) else {
            bridgeLog.error("WallpaperRemoteContextXPC layout unexpected (offset \(offset), size \(class_getInstanceSize(realClass)))")
            return nil
        }
        let object = instance as AnyObject
        Unmanaged.passUnretained(object).toOpaque().advanced(by: offset).storeBytes(of: contextID, as: UInt32.self)
        return object
    }

    /// A `WallpaperSnapshotXPC` wrapping `surface`: its `rawValue` ivar holds a `WallpaperSnapshot`
    /// struct whose only field is the (retained) IOSurface.
    static func snapshot(surface: IOSurface) -> AnyObject? {
        guard let realClass = objc_getClass("WallpaperSnapshotXPC") as? AnyClass,
              let instance = class_createInstance(realClass, 0) else {
            bridgeLog.error("Could not create WallpaperSnapshotXPC")
            return nil
        }
        let offset = class_getInstanceVariable(realClass, "rawValue").map(ivar_getOffset) ?? 8
        guard offset >= 8, offset + MemoryLayout<UnsafeRawPointer>.size <= class_getInstanceSize(realClass) else {
            bridgeLog.error("WallpaperSnapshotXPC layout unexpected (size \(class_getInstanceSize(realClass)))")
            return nil
        }
        let object = instance as AnyObject
        // The object's ivar destroyer releases this reference when WallpaperAgent is done with it.
        let surfaceRef = Unmanaged.passRetained(surface).toOpaque()
        Unmanaged.passUnretained(object).toOpaque().advanced(by: offset).storeBytes(of: surfaceRef, as: UnsafeRawPointer.self)
        return object
    }

    /// Copies `image` into a BGRA IOSurface, the pixel format WallpaperAgent's snapshots use.
    static func snapshot(image: CGImage) -> AnyObject? {
        let properties: [IOSurfacePropertyKey: any Sendable] = [
            .width: image.width,
            .height: image.height,
            .bytesPerElement: 4,
            .pixelFormat: 0x4247_5241, // 'BGRA'
        ]
        guard image.width > 0, image.height > 0, let surface = IOSurface(properties: properties) else { return nil }
        surface.lock(options: [], seed: nil)
        if let context = CGContext(
            data: surface.baseAddress,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: surface.bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        surface.unlock(options: [], seed: nil)
        return snapshot(surface: surface)
    }
}

// MARK: - Reading the private request objects

nonisolated enum HostRequestDecoder {
    /// Recursively finds a stored property named `label` (bounded depth; robust to XPC boxes).
    static func findProperty(_ label: String, in value: Any, depth: Int = 0) -> Any? {
        guard depth < 8 else { return nil }
        for child in Mirror(reflecting: value).children {
            if child.label == label { return child.value }
            if let found = findProperty(label, in: child.value, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The first UUID in an object graph (WallpaperIDXPC → box → WallpaperID → uuid).
    static func findUUID(in value: Any?, depth: Int = 0) -> UUID? {
        guard depth < 8, let value else { return nil }
        if let uuid = value as? UUID { return uuid }
        if let uuid = value as? NSUUID { return uuid as UUID }
        if let string = value as? String, let uuid = UUID(uuidString: string) { return uuid }
        for child in Mirror(reflecting: value).children {
            if let found = findUUID(in: child.value, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The case name of a host enum. `WallpaperPresentationMode` and `WallpaperActivityState` are
    /// payload-less, so their description is the case name (`default`, `locked`, `suspended`…).
    static func caseName(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .enum, let label = mirror.children.first?.label { return label }
        return String(describing: value)
    }

    static func surfaceKey(fromID id: Any?, displayID: UInt32? = nil) -> String {
        findUUID(in: id)?.uuidString ?? "display-\(displayID ?? 0)"
    }

    static func creationRequest(id: Any?, request: Any?) -> HostSurfaceRequest {
        var size = CGSize(width: 2560, height: 1440)
        var scale: CGFloat = 2
        var isPreview = false
        var displayID: UInt32?
        var modeName: String?
        var activityName: String?

        if let request {
            if let destination = findProperty("destination", in: request) {
                if let value = findProperty("size", in: destination) as? CGSize { size = value }
                if let value = findProperty("scaleFactor", in: destination) as? CGFloat { scale = value }
                if let value = findProperty("directDisplayID", in: destination) as? UInt32 { displayID = value }
            }
            if let value = findProperty("isPreview", in: request) as? Bool { isPreview = value }
            modeName = findProperty("presentationMode", in: request).map(caseName)
            activityName = findProperty("activityState", in: request).map(caseName)
        }
        let decoded = HostSurfaceRequest(
            key: surfaceKey(fromID: id, displayID: displayID),
            size: size,
            scale: scale,
            isPreview: isPreview,
            displayID: displayID,
            presentation: SystemWallpaperPresentation(modeName: modeName, activityName: activityName)
        )
        bridgeLog.debug("acquire request \(decoded.key, privacy: .public): \(Int(size.width))x\(Int(size.height)) @\(scale)x preview=\(isPreview) mode=\(modeName ?? "?", privacy: .public) activity=\(activityName ?? "?", privacy: .public)")
        return decoded
    }

    static func updateRequest(id: Any?, request: Any?) -> HostSurfaceUpdate {
        var modeName: String?
        var activityName: String?
        var size: CGSize?
        var scale: CGFloat?
        if let request {
            modeName = findProperty("presentationMode", in: request).map(caseName)
            activityName = findProperty("activityState", in: request).map(caseName)
            if let destination = findProperty("destination", in: request) {
                size = findProperty("size", in: destination) as? CGSize
                scale = findProperty("scaleFactor", in: destination) as? CGFloat
            }
        }
        return HostSurfaceUpdate(key: surfaceKey(fromID: id), modeName: modeName, activityName: activityName, size: size, scale: scale)
    }
}

// MARK: - Accepting WallpaperAgent's connection

struct WallpaperHostConfiguration: AppExtensionConfiguration {
    nonisolated func accept(connection: NSXPCConnection) -> Bool {
        bridgeLog.info("XPC connection from pid \(connection.processIdentifier)")

        let exported = NSXPCInterface(with: (any WallpaperExtensionXPCProtocol).self)
        let typeNames = [
            "WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperUpdateRequestXPC",
            "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperContentTypeSetXPC",
            "WallpaperChoiceIDXPC", "WallpaperChoiceIDsXPC", "WallpaperExtensionChoiceRequestXPC",
            "WallpaperChoiceRequestAdditionResultXPC", "WallpaperDebugRequestXPC", "WallpaperDebugResponseXPC",
            "WallpaperMigrationVersionXPC", "WallpaperSettingsViewModelsXPC", "AuditTokenXPC",
        ]
        let allowed = NSMutableSet()
        var missing: [String] = []
        for name in typeNames {
            if let cls = objc_getClass(name) { allowed.add(cls) } else { missing.append(name) }
        }
        if !missing.isEmpty {
            bridgeLog.error("Missing runtime types: \(missing.joined(separator: ", "), privacy: .public)")
        }
        for cls: AnyClass in [NSString.self, NSNumber.self, NSData.self, NSArray.self, NSDictionary.self, NSURL.self, NSError.self] {
            allowed.add(cls)
        }
        guard let classes = allowed as? Set<AnyHashable> else { return false }

        // (selector, argument index, of reply) — every object-typed slot the host may send or expect.
        let slots: [(Selector, Int, Bool)] = [
            (#selector(WallpaperHostHandler.acquire(withId:request:reply:)), 0, false),
            (#selector(WallpaperHostHandler.acquire(withId:request:reply:)), 1, false),
            (#selector(WallpaperHostHandler.acquire(withId:request:reply:)), 0, true),
            (#selector(WallpaperHostHandler.update(withId:request:reply:)), 0, false),
            (#selector(WallpaperHostHandler.update(withId:request:reply:)), 1, false),
            (#selector(WallpaperHostHandler.invalidate(withId:reply:)), 0, false),
            (#selector(WallpaperHostHandler.snapshot(withId:reply:)), 0, false),
            (#selector(WallpaperHostHandler.snapshot(withId:reply:)), 0, true),
            (#selector(WallpaperHostHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, false),
            (#selector(WallpaperHostHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, true),
            (#selector(WallpaperHostHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, false),
            (#selector(WallpaperHostHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 1, false),
            (#selector(WallpaperHostHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, true),
            (#selector(WallpaperHostHandler.removeChoiceRequest(withChoiceRequest:reply:)), 0, false),
            (#selector(WallpaperHostHandler.selectedChoicesDidChange(for:reply:)), 0, false),
            (#selector(WallpaperHostHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 0, false),
            (#selector(WallpaperHostHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 1, false),
            (#selector(WallpaperHostHandler.isChoiceDownloaded(with:reply:)), 0, false),
            (#selector(WallpaperHostHandler.download(withChoiceID:reply:)), 0, false),
            (#selector(WallpaperHostHandler.pauseDownload(for:reply:)), 0, false),
            (#selector(WallpaperHostHandler.cancelDownload(for:reply:)), 0, false),
            (#selector(WallpaperHostHandler.resumeDownload(for:reply:)), 0, false),
            (#selector(WallpaperHostHandler.removeDownload(for:reply:)), 0, false),
            (#selector(WallpaperHostHandler.migrateSelectedChoice(for:reply:)), 0, false),
            (#selector(WallpaperHostHandler.migrateSelectedChoice(for:reply:)), 0, true),
            (#selector(WallpaperHostHandler.migrate(from:to:reply:)), 0, false),
            (#selector(WallpaperHostHandler.migrate(from:to:reply:)), 1, false),
            (#selector(WallpaperHostHandler.skipShuffledContent(withId:reply:)), 0, false),
            (#selector(WallpaperHostHandler.canSkipShuffledContent(withId:reply:)), 0, false),
            (#selector(WallpaperHostHandler.handleDebugRequest(for:reply:)), 0, false),
            (#selector(WallpaperHostHandler.handleDebugRequest(for:reply:)), 0, true),
            (#selector(WallpaperHostHandler.handleNotification(withNamed:reply:)), 0, false),
        ]
        for (selector, index, ofReply) in slots {
            exported.setClasses(classes, for: selector, argumentIndex: index, ofReply: ofReply)
        }

        connection.exportedInterface = exported
        connection.remoteObjectInterface = NSXPCInterface(with: (any WallpaperExtensionProxyXPCProtocol).self)
        let handler = WallpaperHostHandler(pid: connection.processIdentifier)
        connection.exportedObject = handler
        let agent = AgentProxy(proxy: connection.remoteObjectProxy as? any WallpaperExtensionProxyXPCProtocol)
        let token = ObjectIdentifier(handler)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { HostAgents.shared.add(agent.proxy, for: token) }
        }
        connection.interruptionHandler = { bridgeLog.debug("XPC interrupted") }
        connection.invalidationHandler = {
            bridgeLog.debug("XPC invalidated")
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HostAgents.shared.remove(token) }
            }
        }
        connection.resume()
        return true
    }
}

/// An NSXPC proxy is safe to message from any thread; this only carries it to the main actor.
private struct AgentProxy: @unchecked Sendable {
    let proxy: (any WallpaperExtensionProxyXPCProtocol)?
}

/// The WallpaperAgent proxies of the open connections, so a new export can ask the host to
/// refresh its snapshots (System Settings' thumbnails).
@MainActor
final class HostAgents {
    static let shared = HostAgents()
    private var agents: [ObjectIdentifier: any WallpaperExtensionProxyXPCProtocol] = [:]

    func add(_ agent: (any WallpaperExtensionProxyXPCProtocol)?, for token: ObjectIdentifier) {
        agents[token] = agent
    }

    func remove(_ token: ObjectIdentifier) {
        agents[token] = nil
    }

    func invalidateSnapshots() {
        for agent in agents.values {
            agent.invalidateSnapshots { error in
                if let error { bridgeLog.error("invalidateSnapshots: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }
}

// MARK: - WallpaperAgent → extension calls

/// Implements the private `WallpaperExtensionXPCProtocol`. Requests are decoded into plain values
/// on the XPC thread, then handed to the main-actor renderer in arrival order (the main queue is
/// FIFO, which keeps acquire → update → invalidate ordered).
final class WallpaperHostHandler: NSObject, WallpaperExtensionXPCProtocol {
    private let pid: Int32

    init(pid: Int32) {
        self.pid = pid
        super.init()
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "StarTorchWallpaperExtension", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: Lifecycle

    func acquire(withId anId: Any?, request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        let decoded = HostRequestDecoder.creationRequest(id: anId, request: request)
        bridgeLog.info("ACQUIRE \(decoded.key, privacy: .public) (pid \(self.pid))")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let contextID = VideoWallpaperRenderer.shared.acquire(decoded, makeContext: PrivateRemoteContext.make) else {
                    reply(nil, Self.error(1, "Could not create the remote layer context"))
                    return
                }
                guard let payload = PrivateXPCObjects.remoteContext(contextID: contextID) else {
                    reply(nil, Self.error(2, "Could not build WallpaperRemoteContextXPC"))
                    return
                }
                reply(payload, nil)
            }
        }
    }

    func update(withId anId: Any?, request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        let decoded = HostRequestDecoder.updateRequest(id: anId, request: request)
        bridgeLog.info("UPDATE \(decoded.key, privacy: .public) mode=\(decoded.modeName ?? "?", privacy: .public) activity=\(decoded.activityName ?? "?", privacy: .public)")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                VideoWallpaperRenderer.shared.update(decoded)
                reply(nil)
            }
        }
    }

    func invalidate(withId anId: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        let key = HostRequestDecoder.surfaceKey(fromID: anId)
        bridgeLog.info("INVALIDATE \(key, privacy: .public)")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                VideoWallpaperRenderer.shared.invalidate(key: key)
                reply(nil)
            }
        }
    }

    func snapshot(withId anId: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        let key = HostRequestDecoder.surfaceKey(fromID: anId)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let payload = VideoWallpaperRenderer.shared.snapshotImage(forKey: key).flatMap(PrivateXPCObjects.snapshot(image:))
                reply(payload, nil)
            }
        }
    }

    // MARK: Settings

    func provideSettingsViewModels(withContentTypes types: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let thumbnail = VideoWallpaperRenderer.shared.settingsThumbnailURL
                reply(WallpaperSettingsPayload.makeViewModels(thumbnailURL: thumbnail), nil)
            }
        }
    }

    // MARK: Choices (single fixed choice: nothing to add, remove or download)

    func addChoiceRequest(withChoiceRequest request: Any?, onBehalfOfProcess process: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) {
        reply(nil, nil)
    }

    func removeChoiceRequest(withChoiceRequest request: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func selectedChoicesDidChange(for anId: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { HostAgents.shared.invalidateSnapshots() }
        }
        reply(nil)
    }

    func invokeContextMenuAction(withMenuItemID menuItemID: Any?, groupItemID: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    func isChoiceDownloaded(with choiceID: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) {
        reply(true, nil)
    }

    func download(withChoiceID choiceID: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) -> Any? {
        reply(nil)
        return nil
    }

    func pauseDownload(for choiceID: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func cancelDownload(for choiceID: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func resumeDownload(for choiceID: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func removeDownload(for choiceID: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }

    // MARK: Migration, shuffle, debug, notifications

    func migrateSelectedChoice(for anId: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) { reply(nil, nil) }
    func migrate(from: Any?, to: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func skipShuffledContent(withId anId: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    func canSkipShuffledContent(withId anId: Any?, reply: @escaping @Sendable (Bool, (any Error)?) -> Void) { reply(false, nil) }
    func handleDebugRequest(for request: Any?, reply: @escaping @Sendable (Any?, (any Error)?) -> Void) { reply(nil, nil) }
    func handleNotification(withNamed name: Any?, reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
}
