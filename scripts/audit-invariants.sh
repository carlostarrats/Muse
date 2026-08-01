#!/bin/bash
#
#  audit-invariants.sh — the durable constraints that a machine can check.
#
#  WHY THIS EXISTS
#  ---------------
#  Six review rounds on `new-product-build-1` each found real bugs, and each
#  found them by running a lens the previous rounds hadn't. That works, but it
#  never terminates: the lens space is unbounded, so "review until green" has no
#  exit criterion and the same classes get rediscovered by whoever remembers to
#  look. A large share of what those rounds found is not insight — it is
#  mechanically detectable. This script is that share, moved out of human memory
#  and `docs/durable-constraints.md` prose and into something that fails.
#
#  Every check below is a rule that was broken ONCE, shipped, and cost a
#  session. The comment on each names the bug so nobody deletes a check they
#  think is theoretical.
#
#  WHY A SHELL SCRIPT AND NOT AN XCTEST
#  ------------------------------------
#  `EditingModuleImportTests` already tries this as a grep test and SKIPS on
#  this machine: the test host is the sandboxed app, and the checkout lives in
#  ~/Documents, which the sandbox denies without user selection. A source-tree
#  check that lives in the suite therefore passes vacuously exactly where it is
#  needed. A shell script has no sandbox. Run it from the repo root.
#
#  THE RATCHET PATTERN
#  -------------------
#  Most checks are allowlists, not bans. The listed sites were read on the date
#  given and are correct for the reason given. A NEW site trips the check and
#  stays tripped until someone adds it WITH a reason — which forces the same
#  thinking the original review did, at the moment the code is written rather
#  than six rounds later.
#
#  Usage:  ./scripts/audit-invariants.sh          (from the repo root)
#  Exit:   0 = all green, 1 = at least one violation.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
SRC="Muse/Muse"

if [ ! -d "$SRC" ]; then
    echo "error: run from the repo root (expected $SRC/)" >&2
    exit 1
fi

FAILURES=0
CHECKS=0

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }

# Report a check's outcome. $1 = id, $2 = description, $3 = violations (may be
# empty). A check with no violations prints one green line; a failing one prints
# the offending lines and the rule they broke.
report() {
    local id="$1" desc="$2" violations="$3" rule="${4:-}"
    CHECKS=$((CHECKS + 1))
    if [ -z "$violations" ]; then
        green "  PASS  $id — $desc"
    else
        FAILURES=$((FAILURES + 1))
        red   "  FAIL  $id — $desc"
        [ -n "$rule" ] && dim "        rule: $rule"
        while IFS= read -r line; do
            [ -n "$line" ] && echo "          $line"
        done <<< "$violations"
    fi
}

# Grep the app source with comments stripped, so a rule that is DISCUSSED in a
# comment is not reported as a rule that is BROKEN in code. This is not
# cosmetic: the first draft of this script flagged ViewerInfoColumn.swift for
# URLSession, in a comment that exists to say the app never uses URLSession
# there. A checker that cries wolf gets ignored, and an ignored checker is
# worse than none.
scan() {
    local pattern="$1"
    shift
    grep -rn --include='*.swift' -E "$pattern" "$@" 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+: *//' \
        | grep -vE '^[^:]+:[0-9]+: *\*' \
        | grep -vE '^[^:]+:[0-9]+: */// '
}

# Filter a scan result down to files NOT on an allowlist.
# $1 = scan output, $2..$n = allowed path fragments.
not_allowed() {
    local input="$1"; shift
    local out="$input"
    for allowed in "$@"; do
        out="$(printf '%s\n' "$out" | grep -vF "$allowed")"
    done
    printf '%s' "$out"
}

echo
echo "Muse invariant audit — $(date '+%Y-%m-%d %H:%M')"
echo "======================================================================"
echo
echo "Network egress & viewer security"
echo "----------------------------------------------------------------------"

# ---------------------------------------------------------------------------
# AV-1 — every AVFoundation asset goes through the reference-restricted helper.
#
# THE BUG: a QuickTime reference movie (`rmra`/`rdrf` remote data-ref atom) or
# an HLS playlist points a track at a remote URL. Without
# AVURLAssetReferenceRestrictionsKey = .forbidAll, AVFoundation resolves it on
# open and beacons the viewer's IP. Video assets open on mere FOLDER OPEN
# (thumbnail prewarm), so a planted file leaks with no click at all.
# ---------------------------------------------------------------------------
v="$(scan 'AVURLAsset\(url:|AVPlayer\(url:' "$SRC")"
v="$(not_allowed "$v" "AVURLAsset+NoNetwork.swift")"
report "AV-1" "no bare AVURLAsset(url:)/AVPlayer(url:)" "$v" \
    "build every asset via AVURLAsset.noNetwork(url:) / AVPlayer.noNetwork(url:)"

# ---------------------------------------------------------------------------
# AV-2 — no video or audio file may reach QuickLook.
#
# THE BUG: QuickLook's out-of-process AVFoundation is UNRESTRICTED, so handing
# it a file re-opens the exact egress .noNetwork closes. The rule originally
# stopped at .video; .m4a is the same ISO-BMFF container and fell through both
# thumbnail paths until 2026-07-28. Enforced in code by
# ThumbnailCache.mayUseQuickLook — this check guards the ENTRY POINTS, so a new
# file touching QuickLook has to prove it consults that predicate.
# ---------------------------------------------------------------------------
v="$(scan 'QLThumbnailGenerator|QLPreviewView' "$SRC")"
v="$(not_allowed "$v" \
    "Filesystem/ThumbnailCache.swift" \
    "Export/CollectionPDFExporter.swift" \
    "Views/QuickLookFallback.swift" \
    "Views/Viewer/HeroStage.swift")"
report "AV-2" "QuickLook confined to the four reviewed entry points" "$v" \
    "a new QuickLook site must consult ThumbnailCache.mayUseQuickLook (video AND audio excluded)"

# ---------------------------------------------------------------------------
# NET-1 — the app has exactly four sanctioned network paths.
#
# Sparkle (appcast + update), the Google Drive share, announcements.json, and
# the on-demand CLIP model download. Everything else opening a socket is a
# privacy-policy violation, not a bug: the shipping claim is "Data Not
# Collected".
# ---------------------------------------------------------------------------
v="$(scan 'URLSession' "$SRC")"
v="$(not_allowed "$v" \
    "Sharing/Drive/" \
    "Commerce/AnnouncementStore.swift" \
    "Intelligence/Clip/ClipModelStore.swift" \
    "Networking/BoundedBody.swift")"
report "NET-1" "URLSession confined to the four sanctioned paths" "$v" \
    "no new network path; see CLAUDE.md network policy (Data Not Collected)"

# ---------------------------------------------------------------------------
# NET-2 — a remote body is bounded BEFORE it is in memory.
#
# THE BUG (round 4, R4-3): AnnouncementFeed.parse guarded maxPayloadBytes, but
# URLSession.data(for:) buffers the whole body first — so the SERVER chose the
# allocation and the cap only decided whether to parse what had already landed.
# This is the app's only automatic, non-user-initiated fetch, at every launch.
# The fix (Networking/BoundedBody) rejects a declared-oversize Content-Length
# before reading a byte and enforces a streaming tally when the header lies.
#
# Round 6 (R6-1) then found the same hole one leg over: the CLIP model's
# PAYLOAD download, measured in hundreds of MB, had no ceiling at all. It uses
# session.download(for:) — spooled to disk, so RAM stays flat — which is why
# that spelling counts as bounded here.
# ---------------------------------------------------------------------------
#
# Sharing/Drive/ is a DELIBERATE exclusion, not an oversight (reviewed
# 2026-08-01). The announcements reasoning does not transfer: those calls are
# OAuth-authenticated, user-initiated, TLS to googleapis.com, and return small
# JSON metadata. For one of those bodies to be hostile, Google's API would have
# to be compromised or TLS broken — at which point an unbounded JSON parse is
# not the exposure that matters. Weigh that against the cost: BoundedBody reads
# one BYTE at a time, which is right for a 16 KB feed and was already backed
# out once (R6-4) as a throughput regression on anything larger. If Drive is
# ever bounded, chunk BoundedBody first.
unbounded=""
for f in $(grep -rl --include='*.swift' 'URLSession' "$SRC" 2>/dev/null); do
    case "$f" in
        *BoundedBody.swift) continue ;;
        *ViewerInfoColumn.swift) continue ;;   # comment-only mention
        */Sharing/Drive/*) continue ;;         # see the note above
    esac
    # A file that buffers a body whole must reference the bounded reader or the
    # spooling download API.
    if scan '\.data\(for:|\.data\(from:' "$f" | grep -q .; then
        if ! grep -qE 'BoundedBody|boundedData|download\(for:' "$f"; then
            unbounded="$unbounded$f: buffers a response body with no ceiling"$'\n'
        fi
    fi
done
report "NET-2" "every remote body is bounded before it lands in memory" "$unbounded" \
    "route through Networking/BoundedBody, or session.download(for:) for large payloads"

# ---------------------------------------------------------------------------
# NET-3 — Drive OAuth stays least-privilege and secretless.
#
# PKCE with no client secret; scope EXACTLY drive.file so Muse can only ever
# see files it created. A broader scope or an embedded secret is a shipped
# credential leak in a distributed binary.
# ---------------------------------------------------------------------------
v=""
if ! grep -q 'auth/drive.file"' "$SRC/Sharing/Drive/DriveConfig.swift" 2>/dev/null; then
    v="DriveConfig.scope is no longer exactly drive.file"
fi
secret="$(scan 'client_secret|clientSecret' "$SRC/Sharing/Drive/")"
[ -n "$secret" ] && v="$v"$'\n'"$secret"
broad="$(scan 'auth/drive[^.]|auth/drive"' "$SRC/Sharing/Drive/")"
[ -n "$broad" ] && v="$v"$'\n'"$broad"
report "NET-3" "Drive OAuth is PKCE, secretless, scoped to drive.file" "$(printf '%s' "$v" | sed '/^$/d')" \
    "never widen the scope, never embed a client secret in a distributed binary"

echo
echo "Crash-safety on user-supplied numbers"
echo "----------------------------------------------------------------------"

# ---------------------------------------------------------------------------
# INT-1 — Int(_:) on a number a FILE declared.
#
# THE BUG (round 6, R6-2): Int(_:) traps on NaN, on infinity, and past Int.max.
# Round 4 swept for try!/fatalError/unchecked subscripts and found none — a
# genuinely clean result at the wrong door, because Int(_:) is none of those and
# takes the process down just as hard. Five sites, most in the Info card, which
# loads on hero open: a corrupt or crafted movie crashed the app on SELECTING a
# file. Reproduced at runtime, exit 133.
#
# `Int(x.rounded())` is the exact shape of the trap and a near-zero-false-
# positive signal — a value you rounded is a value you did not bound.
# Int(exactly:) returns nil instead, which is what a garbage header means.
# ---------------------------------------------------------------------------
v="$(scan 'Int\([^)]*\.rounded\(\)|Int32\([^)]*\.rounded\(\)|Int64\([^)]*\.rounded\(\)|UInt\([^)]*\.rounded\(\)' "$SRC" \
    | grep -v 'exactly:')"
# GridView's slider binding is bounded by the Slider's own range, not by a file.
v="$(not_allowed "$v" "Views/GridView.swift")"
report "INT-1" "no Int(x.rounded()) on file-declared numbers" "$v" \
    "use Int(exactly:) and treat nil as 'no value'; guard .isFinite first"

echo
echo "Destructive operations"
echo "----------------------------------------------------------------------"

# ---------------------------------------------------------------------------
# DEL-1 — user files are moved to Trash, never unlinked.
#
# The product rule: Muse never destroys a user's file. Every listed site below
# was read and operates on a TEMP or CACHE path Muse itself created — not on
# anything the user owns. A new removeItem/unlink has to earn its place here.
# ---------------------------------------------------------------------------
v="$(scan 'removeItem\(at:|removeItem\(atPath:|\bunlink\(' "$SRC")"
v="$(not_allowed "$v" \
    "Intelligence/Clip/ClipModelStore.swift" \
    "Editing/EditCopyFlow.swift" \
    "Filesystem/ThumbnailCache.swift" \
    "Export/OutputRender.swift" \
    "Export/CollectionPDFExporter.swift" \
    "Views/CollectionPDFSave.swift" \
    "Components/PhaseTrace.swift")"
report "DEL-1" "removeItem/unlink confined to Muse's own temp+cache paths" "$v" \
    "user files go to Trash via NSWorkspace.shared.recycle — never unlink"

# ---------------------------------------------------------------------------
# OUT-1 — everything that leaves the app goes through OutputRender.
#
# RenderedOutput's fileprivate init IS the enforcement: a new export, share or
# publish path physically cannot compile without going through the choke point,
# which is where Spec 04 renders the edit stack. A public init silently
# reintroduces "shares the unedited original".
# ---------------------------------------------------------------------------
v=""
if ! grep -q 'fileprivate init(url: URL' "$SRC/Export/OutputRender.swift" 2>/dev/null; then
    v="RenderedOutput's init is no longer fileprivate — the choke point is open"
fi
report "OUT-1" "RenderedOutput's init stays fileprivate" "$v" \
    "the fileprivate init is the enforcement; never add a public one"

echo
echo "Decode bounds"
echo "----------------------------------------------------------------------"

# ---------------------------------------------------------------------------
# DEC-1 — every automatic full-raster decode is bounded.
#
# THE BUG: a few-KB PNG can declare 40000x40000 (~1.6 Gpx). Formats ImageIO
# cannot stream-downsample (PNG/TIFF/BMP) materialize the whole raster, so the
# app OOMs on FOLDER OPEN (prewarm) or on index (auto-tag) — no click required.
# withinDecodeBudget is a header-only pre-check.
# ---------------------------------------------------------------------------
v=""
for f in $(grep -rl --include='*.swift' 'CGImageSourceCreateImageAtIndex' "$SRC" 2>/dev/null); do
    if ! grep -qE 'withinDecodeBudget|BoundedRead|boundedDecode' "$f"; then
        v="$v$f: full-raster decode with no budget guard"$'\n'
    fi
done
report "DEC-1" "every CGImageSourceCreateImageAtIndex site guards its budget" "$v" \
    "call ThumbnailCache.withinDecodeBudget(src) before any automatic full decode"

echo
echo "Build & platform integrity"
echo "----------------------------------------------------------------------"

# ---------------------------------------------------------------------------
# ENT-1 — Debug builds must not touch the production iCloud container.
#
# THE BUG: dev churn under the production ubiquity container lets `bird` purge
# real user data. Debug signs with Muse-Debug.entitlements = production minus
# the three iCloud keys. This is a data-loss guard, not hygiene.
# ---------------------------------------------------------------------------
# Match declared KEYS only. The file's header comment explains at length that
# iCloud is deliberately omitted, and a naive content grep reports that
# explanation as the violation it is warning about.
v="$(grep -in '<key>' "Muse/Muse/Muse-Debug.entitlements" 2>/dev/null \
    | grep -i 'icloud\|ubiquity')"
report "ENT-1" "Muse-Debug.entitlements carries no iCloud keys" "$v" \
    "Debug must never mount the production ubiquity container"

# ---------------------------------------------------------------------------
# EDIT-1 — Editing/ stays platform-neutral.
#
# The render pipeline and edit model must move to iOS unchanged. SwiftUI counts
# as a violation because it pulls AppKit in transitively on macOS. This is the
# check EditingModuleImportTests tries to run and SKIPS on a ~/Documents
# checkout — here it actually runs.
# ---------------------------------------------------------------------------
v="$(grep -rn --include='*.swift' -E '^\s*import\s+(AppKit|SwiftUI)' "$SRC/Editing" 2>/dev/null)"
report "EDIT-1" "Editing/ imports neither AppKit nor SwiftUI" "$v" \
    "the platform-neutral core must stay portable to iOS"

# ---------------------------------------------------------------------------
# ARCH-1 — the build stays universal.
#
# THE BUG: ClipVectors' Float16 made x86_64 uncompilable (commit 6d5246e).
# Intel Macs must keep working; a Debug build compiles only the active arch, so
# arch-specific code is invisible until a Release build on the other side.
# ---------------------------------------------------------------------------
#
# LINE-accurate, not file-accurate. A file-level "does this file mention
# #if arch(arm64) anywhere" test would pass the very regression it exists to
# catch: ClipVectors already has two correctly-guarded uses, so a THIRD,
# unguarded one in the same file would inherit their alibi. The awk below
# tracks the arm64 branch it is actually standing in.
#
# This does not replace building for both arches — it catches the mistake at
# edit time. `xcodebuild -configuration Release` is still the real gate,
# because a Debug build compiles only the active arch and hides this entirely.
v=""
for f in $(grep -rl --include='*.swift' 'Float16' "$SRC" 2>/dev/null); do
    unguarded="$(awk '
        /^[[:space:]]*#if[[:space:]]+arch\(arm64\)/ { depth++; inarm=1; next }
        /^[[:space:]]*#else/                        { if (depth > 0) inarm=0; next }
        /^[[:space:]]*#endif/                       { if (depth > 0) { depth--; inarm=0 }; next }
        /Float16/ {
            if (inarm) next
            line=$0
            sub(/^[[:space:]]+/, "", line)
            if (line ~ /^\/\// || line ~ /^\*/) next     # a comment about the rule
            printf "%s:%d: %s\n", FILENAME, FNR, line
        }
    ' "$f")"
    [ -n "$unguarded" ] && v="$v$unguarded"$'\n'
done
report "ARCH-1" "Float16 stays inside an #if arch(arm64) branch (Intel must compile)" "$(printf '%s' "$v" | sed '/^$/d')" \
    "x86_64 has no Float16; keep it in the arm64 branch with a portable #else"

echo
echo "======================================================================"
if [ "$FAILURES" -eq 0 ]; then
    green "$CHECKS checks, all green."
    echo
    exit 0
else
    red "$CHECKS checks, $FAILURES FAILED."
    echo
    dim "Each failure above is a rule that was broken once, shipped, and cost a"
    dim "session. Fix the code, or — if the new site is genuinely correct — add"
    dim "it to that check's allowlist WITH the reason it is safe."
    echo
    exit 1
fi
