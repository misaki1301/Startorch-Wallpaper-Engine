# ikuyo Live Wallpaper

A macOS live wallpaper app that plays video wallpapers behind your desktop icons. Built with SwiftUI and AppKit.

> 🚧 **Work in progress** — This is my first big project. Things might break, improve, or change entirely.

## Features

- **Video Wallpapers** — Play any MP4 as your desktop wallpaper, behind icons and above the dock
- **Gallery** — Browse and select from a curated collection of wallpapers
- **Local Import** — Import your own video files; automatically converts to HEVC for smaller file sizes (~50% reduction)
- **Favorites** — Heart your favorite wallpapers; cached offline so they play without internet
- **Multi-Display** — Wallpaper scales across all connected monitors
- **Menu Bar Controls** — Start/Stop, Pause/Resume from the menu bar without opening the app
- **System Stats** — CPU and RAM usage shown in the menu bar dropdown
- **In-Memory Playback** — Small cached wallpapers play entirely from RAM for zero disk I/O
- **Seamless Looping** — Gapless playback with `AVPlayerLooper`

## Requirements

- macOS 15.0+
- Apple Silicon or Intel Mac
- App Sandbox enabled (network access for downloading wallpapers)

## Installation

1. Clone the repo
2. Open `ikuyo-live-wallpaper.xcodeproj` in Xcode
3. Build and run (⌘R)

The app runs as a regular window with a menu bar icon. Use the **Gallery** tab to browse wallpapers, or **My Files** to import your own.

> **Note**: The wallpaper window sits at `kCGDesktopWindowLevel + 1` — above the desktop wallpaper, behind icons. This requires running outside the App Store (sandboxed distribution is fine for local builds).

## Tech Stack

| Area | |
|---|---|
| Language | Swift 6 |
| UI | SwiftUI + AppKit (NSWindow, AVPlayerLayer) |
| Video | AVFoundation (AVPlayerLooper, AVAssetExportSession) |
| Persistence | UserDefaults, FileManager cache |
| Stats | Mach APIs (host_cpu_load_info, task_vm_info, getrusage) |

## Project Structure

```
ikuyo-live-wallpaper/
├── Models/          # WallpaperItem, ImportedWallpaperStore
├── Services/        # WallpaperManager, CacheManager, VideoConverter, StatsService
├── Utils/           # MemoryResourceLoader (AVAssetResourceLoaderDelegate)
├── Views/           # SwiftUI views (Gallery, Favorites, Import, Settings, etc.)
└── Assets.xcassets  # App icon
```

## Known Limitations

- GPU usage stats are not shown (no public API for per-process GPU on macOS)
- Imported HEVC conversion can fail on some source video formats (falls back gracefully)
- Menu bar transparency with live wallpaper behind it isn't possible with public APIs
- Video sources are currently hardcoded URLs (configurable via code)

## Credits

Created by[](https://github.com/shiroha1301) me @misaki1301

Wallpaper samples are from danbooru.donmai.us and Pexels (for testing purposes only).
