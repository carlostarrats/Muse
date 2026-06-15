#!/usr/bin/env bash
#
# make-dmg-background.sh — (re)build the Retina DMG background TIFF.
#
# Takes dmg/dmg-background.jpg (the 1200x800 source artwork) and produces
# dmg/dmg-background.tiff: a multi-resolution image holding a 600x400 @1x rep
# (72 dpi) and a 1200x800 @2x rep (144 dpi). Both map to 600x400 POINTS, so
# Finder shows the DMG background at 600x400 points — crisp on Retina, never
# cropped. Run this after changing the source art.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/dmg/dmg-background.jpg"
OUT="$REPO_ROOT/dmg/dmg-background.tiff"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

[[ -f "$SRC" ]] || { echo "error: source not found at $SRC" >&2; exit 1; }

# -z takes height then width; force the dpi so the point sizes match (600x400).
sips -s format png -z 400 600  -s dpiHeight 72  -s dpiWidth 72  "$SRC" --out "$TMP/bg-1x.png" >/dev/null
sips -s format png -z 800 1200 -s dpiHeight 144 -s dpiWidth 144 "$SRC" --out "$TMP/bg-2x.png" >/dev/null

tiffutil -cathidpicheck "$TMP/bg-1x.png" "$TMP/bg-2x.png" -out "$OUT"
echo "built: $OUT"
