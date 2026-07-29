# Release Notes in the Update Dialog — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When Sparkle offers a Muse update, the dialog shows what changed, in
user-facing language — sourced from the `docs/release-notes-<version>.md` file
that is already hand-written for every release.

**Architecture:** No app-side code. `scripts/release.sh` stages the existing
notes markdown next to the DMG under the basename `generate_appcast` looks for,
passes `--embed-release-notes` so the text lands inline in `appcast.xml` as
`<description sparkle:format="markdown">` (one appcast fetch, no second asset,
no second host), asserts the description actually landed, and feeds the same
file to `gh release create --notes-file`.

**Tech Stack:** bash, Sparkle 2.9.3 `generate_appcast`, `gh` CLI.

Spec: `docs/superpowers/specs/2026-07-28-update-release-notes-design.md`.

## Global Constraints

- **Sparkle is pinned at 2.9.3** (`Package.resolved`). `sparkle:format="markdown"`
  rendering requires 2.5+; producer and consumer come from the same resolved
  artifact. Do not special-case older Sparkle.
- **Embed, never link.** `generate_appcast` without `--embed-release-notes`
  emits `<sparkle:releaseNotesLink>` — a second network fetch to an asset that
  must be uploaded separately, blank-on-404. The app's network policy is one
  appcast fetch; keep it that way.
- **Notes basename must match the archive**: `Muse-$VERSION.dmg` ↔
  `Muse-$VERSION.md`. A mismatch is silent — no warning, just empty notes.
- **Fail before the expensive work.** Missing-notes detection belongs in the
  preflight block (line ~58), which runs before the ~20-minute archive +
  notarize round trip.
- **No silent degrade.** Every failure mode is a hard `exit 1` with a named
  cause. A silent degrade is the bug being fixed.
- Existing script style: `set -euo pipefail`, `▸` for progress, `✓` for
  success, `✗ … >&2` + `exit 1` for failure. Match it.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `scripts/release.sh` | The whole release pipeline | Modify — arg parsing, preflight, staging + prune, generate flags + assertion, publish |
| `docs/RELEASING.md` | Human checklist for cutting a release | Modify — add step 0, correct the wrong `Muse.html` guidance, record link-vs-embed |
| `docs/session-log.md` | Chronological narrative | Append a dated entry |

No test files: this is a release pipeline that archives, notarizes and hits the
network, so it cannot run under `xcodebuild test`. Verification is a scratch-dir
dry run per task, spelled out in each task's steps. That is a real limitation,
not an omission — the rendering check is owed at the next real release.

---

### Task 1: `--no-notes` flag and the missing-notes preflight

**Files:**
- Modify: `scripts/release.sh:29-31` (arg parsing), `scripts/release.sh:52-56`
  (config), `scripts/release.sh:58-65` (preflight)

**Interfaces:**
- Produces: `$NOTES_SRC` — absolute path to `docs/release-notes-$VERSION.md`;
  `$NOTES` — `"no"` when `--no-notes` was passed, else `"yes"`. Tasks 2 and 3
  read both.

- [ ] **Step 1: Replace the positional `--publish` check with a flag loop**

The current parsing only looks at `$2`, so `release.sh 1.5 --no-notes --publish`
would silently ignore `--publish`. Replace lines 29-31:

```bash
VERSION="${1:-}"
PUBLISH="no"
NOTES="yes"
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --publish)  PUBLISH="yes" ;;
    --no-notes) NOTES="no" ;;
    *) echo "✗ unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done
if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/release.sh <version> [--publish] [--no-notes]   (e.g. 1.0.1)" >&2
  exit 1
fi
```

Delete the old `if [[ -z "$VERSION" ]]` block that followed line 31 so it is
not duplicated.

- [ ] **Step 2: Define the notes path beside the other config**

After the `DMG=` line (~54):

```bash
NOTES_SRC="$REPO_ROOT/docs/release-notes-$VERSION.md"
```

- [ ] **Step 3: Add the preflight check**

In the preflight block, after the `create-dmg` check (~line 59):

```bash
if [[ "$NOTES" == "yes" && ! -f "$NOTES_SRC" ]]; then
  echo "✗ release notes missing: docs/release-notes-$VERSION.md" >&2
  echo "  Write them first (they appear in the Sparkle update dialog AND the" >&2
  echo "  GitHub release), or re-run with --no-notes to ship without notes." >&2
  exit 1
fi
[[ "$NOTES" == "no" ]] && echo "▸ --no-notes: this release will ship with an EMPTY update dialog"
```

- [ ] **Step 4: Verify the failure path**

Run: `cd "<repo>" && scripts/release.sh 9.9.9 2>&1 | head -5`
Expected: `✗ release notes missing: docs/release-notes-9.9.9.md`, exit 1, and
**no archive started** (no `▸ Archiving…` line).

- [ ] **Step 5: Verify the pass-through and flag-order paths**

Run: `bash -n scripts/release.sh` — expected: no output (syntax OK).
Run: `scripts/release.sh 1.4 --no-notes --publish 2>&1 | head -8`
Expected: the `--no-notes` warning line appears, preflight proceeds past the
notes check, and it reaches `▸ Archiving…` (interrupt with Ctrl-C once seen —
this confirms both flags parsed regardless of order).
Run: `scripts/release.sh 1.4 --bogus 2>&1 | head -2`
Expected: `✗ unknown option: --bogus`, exit 1.

- [ ] **Step 6: Commit**

```bash
git add scripts/release.sh
git commit -m "release: refuse to cut a release with no notes"
```

---

### Task 2: Stage the notes, embed them, assert they landed

**Files:**
- Modify: `scripts/release.sh:143-153` (the "sign update + generate appcast"
  step)

**Interfaces:**
- Consumes: `$NOTES`, `$NOTES_SRC` from Task 1.
- Produces: `$REL_DIR/Muse-$VERSION.md` on disk and a non-empty `<description>`
  in `$REL_DIR/appcast.xml`.

- [ ] **Step 1: Extend the prune to notes files**

The existing `find … -delete` keeps only the current DMG but ignores notes,
which is how a stale `Muse-1.3.3.html` survived in `build/releases/` into the
1.4 release. Replace the `find` command with:

```bash
find "$REL_DIR" -maxdepth 1 \
  \( -name '*.dmg' -o -name '*.delta' -o -name 'appcast.xml' -o -name '*.md' -o -name '*.html' \) \
  ! -name "$(basename "$DMG")" -delete
```

- [ ] **Step 2: Copy the notes into the appcast dir**

Immediately after the `find`, before `generate_appcast`:

```bash
# generate_appcast picks up a notes file whose basename matches the archive —
# Muse-1.4.dmg ↔ Muse-1.4.md. The match is silent when it fails, hence the
# assertion below.
if [[ "$NOTES" == "yes" ]]; then
  cp "$NOTES_SRC" "$REL_DIR/Muse-$VERSION.md"
fi
```

- [ ] **Step 3: Pass `--embed-release-notes`**

```bash
"$SPARKLE_BIN/generate_appcast" --maximum-deltas 0 --embed-release-notes "$REL_DIR" \
  --download-url-prefix "https://github.com/$REPO_SLUG/releases/download/$TAG/"
```

Without the flag this emits `<sparkle:releaseNotesLink>` pointing at a
separately-uploaded asset — a second fetch that is blank on 404. Verified
behavior, both forms, 2026-07-28.

- [ ] **Step 4: Assert the description actually landed**

After the `generate_appcast` call:

```bash
if [[ "$NOTES" == "yes" ]]; then
  if ! grep -q '<description' "$REL_DIR/appcast.xml"; then
    echo "✗ appcast has no <description> — the update dialog would be blank." >&2
    echo "  Check that $REL_DIR/Muse-$VERSION.md exists and matches the DMG basename." >&2
    exit 1
  fi
  echo "✓ Release notes embedded in the appcast"
fi
```

- [ ] **Step 5: Dry-run the staging + generate + assert logic in a scratch dir**

This exercises the real `generate_appcast` against the real 1.4 DMG without
cutting a release:

```bash
S=/private/tmp/release-notes-dryrun; rm -rf $S; mkdir -p $S
cp build/releases/Muse-1.4.dmg $S/
cp docs/release-notes-1.4.md $S/Muse-1.4.md
SB="$(dirname "$(find "$HOME/Library/Developer/Xcode/DerivedData"/Muse-*/SourcePackages/artifacts/sparkle/Sparkle/bin -maxdepth 1 -name generate_appcast | head -1)")"
"$SB/generate_appcast" --maximum-deltas 0 --embed-release-notes $S \
  --download-url-prefix "https://github.com/carlostarrats/Muse/releases/download/v1.4/"
grep -c '<description sparkle:format="markdown">' $S/appcast.xml
```

Expected: `1`. Then confirm the negative case — the assertion must fire when
the notes file is absent:

```bash
rm $S/appcast.xml $S/Muse-1.4.md
"$SB/generate_appcast" --maximum-deltas 0 --embed-release-notes $S \
  --download-url-prefix "https://github.com/carlostarrats/Muse/releases/download/v1.4/"
grep -q '<description' $S/appcast.xml && echo "UNEXPECTED: description present" || echo "OK: assertion would fire"
```

Expected: `OK: assertion would fire`. Clean up with `rm -rf $S`.

- [ ] **Step 6: Commit**

```bash
git add scripts/release.sh
git commit -m "release: embed the release notes in the appcast"
```

---

### Task 3: The GitHub release body uses the same file

**Files:**
- Modify: `scripts/release.sh:156` (the `GH_CMD` array)

**Interfaces:**
- Consumes: `$NOTES`, `$NOTES_SRC` from Task 1.

- [ ] **Step 1: Build the command with `--notes-file` when notes exist**

Replace the single-line `GH_CMD=(…)` with:

```bash
GH_CMD=(gh release create "$TAG" "$DMG" "$REL_DIR/appcast.xml" --title "Muse $VERSION")
if [[ "$NOTES" == "yes" ]]; then
  GH_CMD+=(--notes-file "$NOTES_SRC")
else
  GH_CMD+=(--notes "Muse $VERSION")
fi
```

The `--no-notes` branch keeps the old placeholder body so the release page is
never empty.

- [ ] **Step 2: Verify the printed command is correct and quotable**

The script prints the command with `printf '%q '` when not publishing. Run the
array construction in isolation:

```bash
VERSION=1.4 TAG=v1.4 NOTES=yes NOTES_SRC=docs/release-notes-1.4.md \
DMG=build/releases/Muse-1.4.dmg REL_DIR=build/releases bash -c '
GH_CMD=(gh release create "$TAG" "$DMG" "$REL_DIR/appcast.xml" --title "Muse $VERSION")
if [[ "$NOTES" == "yes" ]]; then GH_CMD+=(--notes-file "$NOTES_SRC"); else GH_CMD+=(--notes "Muse $VERSION"); fi
printf "%q " "${GH_CMD[@]}"; echo'
```

Expected: a single line ending `--title Muse\ 1.4 --notes-file docs/release-notes-1.4.md`.

Run: `bash -n scripts/release.sh` — expected: no output.

- [ ] **Step 3: Commit**

```bash
git add scripts/release.sh
git commit -m "release: use the release notes as the GitHub release body"
```

---

### Task 4: Correct and extend the release documentation

**Files:**
- Modify: `docs/RELEASING.md` (the "one command" section, per-release step
  list, step 4 aside, and Notes/gotchas)
- Modify: `docs/session-log.md` (append a dated entry)

- [ ] **Step 1: Add the notes step to the per-release checklist**

Insert a new step before "### 1. Bump the version", renumbering the steps that
follow:

```markdown
### 0. Write the release notes

Write `docs/release-notes-<version>.md` in user-facing language — what changed
and why it matters, not commit subjects. This one file is the *only* source
for both the Sparkle update dialog and the GitHub release body, so a release
cannot be cut without it (`release.sh` fails in preflight; `--no-notes`
deliberately opts out).
```

- [ ] **Step 2: Correct the wrong step-4 aside**

The current text is `(Add release notes by dropping a `Muse.html` next to the
DMG, or edit the generated `<description>`.)` — the basename never matches, and
it is why 1.4 shipped with a blank dialog. Replace it with:

```markdown
`release.sh` copies `docs/release-notes-<version>.md` to
`build/releases/Muse-<version>.md` first — `generate_appcast` uses a notes file
whose basename matches the archive — and passes `--embed-release-notes` so the
text lands inline in the appcast as `<description sparkle:format="markdown">`.
```

- [ ] **Step 3: Record the link-vs-embed finding in Notes / gotchas**

```markdown
- **Release notes must be EMBEDDED, not linked.** Without
  `--embed-release-notes`, `generate_appcast` writes a
  `<sparkle:releaseNotesLink>` derived from `SUFeedURL` — the notes then need
  to be uploaded as their own release asset and are silently blank if that
  asset 404s. Embedding keeps the update check to a single appcast fetch, which
  is what the app's network policy promises. Verified both ways, 2026-07-28.
- **A notes-file basename mismatch is silent.** `Muse-1.4.dmg` needs
  `Muse-1.4.md`; anything else produces no warning and no notes. `release.sh`
  asserts a non-empty `<description>` after generating for exactly this reason.
```

- [ ] **Step 4: Mention the flag in the "easy way" section**

Under the `scripts/release.sh 1.0.1` examples, add:

```sh
scripts/release.sh 1.0.1 --no-notes   # skip the notes requirement (empty dialog)
```

- [ ] **Step 5: Append a session-log entry**

Add a dated entry to `docs/session-log.md` in the existing format, covering:
the update dialog was blank because `release.sh` never staged a notes file;
`docs/release-notes-<v>.md` is now the single source for both the dialog and
the GitHub body; embed-not-link and why; the preflight and post-generate
assertions; and that the *rendering* remains unverified until the next signed,
notarized release smoke test.

- [ ] **Step 6: Verify the docs are accurate**

Re-read the edited `docs/RELEASING.md` steps against the final
`scripts/release.sh`. Every filename, flag and path named in the doc must exist
in the script. Expected: no `Muse.html` reference remains
(`grep -n 'Muse\.html' docs/RELEASING.md` returns nothing).

- [ ] **Step 7: Commit**

```bash
git add docs/RELEASING.md docs/session-log.md
git commit -m "docs: record how release notes reach the update dialog"
```

---

## Verification owed after this plan

The mechanism is verified offline; the **rendering is not**. At the next real
release, follow the existing "Verifying" section of `docs/RELEASING.md`:
install an older signed build, run **Muse ▸ Check for Updates…**, and confirm
the notes pane shows the formatted markdown (headings, bold, bullets) in both
light and dark appearance. Until that runs, describe the rendering as
unverified.
