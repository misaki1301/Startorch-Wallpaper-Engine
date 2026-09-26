# Lock screen video through the Aerials pipeline (research spike, Phase L1)

**Status:** research prototype. Nothing is wired into the app UI. Nothing in this document was
applied to a real system: every finding comes from read-only inspection of one Mac running
**macOS 27.0 (26A428)** with the macOS 27 SDK, and the recommendation still has to be proven by
the manual test plan at the end.

**Goal:** get a StarTorch clip playing on the macOS lock screen the way Apple's Aerials do (and
the way Backdrop by Cindori does), for the user's own app on their own Mac. This depends on
undocumented macOS internals that can change in any update.

## TL;DR

- Apple's lock screen video comes from `WallpaperAerialsExtension`, a system ExtensionKit
  extension. A third-party app can't be that extension. It can, however, add its own entry to
  the extension's **per-user, user-owned manifest** and place a matching video next to Apple's.
- `entries.json` has **no signature, checksum or hash check**. It's plain JSON extracted from
  `manifest.tar`, and it's only re-extracted when a **new** manifest is downloaded (checked about
  twice a day with a conditional GET, and in practice after each macOS update).
- Apple's clips are **HEVC Main 10, 240 fps (time scale 240000), BT.709 SDR, `.mov`, no audio**,
  with 5 temporal sub-layers. The extension's player works on original sample times and ramps the
  frame "level" down when you unlock (the slow-motion stop). A custom clip should be 240 fps.
- **Recommendation: add our own asset and category** with our own UUIDs; don't overwrite an Apple
  asset. Place the video atomically (new inode), tag it with the `SourceURL` xattr the extension
  uses, back up everything, and re-apply whenever the manifest is refreshed.
- Prototype: `AerialsInstaller` (Swift, injected paths, tested on a synthetic store),
  `AerialClipExporter` (makes the 240 fps clip, tested), and `scripts/aerials-dev.sh`
  (`status | apply | revert` for manual testing, with backups and a typed `yes`).

## Where things live (macOS 27.0)

| What | Path | Owner |
|---|---|---|
| Aerials extension | `/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex` (`com.apple.wallpaper.extension.aerials`, v313.0.4.401) | root, SSV |
| Extension point | `/System/Library/ExtensionKit/ExtensionPoints/com.apple.wallpaper.appexpt` (`EXRequiredEntitlements: com.apple.private.wallpaper.extension`) | root, SSV |
| Host | `/System/Library/CoreServices/WallpaperAgent.app` (links `WallpaperAerialsCore` too) | root, SSV |
| Aerials store | `~/Library/Application Support/com.apple.wallpaper/aerials/` | **user** |
| Selection | `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` | user |
| Background-check prefs | `com.apple.wallpaper.aerial` defaults domain | user |
| Built-in fallback | `/System/Library/Wallpapers/.default/Golden Gate.mov` | root, SSV |

The extension is sandboxed; its entitlements give it read-write access to
`~/Library/Application Support/com.apple.wallpaper/` (home-relative temporary exception), network
client, CacheDelete and the `com.apple.wallpaper.aerial` preferences:

```
$ codesign -d --entitlements - /System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex
  com.apple.private.CacheDelete = [PURGEABLE_ENTITLEMENT, …]
  com.apple.security.app-sandbox = true
  com.apple.security.network.client = true
  com.apple.security.temporary-exception.files.home-relative-path.read-write = [/Library/Application Support/com.apple.wallpaper/]
  com.apple.security.temporary-exception.files.absolute-path.read-write = [/System/Library/Desktop Pictures/, /Library/Application Support/com.apple.idleassetsd/]
  com.apple.security.temporary-exception.shared-preference.read-write = [com.apple.wallpaper, com.apple.wallpaper.aerial]
```

## Q1. Video format

Measured with a small AVFoundation probe (sample-level scan of the first 3000 samples),
`ffprobe` and `avmediainfo` on the downloaded clips (read-only):

```
$ avmediainfo …/aerials/videos/4C108785-A7BA-422E-9C79-B0129F1D5550.mov      # "Tahoe Day"
Duration: 299.937 seconds (179962/600)
Track 1: Video 'vide'   Format: HEVC 'hvc1'   Dimensions: 3840 x 2160
	Media time scale: 240000   Estimated data rate: 12431.863 kbit/s
	Nominal frame rate: 240.000 fps   Minimum sample duration: 1000/240000 seconds
	Frame reordering required

$ ffprobe -show_streams -show_format …
profile=Main 10  codec_tag_string=hvc1  pix_fmt=yuv420p10le  level=183
color_range=tv  color_space=bt709  color_transfer=bt709  color_primaries=bt709
r_frame_rate=240/1  time_base=1/240000  nb_frames=71985  has_b_frames=4
TAG:major_brand=qt  nb_streams=1

probe: sync samples at [0, 1185, 2385]   sample durations: ["1000/240000"]
       first PTS: [0.0, 0.0667, 0.0333, 0.0167, 0.0083, 0.0042]    # hierarchical B-frames
       hvcC: 01 22 20000000 b00000000000 b7 f000 fc fd fa fa 0000 2b 03 …
             profile_space 0, tier High, profile Main10 (2), level 6.1 (0xb7)
             byte 21 = 0x2b → numTemporalLayers = 5, lengthSize = 4
       asset metadata items: 0; metadata tracks: none; audio tracks: none; track associations: none
```

| Clip | Size | Duration | Color | Rate / time scale | Keyframes |
|---|---|---|---|---|---|
| 4C108785 Tahoe Day | 3840×2160 | 299.94 s | BT.709 / BT.709 / BT.709 | 240 fps / 240000 | every 1185–1200 |
| 4207734D Golden Gate Sunset | 4096×2160 | 300.00 s | BT.709 | 240 fps / 240000 | every 1185–1200 |
| 6D6834A4 Sequoia Sunrise | 3840×2160 | 315.00 s | **P3 D65 / gamma 2.2 (code 4) / BT.709** | 240 fps / 240000 | every 1169–1184 |
| 506107AC (orphan, see Q5) | 1920×1080 | 216.05 s | untagged, full range | **60 fps / 600** | every 60 |

What the "240FPS" in `url-4K-SDR-240FPS` means: every sample really is 1/240 s long (≈72 000
frames per 5 minutes) at only ~12 Mbit/s, encoded as a 5-layer temporal hierarchy
(240/120/60/30/15 fps), so a decoder can drop layers. The logs show why it matters: the player
reads samples itself and ramps a "level" down when you unlock, which is the slow-motion stop:

```
[com.apple.wallpaper:video-player] Pause Action: Switch to .beginRampingDown
[com.apple.wallpaper:video-player] RAMP-DOWN switch from level 1 to level 2 at originalPTS 5.233333
[com.apple.wallpaper:video-player] RAMP-DOWN switch from level 2 to level 3 at originalPTS 5.700000
[com.apple.wallpaper:video-player] RAMP-DOWN switch from level 3 to level 4 at originalPTS 5.900000
[com.apple.wallpaper:video-player] minUpcomingOriginalPTS.seconds 0.004167 - self.firstPrerolledPTS!.seconds 0.000000 = 0.004167
```

No HDR metadata (no mastering display or content light level; transfer is BT.709), no audio, no
timed metadata, no `udta` besides the encoder name. `pointsOfInterest` in the manifest maps
seconds to caption keys; it's `{}` for many assets, so it's optional in practice.

**What a custom clip must match (recommended):** `.mov` (`qt  `), one HEVC `hvc1` Main 10 track,
BT.709 video range, **240 fps with 1000/240000 sample durations**, keyframe about every 5 s,
~3840×2160, ~12 Mbit/s, no audio. `AerialClipExporter` produces exactly that (verified in
`AerialClipExporterTests` and with ffprobe: `profile=Main 10 hvc1 yuv420p10le bt709 r_frame_rate=240/1
time_base=1/240000 nb_frames=240 major_brand=qt`). It can't reproduce the 5 temporal sub-layers
(AVAssetWriter doesn't expose that VideoToolbox option), and slower sources are brought to 240
fps by repeating frames, so the unlock ramp will look stepped rather than smooth. Frame
interpolation (for example VideoToolbox's frame-rate conversion on macOS 15.4+) would fix that
later.

Confidence: **high** for the measured format; **medium** that 240 fps is required rather than
just safest (the player's ramp and PTS math strongly suggest it; only a test can confirm).

## Q2. Manifest lifecycle

Evidence:

```
$ xattr -l aerials/manifest.tar
LastETag: "67FC25B13FC5E7F5C1BB4CD7C5AFC433"
SourceURL: https://sylvan.apple.com/itunes-assets/Aerials126/v4/82/2e/34/822e344c-…/resources-27-0-1.tar
com.apple.quarantine: 0086;…;WallpaperAerialsExtension;
$ stat: manifest.tar mtime 2026-09-03 12:42:51; entries.json mtime 2026-09-02 13:07:12 (from the tar), ctime 2026-09-03 12:42:51
$ ps: WallpaperAerialsExtension (pid 701) started 2026-09-17 11:04:09 (boot 11:02:53)
$ defaults read com.apple.wallpaper.aerial
  lastUpdateDate = "2026-09-03 17:42:51 +0000"; scheduledUpdateDate = "2026-09-26 21:53:10 +0000";
  remoteResourceExpirationDate = "2026-09-27 08:50:13 +0000";
  remoteResourceURL = "https://sylvan.apple.com/…/resources-27-0-1.tar"
/System/Library/Wallpapers/.default/* installed 2026-09-03 05:34 (the macOS 27.0 update)
```

and the logs for a background check (twice a day in the 7-day window):

```
[aerials-activity-scheduler] Triggered background activity com.apple.wallpaper.aerials.background-activity
[aerial-assets] Updating remote resource url
[aerial-assets] Successfully updated remote resource url: https://sylvan.apple.com/…/resources-27-0-1.tar
[aerial-assets] Updating manifest
[aerial-assets] Resource at: <private> has not been modified
[aerial-assets] No manifest updates
```

Strings in the extension binary confirm the flow and name the knobs:

```
https://configuration.apple.com/configurations/internetservices/aerials/resources-config-27-0.plist
https://sylvan.apple.com/…/resources-27-0-0.tar          (built-in default)
Decompressing manifest / Finished decompressing manifest / Loading downloaded manifest / Loading fallback manifest
Successfully updated manifest to %s / No manifest updates / Re-downloading %ld selected video(s) whose URL changed
Perform manifest migration / Resetting aerial ID to default during migration: %{public}s
AerialManifestForceLocal / AerialManifestLocalPathOverride / AerialManifestURLOverride   (defaults keys)
manifestJSONFileName, manifestSourceFileName, manifestVideoStorageURL, manifestThumbnailStorageURL
```

`nm -u` shows no `CC_SHA*`/`Sec*` imports; strings have no checksum, digest or signature logic;
only libarchive. `TVIdleScreenStrings.bundle` is code-signed, but it's only used for localized
strings.

Conclusions:

- **Refresh trigger:** a background activity (about every 12 h) fetches the per-OS config plist
  (`resources-config-27-0.plist`), then does a conditional GET (`If-None-Match` with `LastETag`)
  for the tar. Only a **changed** tar is downloaded and **re-extracted over `entries.json`**.
  The config name is per OS version, so an OS update is a near-certain refresh (here: macOS 27.0
  installed 05:34, new manifest 12:42 the same day). Apple can also publish a new tar at any time.
- **Not** re-extracted at launch or boot: `entries.json`'s ctime (Sep 3) predates the running
  extension (Sep 17 boot).
- **No integrity check** on `entries.json`. A custom asset/category survives until the next
  refresh, then disappears. After a refresh, "manifest migration" resets selected IDs that no
  longer exist to the default Aerial, so the user's selection is lost too.
- The extension decodes the whole manifest; a decoding error falls back to the built-in manifest
  (`ManifestDecodingError`, "Loading fallback manifest"), which would hide every downloaded Aerial.
  So our entries must be schema-perfect (the installer validates this).
- `AerialManifestForceLocal` / `AerialManifestLocalPathOverride` / `AerialManifestURLOverride`
  could pin a local manifest, but they look like internal-build switches and changing Apple's
  preferences is out of scope for this spike (hypothesis, untested).

Confidence: **high** for the flow and absence of checks; **medium** for the exact cadence.

## Q3. Asset resolution

- Storage is by ID: `videos/<asset id>.mov`, `thumbnails/<asset id>.png` and
  `thumbnails/<subcategory id>.png`. On this Mac all 164 assets and all 65 subcategories have a
  thumbnail with exactly that name; categories have none (they use `representativeAssetID`).
- Downloads are tagged with `SourceURL` (the remote URL) and `LastETag` xattrs. The Golden Gate
  file's `SourceURL` (`…v5_Final01_HFR_HEVC.mov`) differs from its current manifest URL
  (`…v7_24comp_HFR_16Mbps.mov`) and it was **not** re-downloaded; the string
  "Re-downloading %ld selected video(s) whose URL changed" says that only happens to **selected**
  videos. So a local file is used as is, but a selected asset whose URL differs from the file's
  `SourceURL` is re-downloaded (and would overwrite a swapped file).
- A missing video is downloaded on selection ("Begin asset download", "Downloading first asset")
  or in the background when the policy allows. Unselected videos are marked APFS-purgeable via
  CacheDelete ("Marked '%s' as %spurgeable") and can vanish under storage pressure.
- Remote thumbnails are skipped when there is no URL ("No remote thumbnail url for %s; skipping");
  a local `thumbnails/<id>.png` is used as is (`localAssetThumbnailURL`).
- Names come from `TVIdleScreenStrings.bundle` via `localizedStringForKey:value:table:`. An
  unknown key comes back as the key itself, so our `localizedNameKey` is the display name.

For our asset the installer therefore sets `url-4K-SDR-240FPS` to the **`file://` URL of the
placed video itself** and writes the same string to its `SourceURL` xattr. The URLs match, so
the "URL changed" re-download shouldn't fire, and if the video is ever purged a re-download can
only fail locally instead of fetching something from the network. Whether the extension accepts
a `file://` URL at all (it logs "resulted in non-HTTP response" for some downloads) is unknown;
`status` detects a missing video either way.

Confidence: **high** for the naming; **medium** for re-download behavior; **low** for how a
`file://` URL is treated.

## Q4. Selection

`Store/Index.plist` (copied to a temp folder, then decoded) has `AllSpacesAndDisplays`,
`SystemDefault`, `Spaces` and `Displays`, each with `Desktop` and/or `Idle`
`Content.Choices[] = {Provider, Files, Configuration}`, plus `EncodedOptionValues`. On this Mac:

```
101 × com.apple.wallpaper.choice.image    Configuration = bplist {type: "imageFile", url: {relative: "file:///…png"}}
  7 × com.apple.wallpaper.choice.sequoia  Configuration = <0 bytes>
  2 × com.example.WallpaperApp.WallpaperExtension  Files = [file:///…/rem.html], Configuration = "3481844267"
backup: com.apple.wallpaper.choice.screen-saver  Configuration = bplist {module: {relative: "file:///…appex"}}
```

No Aerial is selected right now, so there is no Aerial `Configuration` sample. The provider ID
is `com.apple.wallpaper.choice.aerials` (in the shared cache next to `…image`, `…dynamic`,
`…sequoia`, etc.), and the extension logs "Failed to decode AerialAssetConfiguration", so the
blob is an encoded configuration holding the asset ID (exact keys unknown).

**Recommendation:** don't write `Index.plist`. Once our asset and category are in the manifest
and the extension has reloaded it, the user picks **System Settings › Wallpaper › StarTorch**.
The same choice drives the desktop and the lock screen. Writing `Index.plist` directly would need
the undocumented configuration encoding and would race `WallpaperAgent`, which owns the file.

Confidence: **high** for the provider ID and the image format; **medium** that the new category
appears in System Settings (to be confirmed by the manual test).

## Q5. Why a naive .mov swap crashes (hypotheses, ranked)

There were **no wallpaper crash reports** in `~/Library/Logs/DiagnosticReports` on this Mac, so
this rests on the binary, the logs and the file evidence:

1. **Frame-rate/timing mismatch (most likely).** The player works in *original PTS*, prerolls,
   and ramps between frame "levels" on unlock. A 24–60 fps H.264/HEVC file where it expects 240 fps
   with 5 temporal layers breaks those assumptions. The logs already show fragile timing with
   Apple's own clips: `PendingStillWithoutRamp: switch to still state scheduled for nan time …
   Adjusting schedule time to DispatchTime.now()` (61× in 7 days). A NaN or out-of-range time that
   isn't caught on some path (Swift traps on `Int(Double.nan)`) is the classic way repeated
   lock/unlock cycles end in a crash.
2. **Overwriting in place.** `cp new.mov <id>.mov` truncates and rewrites the same inode while the
   extension (and CoreMedia) may have it open or cached, so reads see a half-written file. The
   prototype writes to a temporary name and renames, so open handles keep the old inode.
3. **Cached state keyed by asset ID.** The extension snapshots the player on every stop
   (`Taking snapshot of video player in order to cache it for future runs`, `Using existing
   snapshot as initial wallpaper contents`, 235× in 7 days) and keeps an image cache. After a swap
   those caches describe the old clip (duration, first frame); an edit/seek based on the old
   duration past the new clip's end is plausible. Using our own asset ID avoids inheriting them.
4. **Re-download over the swap.** A swapped Apple asset still has Apple's URL. When Apple changes
   that URL (as happened to Golden Gate) and the asset is selected, the extension re-downloads it,
   possibly while the swapped file is being played.
5. **Memory.** Unusual bitrates or 4K60 H.264 in the extension's playback-memory budget (logs show
   constant `FigOSTransactions` pruning) could get the process killed after many cycles.

The orphan `506107AC-….mov` (1080p60, untagged color, full range, `com.apple.provenance` instead
of Apple's `SourceURL`/`LastETag`/quarantine xattrs, and an ID that's no longer in the manifest)
looks like the result of an earlier manual swap on this Mac. It shows that such leftovers are
never cleaned up. It was only inspected, not touched.

Confidence: **low to medium**; these are ranked hypotheses, not a diagnosis.

## Q6. Recommendation

**Add our own asset and category; don't replace an Apple one.**

| | Replace an Apple asset | Add our own (recommended) |
|---|---|---|
| Survives manifest refresh | the file survives, but the URL may change and trigger a re-download over it | entries vanish; detected by `status`, fixed by re-apply |
| Inherits Apple's caches, `SourceURL`, purge state | yes | no |
| Shows up as | Apple's name and thumbnail | "StarTorch" with our thumbnail |
| Revert | restore Apple's 500 MB file (or re-download) | delete three files, restore one JSON |
| Collides with Apple data | yes, by design | no (own UUIDs) |

Design (implemented in `ikuyo-live-wallpaper/Services/AerialsInstaller.swift`):

1. Export the clip with `AerialClipExporter` (240 fps HEVC Main 10 BT.709 `.mov`).
2. Back up `entries.json` (copy keeps bytes, dates and xattrs) and anything at our target paths,
   and write an install record with the manifest's SHA-256 before/after and the `manifest.tar`
   fingerprint (size, whole-second mtime, `LastETag`).
3. Place `videos/<our id>.mov` and both thumbnails by copy-then-rename; tag the video with
   `SourceURL` = the `file://` URL written into the manifest.
4. Insert asset + category + subcategory into `entries.json`, validating every required key
   against the real schema (all 164 real assets and 6 categories pass the same validation), and
   write it atomically **last**, so the extension never sees an entry without its files.
5. Restart `WallpaperAerialsExtension` (it only reads the manifest at launch or after a
   download), then the user selects "StarTorch" in System Settings › Wallpaper.
6. `status()` reports `needsReapply([.manifestRefreshed, .entriesMissing, .videoMissing,
   .videoChanged, .thumbnailMissing])`; the app would check this on launch/wake and re-apply.
7. `revert()` restores the backup byte for byte if the manifest is still ours; if macOS has
   replaced it since, it keeps Apple's new manifest (only stripping our entries if present), and
   always deletes our files.

Still unknown until the user tests: whether the category shows in System Settings; whether the
`file://` URL is accepted or triggers a failing download loop; whether a 240 fps repeated-frame
clip ramps without glitches; whether our entry survives the twice-daily "No manifest updates"
checks (it should) and what exactly happens to the selection on a real refresh; and whether it
all survives a reboot.

## Verified vs hypothesis

| Claim | Status | Evidence |
|---|---|---|
| Aerials store is per-user, user-owned, writable without sudo | **Verified** | `ls -la` (misaki:staff) |
| Asset/category keys of `entries.json` | **Verified** | 164/164 assets carry the 12 required keys; `variant`, `videoGravity` (4), `group` (44) optional |
| `entries.json` is JSONSerialization-style (pretty, sorted, escaped `/`) | **Verified** | raw bytes; numeric `pointsOfInterest` keys are sorted as text |
| Video, thumbnail naming by ID | **Verified** | 164/164 assets, 65/65 subcategories |
| Clip format (HEVC Main10 240 fps, BT.709, 5 temporal layers, no audio/metadata) | **Verified** | probe, ffprobe, avmediainfo, hvcC bytes |
| `AerialClipExporter` output matches that format (except temporal layers) | **Verified** | unit test + ffprobe |
| No signature/hash check on `entries.json` | **Verified (static)** | strings, `nm -u`, no Sec/CC imports |
| Manifest re-extracted only when a new tar is downloaded | **Verified** | ctime vs process start, logs "No manifest updates" |
| Background check ≈ every 12 h, conditional GET | **Verified** | logs, `LastETag` xattr, prefs dates |
| OS update ⇒ new manifest ⇒ our entries wiped | **Likely** | per-OS config URL; tar downloaded hours after the 27.0 install |
| Selection reset to default after refresh | **Likely** | "Resetting aerial ID to default during migration" |
| Aerial provider ID `com.apple.wallpaper.choice.aerials` | **Verified** | shared cache strings |
| Aerial `Configuration` encoding | Unknown | no Aerial selected on this Mac |
| Custom category appears in System Settings | Hypothesis | to test |
| `file://` in `url-4K-SDR-240FPS` is harmless | Hypothesis | to test |
| 240 fps is required (not just safest) | Hypothesis | player ramp/PTS logs |
| Naive swap crash cause | Hypothesis | Q5 |
| A third-party extension at `com.apple.wallpaper` can be hosted | **Observed, unexplained** | see below |

### Side finding: a non-Apple wallpaper extension is being hosted

`/Applications/WallpaperApp.app` (team B97JTSGWZ2, bundle `com.example.WallpaperApp`,
development-signed with only sandbox/network entitlements) contains
`WallpaperAppWallpaperExtension.appex` declaring `EXExtensionPointIdentifier = com.apple.wallpaper`.
Despite the extension point's `EXRequiredEntitlements`, `WallpaperAgent` launched it (pid 1094),
calls `provideSettingsViewModels`, and `Index.plist` has it selected on one Space. Its
notification handlers fail (`WallpaperExtensionKit.WallpaperExtensionError (1)`). With SIP
enabled, this suggests the entitlement check isn't enforced for discovery on this build, or that
a development-signed extension is allowed. It was only observed, not investigated further. If the
lock screen accepts such an extension, it would be a cleaner route than editing Apple's manifest
and deserves its own spike.

## Risks

- **macOS updates:** very likely to wipe our entries (each OS version has its own manifest config,
  and 27.0 refreshed the same day it was installed). Handled by detect-and-re-apply, but the
  selection has to be picked again. Changes to the schema, the store path, the extension's
  sandbox or its player are all possible in any update (high likelihood over a year).
- **Whole-manifest failure:** a malformed entry makes the extension fall back to its built-in
  manifest; mitigated by schema validation and the atomic write, and fixed by `revert`.
- **Crashes:** a clip that doesn't match (Q5) may crash the extension after repeated lock visits;
  mitigated by exporting in the Aerial format and by our own asset ID.
- **Storage:** ~450 MB per 5-minute 4K clip, placed in a folder CacheDelete may purge.
- **Policy:** undocumented, may stop working without notice; not suitable for the App Store build.

## Prototype files

- `ikuyo-live-wallpaper/Services/AerialsInstaller.swift`: `AerialsStore` (paths, no default),
  `AerialsManifest` (pure JSON edits + validation), `AerialsInstaller` (`apply`, `status`,
  `revert`, backups, install record).
- `ikuyo-live-wallpaper/Services/AerialClipExporter.swift`: `AerialClipFormat.macOS27` and
  `AerialClipExporter.export(source:output:format:)`.
- `ikuyo-live-wallpaperTests/AerialsInstallerTests.swift`: synthetic manifest (made-up IDs, same
  schema), apply/revert byte-exactness, refresh and purge detection, re-apply after refresh.
- `ikuyo-live-wallpaperTests/AerialClipExporterTests.swift`: container, codec, 10-bit, BT.709,
  240 fps, time scale, sample durations, keyframe spacing, no audio.
- `scripts/aerials-dev.sh`: `status | apply [--dry-run] <video> | revert [--dry-run]`.

## Manual test plan (for the user)

The spike never ran `apply` or `revert`. To test:

1. `scripts/aerials-dev.sh status` and keep the output.
2. Export a clip in the Aerial format (for now from a test harness calling
   `AerialClipExporter.export`, or any 240 fps HEVC Main 10 `.mov`), e.g. `~/Movies/startorch-aerial.mov`.
3. `scripts/aerials-dev.sh apply --dry-run ~/Movies/startorch-aerial.mov`, read the plan, then
   `scripts/aerials-dev.sh apply ~/Movies/startorch-aerial.mov` and type `yes`.
   It backs up to `~/Library/Application Support/StarTorch Aerials Backups/<timestamp>/` and
   restarts `WallpaperAerialsExtension` and `WallpaperAgent`.
4. System Settings › Wallpaper: find the **StarTorch** category and select it. Confirm the desktop
   and the lock screen (⌃⌘Q) play the clip.
5. Lock and unlock **20+ times**, including leaving it locked for a few minutes. Watch Console
   (`process:WallpaperAerialsExtension`) and check `~/Library/Logs/DiagnosticReports` for
   `WallpaperAerialsExtension*.ips` after each few cycles.
6. Reboot, log in, check the lock screen again, then `scripts/aerials-dev.sh status`.
7. Leave it for a day (two background checks) and run `status` again; it should still say
   "applied and intact".
8. Revert: `scripts/aerials-dev.sh revert --dry-run`, then `scripts/aerials-dev.sh revert` and
   type `yes`. Pick another wallpaper in System Settings if StarTorch was still selected.
