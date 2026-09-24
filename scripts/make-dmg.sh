#!/bin/bash
#
# make-dmg.sh — Package a built .app into a distributable, compressed DMG
# with a symlink to /Applications, using only built-in macOS tools
# (hdiutil). No Homebrew / create-dmg dependency.
#
# Usage:
#   scripts/make-dmg.sh <path-to-.app> <version> [output-dir]
#
# Example:
#   scripts/make-dmg.sh "build/Release/StarTorch Wallpaper Engine.app" 1.0.0 dist
#
# Produces: <output-dir>/StarTorch-Wallpaper-Engine-<version>.dmg

set -euo pipefail

APP_NAME="StarTorch Wallpaper Engine"
VOLUME_NAME="StarTorch Wallpaper Engine"

usage() {
  echo "Usage: $0 <path-to-.app> <version> [output-dir]" >&2
  exit 1
}

APP_PATH="${1:-}"
VERSION="${2:-}"
OUT_DIR="${3:-dist}"

if [[ -z "$APP_PATH" || -z "$VERSION" ]]; then
  usage
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle not found at: $APP_PATH" >&2
  exit 1
fi

DMG_FILENAME="StarTorch-Wallpaper-Engine-${VERSION}.dmg"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
DMG_PATH="$OUT_DIR/$DMG_FILENAME"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

STAGING_DIR="$WORK_DIR/staging"
mkdir -p "$STAGING_DIR"

echo "==> Staging DMG contents in $STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"

echo "==> Building compressed DMG: $DMG_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "$DMG_PATH"

echo "==> Verifying DMG"
hdiutil verify "$DMG_PATH"

echo "==> Done: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
