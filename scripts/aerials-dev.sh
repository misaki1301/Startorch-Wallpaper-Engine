#!/bin/bash
# aerials-dev.sh — research tool (Phase L1): put one StarTorch clip into macOS's Aerials
# pipeline so the system wallpaper extension plays it on the lock screen, and take it out again.
#
#   scripts/aerials-dev.sh status                    read-only report, changes nothing
#   scripts/aerials-dev.sh apply [--dry-run] <video> add the clip as a "StarTorch" Aerial
#   scripts/aerials-dev.sh revert [--dry-run]        undo the last apply
#
# This edits undocumented per-user files that macOS owns:
#   ~/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json
#   ~/Library/Application Support/com.apple.wallpaper/aerials/videos/<id>.mov
#   ~/Library/Application Support/com.apple.wallpaper/aerials/thumbnails/<id>.png
# Every file is backed up to a timestamped folder first, apply and revert print exactly what they
# will change and wait for you to type "yes", and only then restart the wallpaper processes.
# Nothing here needs sudo, touches /System, or changes which wallpaper is selected.
# See docs/lockscreen-aerials.md for why it works, the risks, and the test plan.
#
# The clip should already be in the Aerial format (HEVC Main 10, 240 fps, BT.709, .mov); make it
# with AerialClipExporter (ikuyo-live-wallpaper/Services/AerialClipExporter.swift).
set -euo pipefail

# Our own IDs (never Apple's). Shared with AerialsCustomAsset.starTorch in the app.
readonly ASSET_ID="5E64385F-BDBF-488A-9C03-CF8745BA45B4"
readonly CATEGORY_ID="35EB7A9E-3873-4E3F-9657-FC2E713D5B51"
readonly SUBCATEGORY_ID="28A3A684-EAD9-456A-94B8-262CC0687481"
readonly TITLE="StarTorch"

# AERIALS_ROOT / AERIALS_BACKUP_ROOT exist so the script can be pointed at a copy for testing.
readonly STORE="${AERIALS_ROOT:-$HOME/Library/Application Support/com.apple.wallpaper/aerials}"
readonly BACKUP_ROOT="${AERIALS_BACKUP_ROOT:-$HOME/Library/Application Support/StarTorch Aerials Backups}"
readonly ENTRIES="$STORE/manifest/entries.json"
readonly TAR="$STORE/manifest.tar"
readonly VIDEO_TARGET="$STORE/videos/$ASSET_ID.mov"
readonly THUMB_TARGET="$STORE/thumbnails/$ASSET_ID.png"
readonly SUBTHUMB_TARGET="$STORE/thumbnails/$SUBCATEGORY_ID.png"
readonly INDEX_PLIST="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
readonly JQ="${JQ:-/usr/bin/jq}"

die() { echo "error: $*" >&2; exit 1; }
note() { echo "  $*"; }

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
mtime() { stat -f '%m' "$1"; }
fsize() { stat -f '%z' "$1"; }
xattr_or_none() { xattr -p "$1" "$2" 2>/dev/null || echo "(none)"; }

# file:// URL for a path. Only spaces are escaped, so refuse anything more exotic.
file_url() {
    case "$1" in
        *[!A-Za-z0-9/._\ -]*) die "unexpected characters in path: $1" ;;
    esac
    printf 'file://%s' "${1// /%20}"
}

require_tools() {
    [[ -x "$JQ" ]] || die "jq not found at $JQ (macOS 15+ ships /usr/bin/jq; or set JQ=...)"
}

require_store() {
    [[ -f "$ENTRIES" ]] || die "no Aerials manifest at $ENTRIES — open System Settings › Wallpaper once so macOS creates it"
    "$JQ" -e '(.assets | type) == "array" and (.categories | type) == "array"' "$ENTRIES" >/dev/null \
        || die "$ENTRIES doesn't have the expected assets/categories arrays; macOS may have changed the format"
}

ours_in_manifest() {
    "$JQ" -e --arg a "$ASSET_ID" --arg c "$CATEGORY_ID" \
        '(any(.assets[]; .id == $a)) and (any(.categories[]; .id == $c))' "$ENTRIES" >/dev/null 2>&1
}

latest_backup() {
    [[ -d "$BACKUP_ROOT" ]] || return 0
    local dir
    for dir in $(ls -1 "$BACKUP_ROOT" 2>/dev/null | sort -r); do
        if [[ -f "$BACKUP_ROOT/$dir/install.env" && ! -f "$BACKUP_ROOT/$dir/REVERTED" ]]; then
            echo "$BACKUP_ROOT/$dir"
            return 0
        fi
    done
}

confirm() {
    echo
    printf 'Type "yes" to go ahead, anything else to cancel: '
    local answer
    read -r answer
    [[ "$answer" == "yes" ]] || { echo "Cancelled. Nothing was changed."; exit 1; }
}

restart_note() {
    note "restart: killall WallpaperAerialsExtension, then killall WallpaperAgent"
    note "  WallpaperAerialsExtension (/System/Library/ExtensionKit/Extensions/WallpaperAerialsExtension.appex)"
    note "  only reads entries.json when it launches or when it downloads a new manifest."
    note "  WallpaperAgent (/System/Library/CoreServices/WallpaperAgent.app) is relaunched by launchd"
    note "  at once and starts the extension again on demand. The desktop may flash once."
}

restart_wallpaper() {
    echo "Restarting the Aerials extension and the wallpaper agent…"
    killall WallpaperAerialsExtension 2>/dev/null || true
    killall WallpaperAgent 2>/dev/null || true
    sleep 2
    pgrep -x WallpaperAgent >/dev/null && echo "WallpaperAgent is running again." \
        || echo "WallpaperAgent hasn't come back yet; log out and in if the wallpaper stays blank."
}

cmd_status() {
    require_tools
    echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "Store: $STORE"
    if [[ ! -f "$ENTRIES" ]]; then
        echo "  no entries.json (Aerials never opened on this account?)"
        return 0
    fi
    echo
    echo "manifest.tar"
    if [[ -f "$TAR" ]]; then
        note "size $(fsize "$TAR"), modified $(date -r "$(mtime "$TAR")" '+%F %T')"
        note "LastETag $(xattr_or_none LastETag "$TAR")"
        note "SourceURL $(xattr_or_none SourceURL "$TAR")"
    else
        note "(missing)"
    fi
    echo "entries.json"
    note "$("$JQ" -r '"version \(.version), localizationVersion \(.localizationVersion), \(.assets | length) assets, \(.categories | length) categories"' "$ENTRIES")"
    note "modified $(date -r "$(mtime "$ENTRIES")" '+%F %T'), sha256 $(sha256 "$ENTRIES")"
    echo "Background manifest check (com.apple.wallpaper.aerial)"
    note "last update $(defaults read com.apple.wallpaper.aerial lastUpdateDate 2>/dev/null || echo '?'), next check $(defaults read com.apple.wallpaper.aerial scheduledUpdateDate 2>/dev/null || echo '?')"
    echo
    echo "StarTorch Aerial ($ASSET_ID)"
    if ours_in_manifest; then note "in manifest: yes"; else note "in manifest: no"; fi
    if [[ -f "$VIDEO_TARGET" ]]; then
        note "video: $(fsize "$VIDEO_TARGET") bytes, SourceURL $(xattr_or_none SourceURL "$VIDEO_TARGET")"
    else
        note "video: missing"
    fi
    for t in "$THUMB_TARGET" "$SUBTHUMB_TARGET"; do
        [[ -f "$t" ]] && note "thumbnail $(basename "$t"): present" || note "thumbnail $(basename "$t"): missing"
    done
    if [[ -f "$INDEX_PLIST" ]] && grep -q "$ASSET_ID" "$INDEX_PLIST" 2>/dev/null; then
        note "selected in Index.plist: yes"
    else
        note "selected in Index.plist: no (pick it in System Settings › Wallpaper after apply)"
    fi

    local backup
    backup="$(latest_backup)"
    echo
    if [[ -z "$backup" ]]; then
        echo "No active install recorded under $BACKUP_ROOT."
    else
        echo "Last apply: $backup"
        # shellcheck disable=SC1091
        source "$backup/install.env"
        local drift=()
        [[ "$(xattr_or_none LastETag "$TAR")" == "$TAR_ETAG" && "$(mtime "$TAR" 2>/dev/null || echo 0)" == "$TAR_MTIME" ]] \
            || drift+=("manifest.tar changed (macOS downloaded a new manifest)")
        ours_in_manifest || drift+=("our entries are gone from entries.json")
        [[ -f "$VIDEO_TARGET" ]] || drift+=("video missing (purged?)")
        [[ -f "$VIDEO_TARGET" && "$(fsize "$VIDEO_TARGET")" == "$VIDEO_SIZE" ]] || [[ ! -f "$VIDEO_TARGET" ]] \
            || drift+=("video size changed")
        if ((${#drift[@]} == 0)); then
            echo "Status: applied and intact."
        else
            echo "Status: NEEDS RE-APPLY:"
            for d in "${drift[@]}"; do note "- $d"; done
            note "Run: $0 revert, then $0 apply <video>"
        fi
    fi
    echo
    echo "Processes"
    note "WallpaperAgent pid $(pgrep -x WallpaperAgent || echo '-'), WallpaperAerialsExtension pid $(pgrep -x WallpaperAerialsExtension || echo '-')"
}

cmd_apply() {
    local dry_run=0
    if [[ "${1:-}" == "--dry-run" ]]; then dry_run=1; shift; fi
    local video="${1:-}"
    [[ -n "$video" ]] || die "usage: $0 apply [--dry-run] <video.mov>"
    [[ -f "$video" ]] || die "no such file: $video"
    video="$(cd "$(dirname "$video")" && pwd)/$(basename "$video")"
    require_tools
    require_store
    if ours_in_manifest; then
        die "the StarTorch Aerial is already in the manifest; run '$0 revert' first"
    fi

    echo "Checking the clip against the Aerial format (HEVC hvc1, 240 fps)…"
    local info warn=0
    info="$(avmediainfo "$video" 2>/dev/null || true)"
    grep -q "HEVC 'hvc1'" <<<"$info" || { note "WARNING: not HEVC 'hvc1'"; warn=1; }
    grep -q "Nominal frame rate: 240" <<<"$info" || { note "WARNING: not 240 fps"; warn=1; }
    grep -q "Track [0-9]*: Audio" <<<"$info" && { note "WARNING: has an audio track"; warn=1; }
    ((warn == 0)) && note "looks like an Aerial clip." \
        || note "Apple's player retimes 240 fps samples; export with AerialClipExporter first to be safe."

    local stamp backup video_url thumb_url
    stamp="$(date '+%Y%m%d-%H%M%S')"
    backup="$BACKUP_ROOT/$stamp"
    video_url="$(file_url "$VIDEO_TARGET")"
    thumb_url="$(file_url "$THUMB_TARGET")"

    echo
    echo "Plan:"
    note "back up  $ENTRIES"
    note "     to  $backup/entries.json"
    for t in "$VIDEO_TARGET" "$THUMB_TARGET" "$SUBTHUMB_TARGET"; do
        if [[ -e "$t" ]]; then
            note "replace  $t  (leftover from an earlier StarTorch apply; our own ID)"
        else
            note "create   $t"
        fi
    done
    note "         video copied from $video ($(fsize "$video") bytes), tagged SourceURL=$video_url"
    note "         thumbnails made from the clip with qlmanage"
    note "edit     $ENTRIES:"
    note "         + asset    $ASSET_ID \"$TITLE\" (url-4K-SDR-240FPS=$video_url)"
    note "         + category $CATEGORY_ID \"$TITLE\" with subcategory $SUBCATEGORY_ID"
    note "         ($("$JQ" '.assets | length' "$ENTRIES") -> $(( $("$JQ" '.assets | length' "$ENTRIES") + 1 )) assets," \
         "$("$JQ" '.categories | length' "$ENTRIES") -> $(( $("$JQ" '.categories | length' "$ENTRIES") + 1 )) categories)"
    restart_note
    note "not changed: which wallpaper is selected (pick \"$TITLE\" yourself in System Settings › Wallpaper)"

    if ((dry_run)); then
        echo
        echo "Dry run: nothing was changed."
        return 0
    fi
    confirm

    local work
    work="$(mktemp -d -t startorch-aerials)"
    trap 'rm -rf "$work"' EXIT
    qlmanage -t -s 1280 -o "$work" "$video" >/dev/null 2>&1 || true
    local thumb="$work/$(basename "$video").png"
    [[ -s "$thumb" ]] || die "couldn't make a thumbnail with qlmanage; nothing was changed"

    mkdir -p "$backup"
    cp -p "$ENTRIES" "$backup/entries.json"
    local sha_before
    sha_before="$(sha256 "$ENTRIES")"

    mkdir -p "$STORE/videos" "$STORE/thumbnails"
    cp "$video" "$STORE/videos/.$ASSET_ID.mov.startorch-tmp"
    mv -f "$STORE/videos/.$ASSET_ID.mov.startorch-tmp" "$VIDEO_TARGET"
    xattr -w SourceURL "$video_url" "$VIDEO_TARGET"
    for t in "$THUMB_TARGET" "$SUBTHUMB_TARGET"; do
        cp "$thumb" "$t.startorch-tmp"
        mv -f "$t.startorch-tmp" "$t"
    done

    "$JQ" -S --arg aid "$ASSET_ID" --arg cid "$CATEGORY_ID" --arg sid "$SUBCATEGORY_ID" \
        --arg title "$TITLE" --arg url "$video_url" --arg thumb "$thumb_url" '
        .assets |= (map(select(.id != $aid)) + [{
            accessibilityLabel: $title, categories: [$cid], id: $aid, includeInShuffle: false,
            localizedNameKey: $title, pointsOfInterest: {}, preferredOrder: 0, previewImage: $thumb,
            shotID: ("STARTORCH_" + $aid[0:8]), showInTopLevel: true, subcategories: [$sid],
            "url-4K-SDR-240FPS": $url
        }])
        | .categories |= (map(select(.id != $cid)) as $c | $c + [{
            id: $cid, localizedDescriptionKey: $title, localizedNameKey: $title,
            preferredOrder: (([$c[].preferredOrder] | max // -1) + 1), previewImage: $thumb,
            representativeAssetID: $aid,
            subcategories: [{
                id: $sid, localizedDescriptionKey: $title, localizedNameKey: $title,
                preferredOrder: 0, previewImage: $thumb, representativeAssetID: $aid
            }]
        }])' "$ENTRIES" > "$work/entries.json"
    "$JQ" -e --arg a "$ASSET_ID" 'any(.assets[]; .id == $a)' "$work/entries.json" >/dev/null \
        || die "the edited manifest failed validation; entries.json was not changed (media files were; run revert)"
    cp "$work/entries.json" "$ENTRIES.startorch-tmp"
    mv -f "$ENTRIES.startorch-tmp" "$ENTRIES"

    cat > "$backup/install.env" <<EOF
STORE_ROOT='$STORE'
ENTRIES_SHA_BEFORE='$sha_before'
ENTRIES_SHA_AFTER='$(sha256 "$ENTRIES")'
TAR_ETAG='$(xattr_or_none LastETag "$TAR")'
TAR_MTIME='$(mtime "$TAR" 2>/dev/null || echo 0)'
VIDEO_SIZE='$(fsize "$VIDEO_TARGET")'
EOF
    echo "Applied. Backup: $backup"
    restart_wallpaper
    echo
    echo "Next: System Settings › Wallpaper › Aerials › \"$TITLE\" and pick it (also 'Show on all Spaces')."
}

cmd_revert() {
    local dry_run=0
    if [[ "${1:-}" == "--dry-run" ]]; then dry_run=1; fi
    require_tools
    local backup
    backup="$(latest_backup)"
    [[ -n "$backup" ]] || die "no active install recorded under $BACKUP_ROOT; nothing to revert"
    # shellcheck disable=SC1091
    source "$backup/install.env"
    [[ "$STORE_ROOT" == "$STORE" ]] || die "that install was for $STORE_ROOT, not $STORE"

    local current_sha="" manifest_action
    [[ -f "$ENTRIES" ]] && current_sha="$(sha256 "$ENTRIES")"
    if [[ "$current_sha" == "$ENTRIES_SHA_AFTER" ]]; then
        manifest_action="restore"
    elif ours_in_manifest; then
        manifest_action="strip"
    else
        manifest_action="keep"
    fi

    echo "Plan (undoing $backup):"
    case "$manifest_action" in
        restore) note "restore  $ENTRIES from $backup/entries.json (byte for byte, with its dates and xattrs)" ;;
        strip)   note "edit     $ENTRIES: macOS replaced it since apply; remove only our asset and category" ;;
        keep)    note "keep     $ENTRIES: macOS already replaced it and our entries are gone" ;;
    esac
    for t in "$VIDEO_TARGET" "$THUMB_TARGET" "$SUBTHUMB_TARGET"; do
        [[ -e "$t" ]] && note "delete   $t" || note "(already gone) $t"
    done
    restart_note
    note "If \"$TITLE\" is still selected, macOS falls back to its default Aerial."

    if ((dry_run)); then
        echo
        echo "Dry run: nothing was changed."
        return 0
    fi
    confirm

    case "$manifest_action" in
        restore)
            cp -p "$backup/entries.json" "$ENTRIES.startorch-tmp"
            mv -f "$ENTRIES.startorch-tmp" "$ENTRIES"
            ;;
        strip)
            "$JQ" -S --arg a "$ASSET_ID" --arg c "$CATEGORY_ID" \
                '.assets |= map(select(.id != $a)) | .categories |= map(select(.id != $c))' \
                "$ENTRIES" > "$ENTRIES.startorch-tmp"
            mv -f "$ENTRIES.startorch-tmp" "$ENTRIES"
            ;;
        keep) ;;
    esac
    rm -f "$VIDEO_TARGET" "$THUMB_TARGET" "$SUBTHUMB_TARGET"
    touch "$backup/REVERTED"
    echo "Reverted. The backup stays in $backup."
    restart_wallpaper
}

case "${1:-}" in
    status) shift; cmd_status "$@" ;;
    apply)  shift; cmd_apply "$@" ;;
    revert) shift; cmd_revert "$@" ;;
    *) echo "usage: $0 status | apply [--dry-run] <video> | revert [--dry-run]" >&2; exit 2 ;;
esac
