#!/usr/bin/env bash
#
# release.sh — cut a Muse release in one command.
#
# Does the whole direct-distribution pipeline:
#   archive (Developer ID) → notarize+staple the app → build the DMG with the
#   drag-to-Applications background → notarize+staple the DMG → EdDSA-sign the
#   update → generate the Sparkle appcast.
#
# It does NOT publish to GitHub by default (that step is public + irreversible).
# It prints the exact `gh release create` command to run, or pass --publish to
# have it run that for you.
#
# Usage:
#   scripts/release.sh <version> [--publish]
#   scripts/release.sh 1.0.1
#   scripts/release.sh 1.0.1 --publish
#
# One-time setup (see docs/RELEASING.md):
#   - "Developer ID Application" certificate in Xcode ▸ Settings ▸ Accounts
#   - notarytool credentials saved as a profile (default name: muse-notary):
#       xcrun notarytool store-credentials muse-notary \
#         --apple-id "carlostarrats@icloud.com" --team-id "TV4QZT7A7X"
#   - brew install create-dmg

set -euo pipefail

# ---- args -------------------------------------------------------------------
VERSION="${1:-}"
PUBLISH="no"
[[ "${2:-}" == "--publish" ]] && PUBLISH="yes"
if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/release.sh <version> [--publish]   (e.g. 1.0.1)" >&2
  exit 1
fi

# ---- config -----------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

TAG="v$VERSION"
BUILD="$(git rev-list --count HEAD)"          # monotonic CFBundleVersion
TEAM_ID="TV4QZT7A7X"
NOTARY_PROFILE="${NOTARY_PROFILE:-muse-notary}"
REPO_SLUG="carlostarrats/Muse"
PROJECT="Muse/Muse.xcodeproj"
SCHEME="Muse"

BUILD_DIR="$REPO_ROOT/build"
ARCHIVE="$BUILD_DIR/Muse.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
REL_DIR="$BUILD_DIR/releases"
APP="$EXPORT_DIR/Muse.app"
DMG="$REL_DIR/Muse-$VERSION.dmg"

echo "▸ Releasing Muse $VERSION  (tag $TAG, build $BUILD)"

# ---- preflight --------------------------------------------------------------
command -v create-dmg >/dev/null 2>&1 || { echo "✗ create-dmg missing — brew install create-dmg" >&2; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "✗ notary profile '$NOTARY_PROFILE' not found — see one-time setup in this script's header" >&2; exit 1; }

SPARKLE_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData"/Muse-*/SourcePackages/artifacts/sparkle/Sparkle/bin -maxdepth 1 -name sign_update 2>/dev/null | head -1)"
SPARKLE_BIN="$(dirname "${SPARKLE_BIN:-/nonexistent}")"
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || { echo "✗ Sparkle tools not found — open the project in Xcode once to resolve packages" >&2; exit 1; }

rm -rf "$ARCHIVE" "$EXPORT_DIR" "$DMG"
mkdir -p "$REL_DIR"

# Submit to Apple and FAIL if the result isn't "Accepted". notarytool exits 0
# even when a submission comes back "Invalid", so we must inspect the status
# and dump the rejection log ourselves — otherwise the pipeline limps onward
# and stapling fails with a confusing "ticket not found".
notarize() {
  local target="$1" out id
  out="$(xcrun notarytool submit "$target" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
  echo "$out"
  if ! grep -q "status: Accepted" <<<"$out"; then
    id="$(grep -m1 ' id:' <<<"$out" | awk '{print $2}')"
    echo "✗ Notarization NOT accepted for $target" >&2
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
    return 1
  fi
}

# stapler can fail with "ticket not ready" right after a successful notarization
# — Apple's CDN needs a moment to publish it. Retry a few times before giving up.
staple_retry() {
  local target="$1" i
  for i in 1 2 3 4 5 6 7 8; do
    if xcrun stapler staple "$target"; then return 0; fi
    echo "  ticket not ready, retrying in 30s ($i/8)…"
    sleep 30
  done
  echo "✗ stapling failed for $target after retries" >&2
  return 1
}

# ---- 1. archive (Developer ID, versioned) ----------------------------------
echo "▸ Archiving…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  ENABLE_HARDENED_RUNTIME=YES \
  archive

# ---- 2. export with Developer ID -------------------------------------------
echo "▸ Exporting (Developer ID)…"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

# ---- 3. notarize + staple the app ------------------------------------------
echo "▸ Notarizing app…"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/Muse-app.zip"
notarize "$BUILD_DIR/Muse-app.zip"
staple_retry "$APP"

# ---- 4. build the DMG (drag-to-Applications background) --------------------
echo "▸ Building DMG…"
"$REPO_ROOT/scripts/make-dmg.sh" "$APP" "$DMG"

# ---- 5. notarize + staple the DMG ------------------------------------------
echo "▸ Notarizing DMG…"
notarize "$DMG"
staple_retry "$DMG"

# ---- 6. sign update + generate appcast -------------------------------------
echo "▸ Signing update + writing appcast…"
# Keep ONLY this release's DMG in the appcast dir before generating. GitHub
# hosts each version's assets under its own tag, so a single download-url-prefix
# can't address older versions — and cross-tag deltas would 404. One DMG in →
# one correct item out (full-download updates; no deltas).
find "$REL_DIR" -maxdepth 1 \( -name '*.dmg' -o -name '*.delta' -o -name 'appcast.xml' \) \
  ! -name "$(basename "$DMG")" -delete
"$SPARKLE_BIN/generate_appcast" --maximum-deltas 0 "$REL_DIR" \
  --download-url-prefix "https://github.com/$REPO_SLUG/releases/download/$TAG/"

echo "✓ Built: $DMG"
echo "✓ Appcast: $REL_DIR/appcast.xml"

# ---- 7. publish (opt-in) ----------------------------------------------------
GH_CMD=(gh release create "$TAG" "$DMG" "$REL_DIR/appcast.xml" --title "Muse $VERSION" --notes "Muse $VERSION")
if [[ "$PUBLISH" == "yes" ]]; then
  echo "▸ Publishing to GitHub…"
  "${GH_CMD[@]}"
  echo "✓ Published $TAG"
  # Keep the README download links pointed at this version's asset
  # (the latest/download/<asset> URL is version-pinned by filename).
  if grep -q 'releases/latest/download/Muse-[0-9][0-9.]*\.dmg' "$REPO_ROOT/README.md" 2>/dev/null; then
    sed -i '' "s#releases/latest/download/Muse-[0-9][0-9.]*\.dmg#releases/latest/download/Muse-$VERSION.dmg#g" "$REPO_ROOT/README.md"
    echo "  ↪ Updated README download links to Muse-$VERSION.dmg — commit README.md."
  fi
  echo "  Verify: curl -L https://github.com/$REPO_SLUG/releases/latest/download/appcast.xml"
else
  echo
  echo "Not published yet. To publish, run:"
  printf '  %q ' "${GH_CMD[@]}"; echo
  echo "(or re-run with --publish)"
fi
