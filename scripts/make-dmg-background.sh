#!/usr/bin/env bash
#
# make-dmg-background.sh — (re)build the DMG background image.
#
# Produces dmg/dmg-background.png at exactly 600x400 PIXELS, 72 dpi.
#
# Why a single 600x400 @72dpi PNG (not a HiDPI TIFF):
#   Finder does NOT scale a DMG background and does NOT reliably honor a HiDPI
#   multi-representation TIFF — it draws the image 1:1 pixels->points, anchored
#   top-left. A 1200x800 image (or a @2x TIFF) renders double-size and crops the
#   bottom; a 600x400 @72dpi image fills the 600x400 window exactly. The source
#   art is 144 dpi, so dpi MUST be forced to 72 — otherwise a 600x400-pixel
#   image reports as 300x200 POINTS and only covers the corner. Slightly soft on
#   Retina — acceptable. Run this after changing the source art.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/dmg/dmg-background.jpg"
OUT="$REPO_ROOT/dmg/dmg-background.png"

[[ -f "$SRC" ]] || { echo "error: source not found at $SRC" >&2; exit 1; }

# -z is HEIGHT then WIDTH; force 72 dpi so pixels map 1:1 to points.
sips -s format png -z 400 600 -s dpiHeight 72 -s dpiWidth 72 "$SRC" --out "$OUT" >/dev/null
echo "built: $OUT (600x400, 72 dpi)"
