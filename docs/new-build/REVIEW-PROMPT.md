# Review prompt — Specs 01–07 (paste into a clean chat)

---

Review, QA and fix the entire `new-product-build-1` branch — everything Specs 01
through 07 built. The outcome I want is a sound codebase with clean, reviewed code.
Go after health, architecture, security, structure, best practice, speed, bugs, leakage,
and anything not right that I am not calling out. Be thorough; check all features.

Constraints:

- It is **36,811 insertions across 294 Swift files (227 new)**, built back-to-back by
  seven separate headless agents that never saw each other's work, and **almost none of
  it has ever been run**.
- **Work solo.** No subagents, no Workflow tool, no fan-out. One context, sequential
  slices. I am on a usage budget and parallel agents burn it.
- **Find problems by reading code, not by waiting for symptoms.** I should not have to
  play with the app to discover what a review should have caught. Runtime checks confirm
  what the code review predicted; they are not how problems get discovered.

## Ground truth, in precedence order

1. `docs/new-build/DECISIONS.md` — binding build-level record. **Read its
   "Current state" block first**; the per-spec "as-built" sections are point-in-time
   snapshots and some are stale.
2. `CLAUDE.md` → "Durable constraints & gotchas" — must-not-break rules. Each encodes a
   bug that already shipped once.
3. `docs/new-build/muse-photo-foundation.md` — product-level decisions.
4. `docs/superpowers/plans/2026-07-30-spec-0*.md` — what each spec was supposed to do.
   Divergences should be recorded in DECISIONS; unrecorded divergence is itself a finding.

**Precedence trap:** CLAUDE.md's durable constraints describe the app as it was BEFORE
these specs. Where new code appears to violate one, it may be a deliberate, recorded
supersession (Spec 02 legitimately deleted `CoordinateReader`, which Spec 01 had just
shipped). Check DECISIONS before calling a violation a bug. If neither doc resolves it,
make the call yourself from the foundation's stated intent and record the reasoning in
your findings — don't stall on it.

The diff is `git diff $(git merge-base main HEAD)..HEAD`.

## Known starting state — read before you trust anything

- **Test baseline, verified 2026-07-31: 1,748 tests, 2 skipped, 0 failures.** Green
  before you touch anything, so any failure you see later is yours. Run the unit suite
  with `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS'
  -only-testing:MuseTests test`. **Do not pipe xcodebuild through `tail`** — it prints a
  per-bundle summary, so tailing shows only the last bundle (6 UI tests) and hides the
  1,748. Grep for `Executed .* tests` instead, or you will misread a green run as a
  near-empty one.
- Two `IIOImageSource ... fileExists == false` errors appear during the run, pointing at
  `~/Desktop/Muse Index Test-2/`. Tests reaching into a real user directory is worth a
  look — low severity, but it means some test depends on my machine's contents.
- Nothing on this branch has been exercised in the running app beyond a single launch.
- `MUSE_TRACE=1` (see `Components/PhaseTrace.swift`) enables phase tracing; the launch
  backfills already call `PhaseTrace.mark`. Use it rather than adding print statements.
- The app is sandboxed: `/tmp` writes are silently denied and `NSLog` does not reach
  `log stream`. Trace to `NSTemporaryDirectory()`.
- A clean build means deleting the built `Muse.app` from DerivedData first. An
  incremental build prints `BUILD SUCCEEDED` over a weeks-stale app; `stat` the binary
  and confirm its mtime is seconds old before believing any runtime result.

## Pass A — systematic sweeps (do this first, before slice-by-slice review)

These are enumerations, not searches. Fill in every row; a gap must show up as a blank
cell rather than as something nobody thought to look for. Write each table into
`docs/new-build/REVIEW-FINDINGS.md`.

1. **Launch work.** Every task that runs at launch: trigger, what it scans, its cost at
   10k and 100k files, its per-launch cap, and what sequences it against the others.
   (`MuseApp.swift` currently fires eight unstructured `Task {}` blocks including four
   independent backfills, and `PhotoTraits.currentVersion` is now 2, which invalidates
   every existing traits row. Each spec added its own and none coordinated. Whether that
   is acceptable is already decided — foundation §9: analysis is background, throttled
   and pausable, photos browsable immediately, cold start budgeted. Conform to that.)
2. **Full-library scans and backfills.** Every one, its trigger, its cap, what
   invalidates it, and whether two can run concurrently over the same rows.
3. **Main-thread work.** Every synchronous DB read on main, every `withAnimation` around
   an `AppState` write, every per-keystroke or per-frame binding to a `@Published`, every
   unbounded debounce.
4. **Algorithmic cost.** Every loop, query or join that is O(n²) or unbounded in library
   size — including inside migrations.
5. **Image decode sites.** Every one, whether it is automatic or user-initiated, and
   whether it is guarded by `withinDecodeBudget`.
6. **Network.** Every `URLSession` call site, the user action that gates it, and what it
   sends. Compare against DECISIONS' Current state list.
7. **Identity rewrites.** Every path that rewrites `parent_dir` or `file_id`, and whether
   it carries tags, notes AND edits (Spec 04's tables are the new ones).
8. **`AppState` surface.** Every new `@Published`, and what re-evaluates when it fires.
9. **Thumbnail cache.** Every call site's requested size vs `renderedVariants`; every
   `invalidate` path vs both stack states.
10. **Error and cancellation paths.** Every new `throw`/`Task` cancellation: what is left
    behind — a temp file, a partial upload, a half-written generation directory, an
    orphaned Drive folder.

Report the tables before fixing. They will reorder the slices below.

## Pass B — slices, each looped until green

For each slice: review against every lens (correctness, durable constraints, security
and leakage, resource/memory, perf, architecture and duplication, error and cancellation
paths, state divergence, test coverage) → fix → verify green → commit that slice →
report → next.

**Green means all of:** clean build with a verified-fresh binary; the full test suite
passes (all 1,748, not just the UI bundle), including every earlier slice's
tests — this is the regression check, since a fix in one slice routinely breaks another;
and a fresh re-review surfaces **no new confirmed findings two rounds running.** One
clean round is not green — a first fix is usually not the whole fix, which is the entire
reason for the loop.

Cap each slice at 5 rounds. Still finding things at round 5 means the area is deeper
than a loop can settle: stop, commit what is green, and write up what remains with your
recommendation — then carry on to the next slice rather than waiting on me. Also stop early
if the only remaining items are speculative. **Verify every finding in the code before
acting on it** and say plainly whether you confirmed it or inferred it — an unverified
fix to this codebase is a regression.

Slices, in default order (Pass A may reorder them):

1. **Invariants** — the `OutputRender` choke point (does Spec 07's social export and
   portfolio upload go through it?); thumbnail keying; the per-`(file_id, parent_dir)`
   grain for tags/notes/edits; rating exclusivity through Spec 06's importers; decode
   budgets; network doctrine; fail-closed metadata stripping including portfolio;
   selection pruning for compare/cull; Escape ordering; modal presentation.
2. **Editing engine + readouts (04, 05)** — render chain order, codec canonical ordering
   and hash stability, autosave, history, versions, presets, Edit-a-Copy.
3. **Import (06)** — the claim is "a new source is a reader and a mapper, never a new
   writer." Verify literally, then mapper correctness and re-run idempotency.
4. **Sharing and social export (07)** — manifest v2, the page's inflate cap and CSP, the
   X export ladder, portfolio manifest swap and sweep. Hardest security surface: the page
   takes attacker-suppliable input.
5. **CLIP, culling, search (02, 03)** — model store lifecycle and fail-closed download,
   embedding index, trait markers, compare/cull state, token search, geocoding, stacks.
6. **Migrations v13–v23** — ordering, correctness against real data, launch cost.
7. **Cross-spec seams** — the pass no spec agent could do. Files two specs modified for
   different reasons (`AppState`, `ContentView`, `GridView`, `SearchService`,
   `AnalyzePipeline`); later specs depending on earlier half-built work; duplicated logic
   that should be shared; shared logic one spec changed under another.

## Don't ask me — the intent is in the plans

Do not stop to ask which behaviour I want. The product intent is already decided and
written down; go read it and conform the code to it. `muse-photo-foundation.md` §9
(architecture & performance) and its §13 decision table are the authority, with
DECISIONS.md for build-level specifics. Decide, act, and record what you concluded and
where you got it.

These are DECIDED and are therefore acceptance criteria, not open questions — audit the
new code against each and fix what doesn't conform:

- **"Everything expensive happens once, at analyze time, in the background."** Query time
  touches only precomputed data.
- **Analysis is background, throttled (battery / Low Power Mode), pausable under thermal
  pressure, "finishes overnight-style." Photos are browsable immediately.** This settles
  the launch-backfill question: four uncoordinated passes that make first launch crawl
  violate a decided rule. Fix it to conform; don't ask me which I'd prefer.
- **Cold start is a budgeted metric** on the reference machine (M1 Air 8GB), alongside
  grid scroll, search latency and slider-to-render latency. Design centre is 10k–50k
  photos and "must be flawless"; 200k–800k must "degrade gracefully — never crash, never
  corrupt, never beachball."
- **"Never write code that assumes everything fits in RAM."**
- **`AppState` is frozen** at ~1380 LOC / ~70 `@Published`, per foundation §9 — new
  features get their own state objects. **This has already been breached and is a
  confirmed finding, not a hypothesis:** `AppState.swift` measures **1505 LOC and 85
  `@Published`** (93 across all `AppState*.swift`) as of 2026-07-31. Attribute every
  addition to its spec, and move the ones that should have been their own store. Note
  DECISIONS records Spec 06 deliberately holding this line ("net-zero `@Published`
  count") while other specs did not — so the rule was known and unevenly applied.
- **The platform-neutral core imports zero AppKit** (edit recipes, search/query, sidecar
  I/O, import mapping).
- **Dependencies stay minimal**; models are downloaded on demand, never bundled.
- **Theming is tokenized** — one `Theme` via Environment, by role. No raw hex or magic
  numbers scattered in views.
- **Edit preview renders at screen resolution, never full-res.**

**Nothing is off limits.** If there is a real problem anywhere, fix it — including in
code the docs describe as deliberate. What is NOT allowed is changing something because
it looks wrong to you without first finding out why it is that way.

Some code here is counterintuitive on purpose and the reason is written down: the
asymmetric 0.3s/0.4s hero backdrop fade (0.4s in, 0.3s out — the out must finish before
the 0.36s unmount, and symmetrising it reintroduces a visible flash), the split branch in
`Indexer.reconcile`, the un-animated spacing slider, the windowed/full-screen toolbar
hybrid. Each was arrived at after several wrong fixes.

So the bar is evidence, not permission. Before changing any of it, find the durable
constraint or DECISIONS entry that explains it and say what the reason was. Then: if you
have identified a genuine defect — it actually misbehaves, leaks, races, or contradicts
the plans — fix it and explain why the documented reasoning no longer holds. If your only
complaint is that it reads as inconsistent, odd, or asymmetric, that is not a defect and
the existing code wins. Update the doc alongside any change you do make, or the next
reviewer re-litigates it from scratch.

Otherwise: fix it. Small, surgical, in the style of the surrounding code — not broad
refactors. Never delete, weaken or skip a test to make it pass. If a change would alter a
migration, `stack_hash`, or a thumbnail cache key, that silently re-keys every edited
thumbnail in every existing library — so do it only if the plans require it, and say so
loudly in your report.

## Pass C — runtime confirmation

Not for discovering that something is slow — Pass A should have predicted that. This
confirms the predictions and catches the narrow class that only appears in motion.

1. Launch on an existing library with `MUSE_TRACE=1` — v13→v23 against real data. Compare
   actual phase timings to Pass A's table; a mismatch means the table was wrong.
2. Grid: still virtualized, correct under the new filters and sorts.
3. Hero open/close — the most timing-fragile thing in the app, and Spec 04 put an editor
   inside it. This genuinely resists static review: the history is that six reasoned
   fixes were wrong and the instrumented ones were right. Instrument, don't reason.
4. Editor: sliders, curve, eyedropper, before/after, versions, presets, Edit-a-Copy.
   Confirm an edit re-thumbnails and the original is untouched on disk.
5. Compare/cull; import (on a real Lightroom or Takeout export if available); social
   export, share, portfolio.
6. Backup/restore round trip — known to lose edit data; confirm the scope.

`sample <pid>` for main-thread stalls; `MUSE_TRACE=1` for phase ordering.

## Final pass

Re-run the full suite, re-verify the Pass A tables (later fixes create new call sites),
then update documentation: `CLAUDE.md` durable constraints for any new rule this review
establishes, `DECISIONS.md` — its **Current state** block for anything volatile, not a new
per-spec section — `docs/architecture-map.md` for new or moved files, and a
`docs/session-log.md` entry for the review. Then commit.

## Known-open, do not re-report

- Backup carries no edit data (`BackupOccurrence` has no edit fields); Spec 09's
  amendment A2 closes it.
- 146 of 992 localization keys have no French value (Specs 03, 06). Flag, don't chase.
- `PerfBaseline` rows were never written for Specs 03, 04, 05.
- `-exportLocalizations` cannot build the project (`ClipVectors.swift` uses `Float16`;
  the extractor builds universal).
- Distribution is still direct + Sparkle; the MAS migration is deliberately deferred.
- Spec 04's `EditCopyFlow` does not stack the copy with its parent (recorded, not stubbed).

Report each pass and slice as you finish it: what you fixed, what you left, what you
could not verify.
