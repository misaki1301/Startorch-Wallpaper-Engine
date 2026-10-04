# Live video behind the transparent menu bar (macOS 26 Tahoe)

## Bug

On Tahoe the menu bar is transparent. The strip behind it shows a **static image** instead of the live video.

## What the code does today

- `WallpaperController.makeDesktopWindow` (`Services/WallpaperController.swift:333-361`) creates a plain borderless `NSWindow`:
  - Frame: `screen.frame`. That includes the menu bar strip, with no inset.
  - Level: `desktopWindow + 1`.
  - The frame is never set again after `orderFrontRegardless()`.
- While the video plays, `updateStillFrames()` (`:365-450`) and `DesktopRestorer.showFrames` set the video's **first frame** as the real system desktop picture (via `NSWorkspace.setDesktopImageURL`). That frame has the dim, blur and vignette baked in.
- `ScreenLayoutChanges` (`:42-62`) compares `window.frame == screen.frame`.
  - If AppKit constrains the window below the menu bar, every `present()` re-sets the frame, AppKit constrains it again, and nothing errors.
- `MenuBarContrast.menuBarHeight` is hardcoded to `24`. Tahoe and notched menu bars are about 37 pt tall.

## Hypotheses

- **A. The window doesn't reach the strip.** AppKit (`constrainFrameRect(_:to:)`) keeps the window below the menu bar, so the still-frame desktop picture shows through.
- **B. The WindowServer draws the desktop picture behind the bar** rather than windows at desktop level.
  - This is certainly the case when *System Settings → Menu Bar → "Show menu bar background"* or *Reduce Transparency* is on. The bar is then tinted from the desktop picture by design.

AppKit usually leaves borderless windows unconstrained, so B is at least as likely as A. That is why the diagnostic comes first.

## Plan

### 1. Diagnostic (DEBUG only; run on a Mac)

- Log the window's position in `makeDesktopWindow`, right after `orderFrontRegardless()`, and in `present()`, after the resize loop:
  - `window.frame`, `screen.frame`, `screen.visibleFrame` and `screen.safeAreaInsets.top`
  - this app's entries from `CGWindowListCopyWindowInfo`: `kCGWindowBounds` and `kCGWindowLayer`
- Use the logger `Logger(subsystem: "com.shibuyaxpress.startorch-wallpaper", category: "DesktopWindow")` and read it with:
  `log stream --predicate 'subsystem == "com.shibuyaxpress.startorch-wallpaper"'`
- Check with a red desktop picture: set a solid-red desktop picture, or skip `showFrames` behind a DEBUG flag.
  - Red under the bar points to B.
  - Video under the bar means it was the still frame.
- Check the logged window frame.
  - If it starts below the menu bar, that confirms A.
- Note the "Show menu bar background" and Reduce Transparency settings.
- Compare the built-in (notched) display with an external one.

### 2. Primary fix: keep the window over the menu bar (fixes A, harmless otherwise)

- Add a new `Services/DesktopWallpaperWindow.swift`. The project uses synchronized groups, so no pbxproj edit is needed.

  ```swift
  final class DesktopWallpaperWindow: NSWindow {
      override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
      override var canBecomeKey: Bool { false }
      override var canBecomeMain: Bool { false }
  }
  ```

- In `makeDesktopWindow`:
  - build the window as a `DesktopWallpaperWindow`
  - call `setFrame(screen.frame, display: false)` again after `orderFrontRegardless()`
  - optionally add `.fullScreenNone` to the window's collection behavior
- In `ScreenLayoutChanges`, compare `frame.integral` on both sides so sub-point rounding isn't treated as a resize.

### 3. If the bar still shows the desktop picture (hypothesis B)

1. Document it as a limitation in the Readability/inspector UI.
   - The still frame already makes the bar's tint match the video's first frame, which is the best that window-based rendering can do.
2. On macOS 26, point users to the existing **system wallpaper extension** (`StarTorchWallpaperExtension`, "Export to System Wallpaper" in Settings).
   - The system renders it as the real wallpaper, so the menu bar backdrop, Mission Control and the lock screen are all live.
3. Try the level `desktopIconWindow - 1` instead of `desktopWindow + 1`, behind a DEBUG toggle first.
4. Rejected: refreshing the desktop picture with the current video frame. Each refresh means a PNG encode plus a WindowServer reload. It costs energy, flickers and writes to disk constantly.

### 4. `MenuBarContrast` height

- Make the height a parameter: `analyze(_:screenHeight:menuBarHeight: = 24, dim:)`.
- The caller passes `max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)`.
  - If that is `0` (the menu bar auto-hides), fall back to 24.

### 5. Tests (Swift Testing)

- `ScreenLayoutChanges`:
  - a window pushed 24 pt under the menu bar → `resized`
  - sub-point rounding → not a resize
- `DesktopWallpaperWindow`:
  - `constrainFrameRect` returns its input unchanged
  - it can't become key or main
- `MenuBarContrast`: a 24 pt strip vs a 38 pt strip gives different luminance on a synthetic image.
- CI can't test compositing. Step 1 is the manual check.

### Order

1. Diagnostic logging (step 1).
2. Window subclass and the frame comparison fix, with their tests (step 2).
3. `MenuBarContrast` height, with its test (step 4).
4. Step 3, depending on the diagnostic result.
