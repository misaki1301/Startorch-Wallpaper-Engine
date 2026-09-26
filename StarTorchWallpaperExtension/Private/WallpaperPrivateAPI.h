//
//  WallpaperPrivateAPI.h — bridging header of the StarTorchWallpaperExtension target.
//
//  ╔══════════════════════════════════════════════════════════════════════════════════╗
//  ║ PRIVATE / REVERSE-ENGINEERED. Nothing declared here is public macOS API.          ║
//  ║                                                                                    ║
//  ║ • CAContext — QuartzCore's private remote-layer context. The extension hands its  ║
//  ║   `contextId` to WallpaperAgent, which composites our layer tree on the desktop   ║
//  ║   and the lock screen.                                                             ║
//  ║ • WallpaperExtensionXPCProtocol / WallpaperExtensionProxyXPCProtocol — the ObjC   ║
//  ║   shapes of the XPC protocols WallpaperAgent speaks with extensions on the        ║
//  ║   private `com.apple.wallpaper` ExtensionKit point (WallpaperExtensionKit.framework).║
//  ║                                                                                    ║
//  ║ Only the protocol *shapes* are declared; the framework itself is dlopen'ed at     ║
//  ║ runtime, never linked. Every selector below was checked against the runtime's     ║
//  ║ own protocol descriptions on macOS 27.0 (26A428); a macOS update may change them. ║
//  ╚══════════════════════════════════════════════════════════════════════════════════╝
//
//  Ported from the owner's prototype (wallpapermoduleweb/WallpaperApp,
//  WallpaperAppWallpaperExtension/WallpaperExtension-Bridging-Header.h). Changes: reply blocks
//  are NS_SWIFT_SENDABLE for Swift 6, and the file carries this notice.
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Private CAContext API (remote rendering)

@interface CAContext : NSObject
@property (readonly) unsigned int contextId;
@property (retain, nullable) CALayer *layer;
+ (nullable id)remoteContext NS_SWIFT_NAME(makeRemoteContext());
+ (nullable id)remoteContextWithOptions:(nullable NSDictionary *)options NS_SWIFT_NAME(makeRemoteContext(options:));
@end

#pragma mark - Extension -> Host (WallpaperAgent)

@protocol WallpaperExtensionProxyXPCProtocol <NSObject>
- (void)pingWithId:(id _Nullable)anId;
- (void)updateSettingsViewModels:(id _Nullable)models reply:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))reply;
- (void)requestReadOnlyAccessTo:(id _Nullable)url reply:(void (NS_SWIFT_SENDABLE ^)(id _Nullable))reply;
- (void)invalidateSnapshotsWithReply:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))reply;
@end

#pragma mark - Host (WallpaperAgent) -> Extension

@protocol WallpaperExtensionXPCProtocol <NSObject>

// Lifecycle
- (void)acquireWithId:(id _Nullable)anId request:(id _Nullable)request reply:(void (NS_SWIFT_SENDABLE ^)(id _Nullable, NSError * _Nullable))reply;
- (void)updateWithId:(id _Nullable)anId request:(id _Nullable)request reply:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))reply;
- (void)invalidateWithId:(id _Nullable)anId reply:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))reply;
- (void)snapshotWithId:(id _Nullable)anId reply:(void (NS_SWIFT_SENDABLE ^)(id _Nullable, NSError * _Nullable))reply;

// Settings
- (void)provideSettingsViewModelsWithContentTypes:(id _Nullable)types reply:(void (NS_SWIFT_SENDABLE ^)(id _Nullable, NSError * _Nullable))reply;

// Choices
- (void)addChoiceRequestWithChoiceRequest:(id _Nullable)request onBehalfOfProcess:(id _Nullable)process reply:(void (NS_SWIFT_SENDABLE ^)(id _Nullable, NSError * _Nullable))reply;
- (void)removeChoiceRequestWithChoiceRequest:(id _Nullable)request reply:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))reply;
- (void)selectedChoicesDidChangeFor:(id _Nullable)anId reply:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))reply;
- (void)invokeContextMenuActionWithMenuItemID:(id _Nullable)menuItemID groupItemID:(id _Nullable)groupItemID reply:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))reply;

// Downloads
- (void)isChoiceDownloadedWith:(id _Nullable)choiceID reply:(void (NS_SWIFT_SENDABLE ^)(BOOL, NSError * _Nullable))reply;
- (id _Nullable)downloadWithChoiceID:(id _Nullable)choiceID reply:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))reply;
- (void)pauseDownloadFor:(id _Nullable)choiceID reply:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))reply;
- (void)cancelDownloadFor:(id _Nullable)choiceID reply:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))reply;
- (void)resumeDownloadFor:(id _Nullable)choiceID reply:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))reply;
- (void)removeDownloadFor:(id _Nullable)choiceID reply:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))reply;

// Migration
- (void)migrateSelectedChoiceFor:(id _Nullable)anId reply:(void (NS_SWIFT_SENDABLE ^)(id _Nullable, NSError * _Nullable))reply;
- (void)migrateFrom:(id _Nullable)from to:(id _Nullable)to reply:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))reply;

// Shuffle
- (void)skipShuffledContentWithId:(id _Nullable)anId reply:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))reply;
- (void)canSkipShuffledContentWithId:(id _Nullable)anId reply:(void (NS_SWIFT_SENDABLE ^)(BOOL, NSError * _Nullable))reply;

// Debug & notifications
- (void)handleDebugRequestFor:(id _Nullable)request reply:(void (NS_SWIFT_SENDABLE ^)(id _Nullable, NSError * _Nullable))reply;
- (void)handleNotificationWithNamed:(id _Nullable)name reply:(void (NS_SWIFT_SENDABLE ^)(NSError * _Nullable))reply;

@end

NS_ASSUME_NONNULL_END
