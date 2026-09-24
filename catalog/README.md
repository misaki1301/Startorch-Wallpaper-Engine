# Wallpaper catalog

`catalog.json` is the manifest behind the in-app **Gallery**. The app downloads it from
`main` on launch (raw.githubusercontent.com), caches it, and falls back to the copy bundled
in `ikuyo-live-wallpaper/Resources/catalog.json` when offline. Keep both files in sync
when you cut a release.

## Rules for adding a wallpaper

Only add videos you have the right to redistribute. Each entry needs:

- a license that allows redistribution (e.g. CC0, CC BY, Pexels License, or your own work), and
- a `creator` to credit and, ideally, a `sourceURL` pointing at the original page.

Host the file somewhere you control (a GitHub Release asset works well) rather than
hot-linking another site's CDN.

## Schema

```json
{
  "version": 1,
  "wallpapers": [
    {
      "id": "rainy-window",
      "title": "Rainy Window",
      "creator": "Jane Doe",
      "license": "CC BY 4.0",
      "url": "https://github.com/misaki1301/Startorch-Wallpaper-Engine/releases/download/catalog-1/rainy-window.mp4",
      "sourceURL": "https://example.com/original-page",
      "posterURL": "https://…/rainy-window.jpg",
      "duration": 12.0,
      "width": 3840,
      "height": 2160,
      "fps": 30,
      "bitrate": 12000000
    }
  ]
}
```

`id`, `title`, `creator`, `license` and `url` are required; the rest are optional and feed
future features (posters, energy badges).
