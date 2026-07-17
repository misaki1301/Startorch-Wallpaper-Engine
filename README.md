# StarTorch Wallpaper Engine

**Turn your Mac desktop into a living canvas.** Play animated video wallpapers behind your icons with zero performance impact.

Built with SwiftUI + AVFoundation. macOS 14+ (Sonoma & later).

---

## Features

| | Feature | Description |
|---|---------|-------------|
| 🎬 | **Video Wallpapers** | Play any MP4 as your desktop wallpaper, behind icons and above the dock |
| 🖼️ | **Gallery** | Browse and select from a curated collection of wallpapers |
| 📂 | **Local Import** | Import your own videos; auto-converts to HEVC for ~50% smaller files |
| ❤️ | **Favorites** | Heart wallpapers for quick access; cached offline for instant playback |
| 🖥️ | **Multi-Display** | Scales across all connected monitors |
| 🎛️ | **Menu Bar** | Start/Stop, Pause/Resume without opening the app |
| 📊 | **System Stats** | CPU and RAM usage at a glance |
| 💾 | **In-Memory Playback** | Cached wallpapers play from RAM — zero disk I/O |
| 🔁 | **Seamless Looping** | Gapless playback with AVPlayerLooper |

## Download

### Option 1: Direct Download (Recommended)

1. Go to [**Releases**](https://github.com/misaki1301/startorch-wallpaper-engine/releases)
2. Download `StarTorch Wallpaper Engine.zip` from the latest release
3. Unzip and drag to `/Applications`
4. Right-click → **Open** (first launch only — bypasses Gatekeeper)

### Option 2: Build from Source

```bash
git clone https://github.com/misaki1301/startorch-wallpaper-engine.git
cd startorch-wallpaper-engine
open "StarTorch Wallpaper Engine.xcodeproj"
# Press ⌘R to build and run
```

**Requirements:** Xcode 26+ (or Xcode 16.4+), macOS 14+

## Usage

1. The app runs in your **menu bar** (photo icon) — click to open the gallery
2. Select a wallpaper from **Gallery** or import your own via **My Files**
3. Click **Start Wallpaper** to activate
4. Use menu bar controls to pause/resume or stop anytime

## Tech Stack

| Layer | Technology |
|-------|------------|
| Language | Swift 6, SwiftUI |
| UI | AppKit (NSWindow, AVPlayerLayer) |
| Video | AVFoundation (AVPlayerLooper, AVAssetExportSession) |
| Persistence | SwiftData, UserDefaults, FileManager cache |
| Stats | Mach APIs (host_cpu_load_info, task_vm_info) |

## Project Structure

```
StarTorch Wallpaper Engine/
├── Models/          # WallpaperItem, ImportedWallpaperStore
├── Services/        # WallpaperManager, CacheManager, VideoConverter, StatsService
├── Utils/           # MemoryResourceLoader (AVAssetResourceLoaderDelegate)
├── Views/           # SwiftUI views (Gallery, Favorites, Import, Configuration)
└── Assets.xcassets  # App icon & accent color
```

## Known Limitations

- GPU usage not available (no public per-process GPU API on macOS)
- HEVC conversion may fail on some exotic video formats (falls back gracefully)
- Video sources are currently hardcoded URLs (configurable via code)

## Contributing

Contributions welcome! Open an issue or submit a PR.

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes
4. Push and open a Pull Request

## License

MIT License — see [LICENSE](LICENSE) for details.

## Credits

Created by [@misaki1301](https://github.com/misaki1301)

Wallpaper samples from [danbooru.donmai.us](https://danbooru.donmai.us) and [Pexels](https://pexels.com) (testing only).
