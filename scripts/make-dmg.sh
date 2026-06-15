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
# The window is sized to the 1200x800 background so the artwork maps 1:1.
# Muse.app sits on the left; the Applications drop-link on the right; the
# user drags one onto the other.

set -euo pipefail

APP="${1:?usage: make-dmg.sh <path-to-Muse.app> [output.dmg]}"
OUT="${2:-build/Muse.dmg}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BG="$REPO_ROOT/dmg/dmg-background.jpg"

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
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"

create-dmg \
  --volname "Muse" \
  --background "$BG" \
  --window-pos 200 120 \
  --window-size 1200 800 \
  --icon-size 128 \
  --icon "Muse.app" 330 400 \
  --app-drop-link 870 400 \
  --hide-extension "Muse.app" \
  --no-internet-enable \
  "$OUT" \
  "$STAGE"

echo "built: $OUT"
