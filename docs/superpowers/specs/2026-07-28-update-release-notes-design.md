# Release notes in the update dialog — design

**Date:** 2026-07-28
**Branch:** `feat/release-notes` (off `main`)
**Status:** approved

## Problem

When Sparkle offers an update, the release-notes pane is empty. A user is
asked to install a new version with no statement of what changed.

The cause is in `scripts/release.sh`: `generate_appcast` picks up a release-
notes file only when its basename matches the archive's, and the script never
puts one there. Muse 1.3.3 shipped notes because a `Muse-1.3.3.html` was
hand-placed in `build/releases/`; 1.4 shipped blank because nobody repeated
that by hand. `docs/RELEASING.md` compounds it by naming the file `Muse.html`,
which is the wrong basename and would never have matched.

Meanwhile `docs/release-notes-<version>.md` already exists, already written in
user-facing language. The text is not the missing piece; the pipeline step is.

## Goals

- The Sparkle update dialog shows what changed, in the user's language of
  benefit rather than commit-speak.
- The same text becomes the GitHub release body.
- A release cannot silently ship blank notes again.
- No new network surface, no app-side code, no new dependency.

## Non-goals

- **French notes.** Sparkle falls back to the single description for every
  locale. `generate_appcast` has no native localized-notes support, so this
  would require hand-editing the generated XML plus a per-release translation
  gate. Deferred; it can be added later without reworking anything here.
- **An in-app "What's New" window.** The update dialog is the surface the user
  actually sees at update time.
- **Authoring tooling.** The notes stay hand-written. They are a product
  statement, not a changelog dump.

## Design

### Source of truth

`docs/release-notes-<version>.md`, the convention already in the repo. One
file per release, hand-written, shown verbatim in both surfaces.

### Mechanism (verified, not assumed)

`generate_appcast` reads a `.md`/`.html`/`.txt` file whose basename matches
the archive. Two behaviors were tested offline against the real
`build/releases/Muse-1.4.dmg` and `docs/release-notes-1.4.md`:

| Invocation | Result |
|---|---|
| `.md` present, no flag | `<sparkle:releaseNotesLink>` pointing at `…/releases/latest/download/Muse-1.4.md` — a URL derived from `SUFeedURL` |
| `.md` present, `--embed-release-notes` | `<description sparkle:format="markdown"><![CDATA[…]]></description>`, the file inline and intact |

**The embedded form is the design.** The link form is rejected because it is a
second network fetch to a second asset that must also be uploaded — and if that
asset 404s, the notes are blank with no signal. Embedding keeps the update
check to the single appcast fetch it is today, which is what the network policy
in CLAUDE.md commits to.

Sparkle is pinned at **2.9.3**, which renders `sparkle:format="markdown"`
client-side, and `generate_appcast` ships inside that same resolved artifact —
producer and consumer are version-matched by construction. The embedded CDATA
preserved headings, bold, bullets, `---`, inline code and emoji verbatim.

### Changes to `scripts/release.sh`

1. **Preflight.** Alongside the existing `create-dmg` and notary-profile
   checks, fail when `docs/release-notes-$VERSION.md` is missing. This runs
   *before* the archive so the failure costs seconds, not the ~20 minutes an
   archive-plus-notarize round trip costs. A `--no-notes` flag opts out for a
   deliberately silent build.
2. **Stage the notes.** Copy the file to `$REL_DIR/Muse-$VERSION.md` so its
   basename matches `Muse-$VERSION.dmg`.
3. **Extend the prune.** The existing `find … -delete` keeps only the current
   DMG but ignores notes files, which is how a stale `Muse-1.3.3.html` survived
   in `build/releases/` into the 1.4 release. Add `*.md` and `*.html` to it, on
   the same "keep only this release's files" rule.
4. **Pass `--embed-release-notes`** to `generate_appcast`.
5. **Assert the result.** After generating, fail loudly unless `appcast.xml`
   contains a non-empty `<description>`. Without this, any future change in
   naming or flags reverts to blank notes on a green run — exactly how this bug
   shipped the first time.
6. **GitHub body.** `gh release create … --notes-file "$NOTES"` replaces the
   placeholder `--notes "Muse $VERSION"`. Under `--no-notes`, keep the
   placeholder.

### Changes to `docs/RELEASING.md`

- A step 0: write `docs/release-notes-<version>.md` before cutting the release.
- Correct the manual step 4 aside: the file is `Muse-<version>.md` matching the
  DMG basename, embedded via `--embed-release-notes` — not `Muse.html`.
- Record the link-vs-embed finding, so a future session doesn't "simplify" to
  the link form and reintroduce the second fetch.

## Error handling

Every failure mode is a hard stop with a named cause, before anything
irreversible:

- Missing notes file → preflight failure, before the archive.
- Notes present but not embedded (naming/flag drift) → post-generate assertion
  failure, before publishing.
- `--no-notes` → an explicit, visible choice, echoed in the run output.

Nothing degrades silently, because a silent degrade is the bug being fixed.

## Testing

The pipeline is a shell script that cannot run in the unit suite (it archives,
notarizes and hits the network), so verification is staged:

1. **Done — offline mechanism check.** `generate_appcast` run in a scratch dir
   against the existing 1.4 DMG, both with and without the flag. Results in the
   table above.
2. **Dry run at implementation time.** Re-run the notes-staging, prune and
   assertion logic against a scratch copy to confirm the script's own steps
   behave, without cutting a release.
3. **Owed at the next real release.** How the notes *render* in the update
   sheet needs a signed, notarized build and an older install — the smoke test
   already documented in the "Verifying" section of `docs/RELEASING.md`. Until
   that runs, rendering is unverified and should be described that way.

## Risks

- **Rendering unverified until a real release** (above). The mechanism is
  verified; the pixels are not.
- **Notes drift from the shipped feature set.** The preflight forces a file to
  exist, not for it to be accurate. That stays a human responsibility.
