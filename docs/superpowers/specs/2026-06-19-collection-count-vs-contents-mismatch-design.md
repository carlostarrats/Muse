# Collection "shows N but opens empty" — root cause + fix spec

**Date:** 2026-06-19
**Status:** Lever 1 **shipped** (`feat/next-28`, TDD, full suite green). Lever 2
**deferred** — only the step-0 diagnostic log is in place; the partial-
materialization guard awaits a confirmed cold-launch repro (see Plan step 0 / the
Lever 2 section). Pick up Lever 2 here once the diagnostic confirms the trigger.
**Reporter:** user, via screenshot of the "Shopping 15" collection opening to a blank grid.

---

## TL;DR for a fresh session

A collection's card/header shows a member count (e.g. "15"), but opening it
shows an empty (or partial) grid. This is the **recurring** "collections show
files but open empty" symptom. It is **transient and self-heals** — by the time
the user re-checked, all 15 were there and every card showed thumbnails.

It is **NOT** the old ghost-row bug (deleted-from-disk files left `is_alive=1`)
that `PathReconciler` already fixed. The files all exist on disk and are fully
downloaded. The cause this time is a **transient membership churn after an app
update**, made to *look* like corruption by a **count-vs-contents source split**.

Two independent fixes, do both, in order:
1. **Lever 1 (cheap, do first):** unify the badge count and the opened-grid
   contents onto one live source so the number never lies.
2. **Lever 2 (deeper, confirm first):** stop iCloud files from being transiently
   dropped from `is_alive` on a partial cold-launch enumeration, which is what
   churns the membership.

Before touching Lever 2 (a data-loss-sensitive path), add ONE diagnostic log
line and confirm the trigger is actually `is_alive` flapping — do not guess and
harden the wrong thing.

---

## Verified evidence (from the 2026-06-19 investigation)

Live DB at `~/Library/Containers/com.tarrats.Muse/Data/Library/Application Support/Muse/muse.sqlite`:

- "Shopping" is an **intent collection**: `id = intent:shopping`,
  `model_version = intent-v1`, `is_hidden = 0`.
- 15 members, all `is_alive = 1` (so the badge counts 15).
- All 15 `absolute_path`s **exist on disk and are fully downloaded** — no iCloud
  placeholders, no `.<name>.icloud` siblings, real byte sizes. Checked by hand.
- Member locations:
  - **14** under `…/Library/Mobile Documents/com~apple~CloudDocs/Archive/Saved Inspo/`
  - **1** is `/Users/carlostarrats/Downloads/social.jpg`
- Configured roots (`muse.roots.v1` in prefs): **"Saved Inspo"** (resolves to the
  iCloud `…/Archive/Saved Inspo` path — confirmed via the bookmark) and **"INSPO"**
  (`~/Desktop/INSPO`).
- User confirmed at runtime: both roots browse **fine** (Saved Inspo ~1950 imgs,
  INSPO shows all 10), and the Collections-page card for Shopping now shows **all
  15 thumbnails**. So security-scope / access is healthy — ruled out.
- User confirmed the empty state **self-resolved** without them watching it
  repopulate ("just when I checked it they were now there").

### Two facts that prove the structural split

- **Badge count = pure DB count, no disk check.**
  `CollectionsRow.swift:66` renders `loaded.aliveCount`, which comes from
  `CollectionStore.fetchAll` →
  `SELECT COUNT(DISTINCT p.file_id) … WHERE m.collection_id=? AND p.is_alive=1`.
  Served from `CollectionsEngine.collections` (an in-memory snapshot, refreshed
  only when `reload()` runs).
- **Opened grid = live query + `fileExists` + sort.**
  `AppState+Filters.setActiveCollection` calls `CollectionStore.alivePaths`
  (live `is_alive=1` query), then `paths.compactMap { fileExists($0) ? FileNode … : nil }`,
  then `SmartSorter.apply` (which never drops files — verified). Result drives
  `visibleFiles` → `GridView`.

Whenever those two reads disagree (different source, different time), you get
"badge says 15, grid shows fewer/none."

### One genuinely-off, timing-independent detail

`/Users/carlostarrats/Downloads/social.jpg` is **not under any added root**. The
badge counts it (DB-only), but the sandboxed app can never display a file outside
its roots, so it is a permanent phantom in the count. Minor, but real, and Lever 1
fixes it for free.

---

## Root cause

### Why it churns (Lever 2 territory)

`CollectionsEngine.recluster()` is **global and idempotent**. The intent track
rebuilds "Shopping" as *every alive file with `intent='shopping'`* (gated to ≥3
members by `IntentCollections.qualifyingBuckets`):

```sql
SELECT f.id, f.intent FROM files f JOIN paths p ON p.file_id=f.id
WHERE f.intent IS NOT NULL AND p.is_alive = 1
```

Then `CollectionStore.upsert` rebuilds that collection's `added_by='auto'` members
in **one atomic transaction** (DELETE auto members + re-INSERT). Because it's
atomic and global, at steady state it always reproduces the correct 15. It can
only be wrong while those files are transiently **out of the pool**, i.e. their
`is_alive` flipped to 0 or their `intent` got cleared.

`recluster()` is invoked after each analysis pass (`AnalyzePipeline.swift:72` for
single-file, `:209` at the end of a folder batch — once per folder, not per file).

**Leading theory for the transient `is_alive=0`:** on a cold launch after an
update, an iCloud folder can enumerate **partially** (not everything materialized
yet). `PathReconciler` (run on fresh folder load, `AppState.swift` ~1003-1007)
guards the *fully-empty* enumeration case with a directory probe, but a **partial**
enumeration is **not** guarded — the not-yet-materialized files look absent and
can be marked `is_alive=0`, dropping them from "Shopping" until a later complete
pass restores them. This matches every symptom: iCloud-only, self-healing, no user
action. **NOT yet proven by a repro — confirm before acting (see Plan, step 0).**

(Note: if `is_alive` really flipped, the badge "15" must have been a *stale*
`CollectionsEngine` snapshot from before the flip — consistent with Lever 1's
diagnosis that the badge reads a cached value while the grid reads live.)

### Why it looks like corruption (Lever 1 territory)

The badge (cached snapshot) and the grid (live query) read different sources at
different times. So a normal background rebuild shows as a frightening "15 over an
empty grid" instead of an honest, self-healing number.

---

## The fix

### Lever 1 — unify count and contents onto one live source (do first)

**Goal:** the badge can never show a number the grid can't back up. During any
churn you'd see a consistent count (briefly lower, then 15), never a lie. Also
drops the out-of-root `Downloads` phantom from the count.

**Approach (confirm exact shape when implementing):** make the displayed count
derive from the same live, reachability-aware set the opened grid uses, rather
than from the `CollectionsEngine` snapshot's `aliveCount`. Options to weigh:
- Cheapest: count only members that are both `is_alive=1` **and** under an active
  root (a path-prefix check against the active root URLs — no per-file `stat`,
  no iCloud risk). This mirrors what the grid can actually show and kills the
  Downloads phantom.
- Or: have the card and the grid share one computed source so they can't drift.

**Touch points:** `CollectionsRow.swift` (badge), `CollectionStore.swift`
(`fetchAll` / a new reachability-aware count), `CollectionsEngine.swift` (what the
snapshot stores). Keep it small + localized.

**Cost:** ~1–2 min incremental Xcode build. Low stakes.

### Lever 2 — stop the iCloud membership churn (confirm trigger first)

**Goal:** members never leave the pool during a post-update rebuild, so
collections stay populated and the 5-minute window disappears.

**Approach:** harden `PathReconciler` so it won't mark a file `is_alive=0` when
the file is merely an **unmaterialized iCloud placeholder** in a ubiquitous
folder (treat "absent from a ubiquitous folder during a partial enumeration" as
"not yet downloaded," not "deleted"). Extends the existing fully-empty guard to
the partial case.

**Touch points:** `Filesystem/PathReconciler.swift` (presence/scope rule) and its
caller in `AppState.swift`. This is the **data-loss-sensitive** path Muse
explicitly guards (see `muse-fix-code-not-my-data` and the iCloud constraints in
CLAUDE.md), so:
- Add a unit test for the partial-materialization case (mirror the existing
  `PathReconcilerTests` false-empty test).
- Do NOT reintroduce any size/mtime polling (violates
  `muse-icloud-content-refresh-override`); this is filesystem-presence /
  dataless-status only.

**Cost:** slightly bigger; higher stakes; needs a test.

---

## Plan (tomorrow)

0. **Confirm Lever 2's trigger before touching the reconcile.** Add one
   diagnostic log line where `PathReconciler` marks rows dead (log folder, count,
   and a few sample paths), build, reproduce the post-update cold-launch, and
   confirm it's the Saved Inspo iCloud files being marked `is_alive=0` on a
   partial enumeration. If it's something else, re-diagnose — don't harden blind.
1. **Implement Lever 1.** Unify the badge onto a live, reachability-aware count.
   Verify: badge == opened-grid count in steady state; Downloads phantom no longer
   counts; build + full `MuseTests` green.
2. **Implement Lever 2** (once step 0 confirms the trigger). Guard the reconcile
   against partial iCloud materialization + add the unit test. Verify: a simulated
   partial enumeration of a ubiquitous folder does not mark unmaterialized files
   dead; full suite green.
3. Update `docs/session-log.md` + the CLAUDE.md durable-constraints / architecture
   map as appropriate (note the partial-materialization guard alongside the
   existing false-empty guard).

## Acceptance

- Opening any collection shows a count that matches its visible contents (no
  "15 over empty"); out-of-root members don't inflate the count.
- After an app update + cold launch with iCloud folders, collections do not
  transiently empty (members aren't dropped from `is_alive` by a partial
  enumeration).
- No regression in the existing ghost-row reconcile (truly-deleted files still
  get marked dead on folder load); `MuseTests` green.

## Do-not-break references

- `muse-fix-code-not-my-data` — fix forward code; don't migrate the dev DB.
- `muse-icloud-content-refresh-override` — content-hash, never size/mtime, for
  iCloud change detection.
- CLAUDE.md "iCloud container is data-loss-sensitive" + the `PathReconciler`
  false-empty guard from `feat/next-16` (2026-06-18 session log).
