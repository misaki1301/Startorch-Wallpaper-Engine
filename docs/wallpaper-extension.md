# Lock screen & desktop via a native wallpaper extension (Route A)

StarTorch ships an extension, **StarTorchWallpaperExtension**, on macOS's `com.apple.wallpaper`
ExtensionKit point. This is the same pipeline Apple's Aerials use. Once you pick **StarTorch** in
System Settings › Wallpaper, macOS itself (`WallpaperAgent`) plays the exported StarTorch clip on
the desktop **and on the lock screen**, even when the StarTorch app isn't running.

> **This relies on private, undocumented macOS interfaces.** Apple doesn't support it, a macOS
> update can break it without warning, and it can't ship on the Mac App Store. The rest of
> StarTorch (the desktop window engine) doesn't depend on it.

The design is ported from the owner's own working prototype
(`wallpapermoduleweb/WallpaperApp`, target `WallpaperAppWallpaperExtension`, "Web Wallpaper").
[Phosphene](https://github.com/kageroumado/phosphene), an open-source project, uses the same
technique. Only its Xcode project layout was consulted, to choose where the extension is
embedded; none of its code was copied.

## Architecture

```
StarTorch Wallpaper Engine.app
├── Contents/MacOS/…                      the app (unchanged desktop engine)
│     Settings › "Lock Screen & Desktop (System Wallpaper)"
│       └─ WallpaperExtensionExporter ──writes──┐
└── Contents/Extensions/StarTorchWallpaperExtension.appex   (launched by WallpaperAgent only)
      ├─ Private/  (the only private-API code)   │
      │    WallpaperPrivateAPI.h                 │
      │    WallpaperHostBridge.swift             │
      │    WallpaperSettingsPayload.swift        │
      ├─ VideoWallpaperRenderer.swift            │
      └─ WallpaperContentSource.swift ◀──reads───┘
                 App Group container  B97JTSGWZ2.com.shibuyaxpress.ikuyo-live-wallpaper
                 Library/Application Support/SystemWallpaper/
                   manifest.json   clips/<hash>.mp4|mov   posters/<hash>.jpg
```

Code under `WallpaperExtensionShared/` is compiled into **both** the app and the extension:

- `SystemWallpaperStore`: the hand-off format.
- `SystemWallpaperPresentation` and `SystemWallpaperPlayback`: the playback rules.

The app's test bundle unit-tests these files.

### How WallpaperAgent drives the extension (host protocol)

The agent-side calls the extension handles are listed below. The selectors were checked against
the runtime's own protocol descriptions on macOS 27.0 (26A428).

| Call | What StarTorch does |
|---|---|
| `provideSettingsViewModels…` | Replies with one group and one choice, **StarTorch**, as a `WallpaperSettingsViewModelsXPC`. It has a video badge, and its thumbnail is the exported poster (or a bundled icon). |
| `acquireWithId:request:` | Decodes the size, scale, display, `isPreview`, `presentationMode` and `activityState`. Creates or reuses the surface's layer tree in a private remote `CAContext`, and replies with a `WallpaperRemoteContextXPC` carrying the context ID. WallpaperAgent composites that layer tree. |
| `updateWithId:request:` | Applies a new `presentationMode` / `activityState` (and size). |
| `invalidateWithId:` | The surface is no longer shown. Its layers are kept for a quick re-acquire, but it stops holding a decoder. |
| `snapshotWithId:` | Returns the poster as a `WallpaperSnapshotXPC` (IOSurface). |
| Everything else (choices, downloads, shuffle, migration, debug, notifications) | Returns a no-op reply. |

### Lock screen and desktop signals

The host's private enums, as read from the 26A428 runtime:

- `WallpaperPresentationMode`: `default` (desktop), `locked` (lock screen / login window) or
  `idle`.
- `WallpaperActivityState`: `active` or `suspended`.

The lock screen shows the **Desktop** choice in `locked` mode. The screen saver ("Idle") choice
is separate, and StarTorch doesn't offer one.

The rules are in `SystemWallpaperPresentation` and are unit-tested:

- **Play** while `active`, in any mode. **Pause** when `suspended`, which is how the host reports
  a surface nobody can see.
- **Desktop**: exactly the user's dim and vignette from StarTorch.
- **Lock screen**: the same, but dim is at least 15% so the clock and password field stay
  legible.
- **Unknown future cases**: show and play.
- **Previews** (System Settings tiles): show the poster only and never create a decoder.

### Renderer (replaces the prototype's `WebWallpaperRenderer`)

The prototype used a hidden `WKWebView` and snapshotted it into an IOSurface 30 times a second on
a timer. StarTorch replaces that with plain layers:

- `AVQueuePlayer` + `AVPlayerLooper`, muted, with `preventsDisplaySleepDuringVideoPlayback = false`.
- **One player (one decoder) per unique clip**, shared by every display's `AVPlayerLayer`.
- Layer stack: a poster layer (shown until the first video frame and whenever the clip can't
  load), then the `AVPlayerLayer` (aspect fill), a dim layer, and a radial vignette. The dim and
  vignette match the app's own.
- The player runs only while at least one non-preview surface is visible. When nothing needs it,
  it is released.
- **No timers or polling.** Everything is driven by:
  - host calls,
  - KVO on `isReadyForDisplay`,
  - a kqueue watcher on the hand-off folder.
- Not applied: **blur**, which would need a Core Image filter on every frame.

### Content hand-off (app → extension)

The prototype bundled its content inside the app. That doesn't work for a wallpaper the user
picks at run time, so StarTorch uses an **App Group container** instead. Both targets are
entitled to `B97JTSGWZ2.com.shibuyaxpress.ikuyo-live-wallpaper`. Because the ID is team-prefixed,
macOS 15+ grants both targets access without a prompt when they are signed by that team.

**Export Current Wallpaper** does the following:

1. Copies the playing clip's local file to `clips/<hash>.<ext>`. The hash comes from the source
   URL, size and modification date, so re-exporting the same clip is a no-op. The copy goes to a
   hidden `.partial` file first, which is then renamed.
2. Writes the first frame to `posters/<hash>.jpg`. This step may fail; the clip still exports.
3. Replaces `manifest.json` **atomically**, last, so the extension never sees a manifest that
   points at a missing clip.
4. Deletes the clips and posters the new manifest no longer names.

The extension watches the folder. When the manifest's revision changes, it swaps in the new
poster and clip, and asks WallpaperAgent to refresh its snapshots (`invalidateSnapshots`). When it
reads a manifest, it ignores unknown versions and any file name that could escape its folder.

A remote catalog wallpaper has to be downloaded before it can be exported.

## The private surface

All private API lives in `StarTorchWallpaperExtension/Private/`, and each file starts with a
notice box.

| Private piece | How it's used | What breaks it |
|---|---|---|
| The `com.apple.wallpaper` extension point | `EXExtensionPointIdentifier` in `Info.plist` | Apple enforcing its declared `EXRequiredEntitlements` (see Signing below) |
| `WallpaperExtensionKit.framework` | `dlopen` at launch, **never linked**; the startup log checks for 5 critical classes | Classes renamed or removed |
| Its XPC protocols | ObjC protocol shapes in `WallpaperPrivateAPI.h` | Selectors changing (all 25 were verified on 26A428) |
| `WallpaperRemoteContextXPC`, `WallpaperSnapshotXPC` | Instances created with `class_createInstance`. The context ID or IOSurface is written into the `box` / `rawValue` ivar at offset 8 (ivar name and size checked first) | Ivar layout changes |
| `WallpaperCreationRequestXPC`, `WallpaperUpdateRequestXPC` | Read with `Mirror` (`destination.size`, `scaleFactor`, `directDisplayID`, `isPreview`, `presentationMode`, `activityState`) | Field renames: the defaults are 2560×1440 @2x, desktop, active |
| `WallpaperSettingsViewModelsXPC` | A Codable mirror of the WallpaperTypes model, archived under a shim class and unarchived as the real class | Key renames: the host ignores the choice and StarTorch disappears from the picker |
| `CAContext` (QuartzCore) | `+remoteContextWithOptions:` and `contextId` | Unlikely to change; Aerials depend on it |

## Risks

- **A macOS update can break it silently.** Any of the private layouts above can change. Failure
  modes range from StarTorch missing from System Settings, to a black wallpaper, to the extension
  crashing. WallpaperAgent then falls back to a default wallpaper, and the rest of the system is
  unaffected.
- **Entitlement enforcement.** If Apple starts enforcing `com.apple.private.wallpaper.extension`,
  third parties can't obtain it, and Route A stops working entirely.
- **Energy.** A 4K HEVC clip decodes continuously while the desktop or lock screen is visible, on
  hardware decode. It pauses only when the host says `suspended`. Test this: see CPU and memory
  in the test plan.
- **Old surfaces are kept.** Invalidated surfaces keep their (decoder-free) layer tree for quick
  re-acquire, as in the prototype. Surface IDs that are never reused (e.g. many display changes)
  accumulate small layer trees until WallpaperAgent terminates the extension, which it does after
  about 5 minutes of inactivity.
- **Notifications.** WallpaperAgent logs `handleNotification … WallpaperExtensionError (1)` for
  the prototype on every wake and time change. The reply is `nil`, the same as the prototype, and
  it is harmless: the agent schedules a normal disconnect.
- **App Store.** Private API: not possible.

## Signing findings (read-only investigation, macOS 27.0 26A428)

Evidence gathered with `codesign -d`, `pluginkit -m`, `log show` and in-process reflection only.
Nothing was registered, installed or launched.

1. **The extension point declares a private entitlement, but it isn't enforced for extensions on
   this build.** Confidence: high.
   - `/System/Library/ExtensionKit/ExtensionPoints/com.apple.wallpaper.appexpt` declares
     `EXRequiredEntitlements = { com.apple.private.wallpaper.extension = true }`.
   - The prototype `/Applications/WallpaperApp.app/Contents/PlugIns/WallpaperAppWallpaperExtension.appex`
     has only `app-sandbox`, `network.client/server` and `get-task-allow`.
   - The prototype is listed by `pluginkit -m -p com.apple.wallpaper`. On 2026-09-26 at 03:50,
     `extensionkit:launch` logged "Launching process with config … com.example.WallpaperApp.WallpaperExtension",
     and WallpaperAgent's `extension-proxy` logged `connect` and several `provideSettingsViewModels`
     round trips to it. Its process (pid 1094) runs with launch arguments
     `{"type":1,…,"enhancedSecurity":false}`.
   - Apple's own `WallpaperAerialsExtension.appex` also lacks the entitlement. The other ten
     system wallpaper extensions have it.
2. **Apple Development signing works.** Confidence: high. This is direct evidence: the prototype
   is signed "Apple Development: Paul Frank Pacheco Carpio (M2732GPYNA)", team B97JTSGWZ2, with
   hardened runtime on the extension, and runs as above.
3. **Developer ID signing: likely to work, but not verified.** Confidence: medium.
   - The only gate observed is entitlement-based. Nothing seen depends on the certificate type:
     the extension launch config carries no development-only flag, and only `enhancedSecurity`
     appears.
   - No Developer ID-signed wallpaper extension was available to observe on this Mac.
   - Test it with the notarized release before relying on it.
4. **Ad-hoc signing: expect it not to work.** Confidence: low to medium; not tested. There are
   three problems:
   - An ad-hoc signature has no team. The team-prefixed App Group then can't be verified, and on
     macOS 15+ the container access is refused or prompts. The extension would show only black.
   - The release workflow's unsigned fallback runs `codesign --force --sign -` on the app only.
     That doesn't re-sign the embedded extension with its entitlements, so the extension isn't
     sandboxed, and ExtensionKit is expected to refuse an unsandboxed extension. This is the
     documented ExtensionKit requirement; it wasn't observed.
   - Whether ExtensionKit even lists an ad-hoc third-party extension on this point is unknown.
5. **Unsigned local builds** (`CODE_SIGNING_ALLOWED=NO`, as in CI) carry no entitlements at all:
   no sandbox and no App Group.

### Build-time registration and the inert extension point

Xcode runs `lsregister -f -R -trusted` on **every** macOS app it builds. This is swift-build's
`RegisterWithLaunchServices` step, and no build setting turns it off. So building the app
registers its embedded extension from DerivedData.

To let CI and local verification build the app without exposing an unsigned extension to
WallpaperAgent, the extension point comes from a build setting:

- The project default is `STARTORCH_WALLPAPER_EXTENSION_POINT = com.apple.wallpaper`.
- The verification builds for this change were run with
  `STARTORCH_WALLPAPER_EXTENSION_POINT=com.shibuyaxpress.startorch.inert-local-build`, and
  `pluginkit -m` confirmed nothing StarTorch appeared.
- CI checks that the built extension's point is `com.apple.wallpaper`.

**Don't pass the override for a build you want to use.**

## Manual test plan

You need a Mac running macOS 14 or later (developed against 27.0), and Xcode signed into team
B97JTSGWZ2.

1. **Build signed.**
   1. Open the project and select the `ikuyo-live-wallpaper` scheme.
   2. Choose Product › Archive, then Distribute App › Custom › Copy App. Alternatively, build
      Release with "Apple Development" signing.
   3. Check the signature:
      - `codesign -d --entitlements - "…/StarTorch Wallpaper Engine.app/Contents/Extensions/StarTorchWallpaperExtension.appex"`
        must show `app-sandbox` and the `B97JTSGWZ2.com.shibuyaxpress.ikuyo-live-wallpaper` group.
      - `plutil -p …/StarTorchWallpaperExtension.appex/Contents/Info.plist | grep EXExtensionPoint`
        must show `com.apple.wallpaper`.
2. **Install.**
   1. Quit any running StarTorch.
   2. Copy the app to `/Applications`, replacing any older copy.
   3. Launch it once.
   4. Check registration: `pluginkit -m -p com.apple.wallpaper | grep shibuyaxpress` should list
      `com.shibuyaxpress.ikuyo-live-wallpaper.WallpaperExtension`.
3. **Export.**
   1. Play a local or downloaded wallpaper.
   2. Open Settings (⌘,) › Lock Screen & Desktop (System Wallpaper) › **Export Current Wallpaper**.
   3. The status should show the title and "now".
4. **Select.**
   1. Click **Open Wallpaper Settings…**, or open System Settings › Wallpaper.
   2. Pick **StarTorch** (look near Aerials).
   3. Stop StarTorch's own desktop engine so the two don't overlap.
5. **Desktop.**
   - The clip plays full-screen, aspect-filled, muted and looping, with your dim and vignette.
   - It keeps playing after quitting the StarTorch app.
6. **Lock screen.**
   1. Press ⌃⌘Q, check that the clip plays behind the clock, then unlock.
   2. **Repeat 20 or more times.** Watch for black frames, a frozen frame, a poster that never
      becomes video, or the Aerial/default image replacing it.
7. **Re-export.** Pick another wallpaper and export again. The desktop should switch without
   re-selecting in System Settings, and the System Settings thumbnail should update.
8. **Two displays.** Connect a second display.
   - Both play, with one decoder: see step 11.
   - Unplug and replug the display. Change its resolution.
9. **Sleep and wake.**
   1. Sleep with  › Sleep, wait a minute, then wake.
   2. Repeat with the lid closed (laptops) and with the display asleep (`pmset displaysleepnow`).
   3. Playback resumes, and nothing plays while asleep.
10. **Reboot.** StarTorch should still be selected and play at the login window and on the
    desktop.
11. **Console.** Filter on subsystem `com.shibuyaxpress.ikuyo-live-wallpaper.WallpaperExtension`
    and on process `WallpaperAgent`.
    - Expected: `ACQUIRE`, `UPDATE mode=… activity=…`, `Created the player`, `Released the player`.
    - Report any `UNSUPPORTED RUNTIME`, `Missing runtime types`, `No App Group container`,
      unarchiving errors, or crashes (`~/Library/Logs/DiagnosticReports/StarTorchWallpaperExtension*`).
12. **CPU and memory.** In Activity Monitor, find `StarTorchWallpaperExtension`:
    - While the desktop is visible: low CPU, with hardware decode showing as GPU / Video
      Decoder.
    - While covered by a full-screen app, or while locked with the display off: close to 0%.
    - With two displays on one clip: one decoder, and memory shouldn't double.
    - Leave it running for an hour; memory should stay flat.
13. **Uninstall.**
    1. In System Settings › Wallpaper, pick any other wallpaper first.
    2. Quit StarTorch and move it from `/Applications` to the Trash.
    3. Optionally delete the hand-off folder:
       `~/Library/Group Containers/B97JTSGWZ2.com.shibuyaxpress.ikuyo-live-wallpaper`.
    4. Check with `pluginkit -m -p com.apple.wallpaper`: StarTorch disappears once LaunchServices
       notices the removal. Log out and back in if it lingers.

## Relation to other work

- **#62**: screen saver + `StarTorchShared/` hand-off. It is independent and complementary: the
  screen saver covers the "Idle" slot, while this extension covers the desktop and lock screen.
  - #62 writes into the legacy screen saver's container through a temporary-exception
    entitlement. This PR uses its own `WallpaperExtensionShared/` folder and an App Group.
  - Both PRs add a key to the app's `.entitlements` and a section to `SettingsView`. Merging one
    after the other needs only a trivial textual conflict resolution.
- **#63**: the Aerials research spike (`docs/lockscreen-aerials.md`). It proposes injecting a
  StarTorch asset into Apple's Aerials store. That spike's "side finding" is a development-signed,
  non-Apple extension hosted by WallpaperAgent: that is the owner's prototype, and this PR builds
  on it.
  - This route writes nothing into Apple's stores.
  - It doesn't need the 240 fps Aerial clip format.
  - It never restarts WallpaperAgent.

  The two routes are alternatives; if this one holds up, #63's installer isn't needed.
