#!/usr/bin/env bash
#
# make-dmg.sh — build the Muse installer DMG with the drag-to-Applications
# background. Run AFTER you have a signed (Developer ID) Muse.app.
#
# Requires: create-dmg  (brew install create-dmg)
#
# Usage:
#   scripts/make-dmg.sh <path-to-Muse.app> [output.dmg]
#
# Example:
#   scripts/make-dmg.sh build/export/Muse.app build/Muse-1.0.1.dmg
#
# The window is 600x400 POINTS; the 1200x800 background is the @2x (Retina)
# asset, so it renders crisp and at the right size. Icon coordinates are in
# the 600x400 point space. Muse.app sits on the left; the Applications
# drop-link on the right; the user drags one onto the other.

set -euo pipefail

APP="${1:?usage: make-dmg.sh <path-to-Muse.app> [output.dmg]}"
OUT="${2:-build/Muse.dmg}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Multi-resolution TIFF (600x400 @1x + 1200x800 @2x) so Finder renders the
# background at 600x400 points, crisp on Retina, with no cropping. Rebuild it
# from dmg/dmg-background.jpg with scripts/make-dmg-background.sh.
BG="$REPO_ROOT/dmg/dmg-background.png"

if [[ ! -d "$APP" ]]; then
  echo "error: app not found at '$APP'" >&2
  exit 1
fi
if [[ ! -f "$BG" ]]; then
  echo "error: background not found at '$BG'" >&2
  exit 1
fi
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "error: create-dmg not installed — run: brew install create-dmg" >&2
  exit 1
fi

# create-dmg refuses to overwrite; start clean.
rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"

# Stage only the app so the volume contains exactly Muse.app + Applications.
STAGE="$(mktemp -d)"
WRAP="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$WRAP"' EXIT
cp -R "$APP" "$STAGE/"

# create-dmg's bundled AppleScript template sets icon size / text size but NOT
# the label position, so on some systems Finder shows labels to the RIGHT of
# the icons (and runs "Applications" off the edge). We want labels BELOW the
# icons. create-dmg resolves its template from its own directory and treats a
# dir containing `.this-is-the-create-dmg-repo` as a source checkout, using a
# sibling `support/`. So we run a symlinked create-dmg from a temp dir whose
# `support/template.applescript` is patched with `set label position to bottom`
# — no global file is touched, and it works on any machine with create-dmg.
CDMG_REAL="$(readlink -f "$(command -v create-dmg)")"
CDMG_SUPPORT="$(dirname "$(dirname "$CDMG_REAL")")/share/create-dmg/support"
ln -s "$CDMG_REAL" "$WRAP/create-dmg"
touch "$WRAP/.this-is-the-create-dmg-repo"
cp -R "$CDMG_SUPPORT" "$WRAP/support"
# Insert the label-position line right after the text-size line in `tell opts`.
sed -i '' 's/\(set text size to TEXT_SIZE\)/\1\
			set label position to bottom/' "$WRAP/support/template.applescript"

"$WRAP/create-dmg" \
  --volname "Muse" \
  --background "$BG" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 128 \
  --icon "Muse.app" 165 170 \
  --app-drop-link 435 170 \
  --hide-extension "Muse.app" \
  --no-internet-enable \
  "$OUT" \
  "$STAGE"

echo "built: $OUT"
