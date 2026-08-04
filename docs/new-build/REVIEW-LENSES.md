# Muse review lens registry

**What this is.** Every lens any review round has run against this codebase,
with the date it ran and what it found. It is the answer to a specific failure
mode: six rounds on `new-product-build-1` each found real bugs, and each found
them by running a lens the previous rounds hadn't thought of. That works, but it
never *ends* — the lens space is unbounded, so "review until it's green" has no
exit criterion and the same classes get rediscovered by whoever happens to
remember them.

**What it changes.** A round is no longer "think of some angles." A round is:

1. Run `./scripts/audit-invariants.sh` — the mechanical checks. Must be green.
2. Run the **unrun** lenses in Part 2 below, if any.
3. Append any genuinely new lens you thought of to Part 2, and run it.
4. If Part 2 is empty and the audit is green, **static review is done.** Say so
   and stop. The remaining risk is runtime, not reading — see the ledger's G1.

That last step is the point. "Done" becomes a fact you can check rather than a
judgment call someone has to defend.

**The standing rule about findings.** A finding that is mechanically detectable
does not get fixed and forgotten — it gets a check in `audit-invariants.sh`, so
the class cannot come back. A finding that needs judgment gets a test. A finding
that is neither gets a row in `docs/durable-constraints.md`. Fixing the instance
without closing the class is what produced six rounds.

---

## Part 1 — lenses already run

Rounds 1–3 are recorded in `REVIEW-FINDINGS.md` and `FEATURE-LEDGER.md`; rounds
4–6 in their commit messages (`73eed68`, `6a702cb`, `8fd4988`). Dates are all
2026-08-01 unless noted.

| Lens | Round | Result |
|---|---|---|
| Launch work — what runs, what blocks what | 1 (A1) | 14 tasks mapped; ordering defects found |
| Full-library scans & backfills — caps, invalidation, self-concurrency | 1 (A2) | 3 unbounded/re-entrant passes found |
| Main-thread work — sync I/O on `@MainActor` | 1 (A3) | LUT blob read on main confirmed |
| Algorithmic cost — O(n²) shapes, unindexable queries | 1 (A4) | `ClipIndex` paging, facet queries |
| Image decode sites — budget guard coverage | 1 (A5) | complete; now **mechanized** as `DEC-1` |
| Network — egress surface | 1 (A6) | complete; now **mechanized** as `NET-1`/`NET-3` |
| Identity rewrites — do the seams carry tags, notes, edits | 1 (A7) | all 5 seams verified |
| `AppState` surface — new `@Published` churn | 1 (A8) | clean |
| Thumbnail cache — keying, eviction | 1 (A9) | unedited key byte-identical |
| Error & cancellation paths — what is left behind | 1 (A10) | orphaned resources found |
| Pre-branch feature regression under the 3 new seams | 2 | 4 findings (hero flight, sidecar tags) |
| Backup completeness vs. the edit model | 3 | G2 closed — edits ride the archive |
| Swift 6 strict concurrency | 3 | 442 warnings eliminated |
| Localization completeness | 3 | 1,002 keys, 0 untranslated |
| Self-QA of the round's own diff | 3, 6, **11** | 4 + 1 + **7** defects in the review's own work |
| Disk-full / write-failure behaviour | 11 (2026-08-03) | 1 finding — a failed HEIC write left NO cache entry, so that tile re-decoded on every launch forever |
| Main-thread I/O introduced by a new feature | 11 (2026-08-03) | 1 finding — a per-stats-tap header read on `@MainActor` |
| SQL **construction** (injection, escaping) | 4 | clean |
| Crash-on-user-data (`try!`, `fatalError`, unchecked subscript) | 4 | clean — and the wrong door; see round 6 |
| Resource lifecycle (shared things rebuilt per item) | 4 | 2 findings (CIContext, LUT LRU) |
| Remote body bounds | 4 | 1 finding; now **mechanized** as `NET-2` |
| Time-zone correctness of SQL date parts | 5 | 2 findings — both user-visible wrong-day bugs |
| Path prefix boundaries | 5 | clean |
| Unicode path normalization | 5 | clean |
| Comparator ordering / sort stability | 5 | clean |
| Transaction atomicity | 5 | clean |
| Task-group concurrency bounds | 5 | clean |
| Arithmetic traps on file-declared numbers | 6 | 5 sites, app crashed on file select; now **mechanized** as `INT-1` |
| Untrusted metadata → filesystem path | 6 | 1 finding (Eagle import escape) |
| Bounds on a download's payload leg | 6 | 1 finding + symlink unpack |
| Local log leakage | 6 | 1 path in a non-DEBUG print |
| Numeric conversion surface beyond `Int(_:)` | 6 | clean — safe by provenance |
| Locks & reentrancy (`await` inside a lock, nested GRDB) | 6 | clean |
| Unbounded in-memory growth | 6 | clean |
| File-write atomicity | 6 | clean |
| **Spec → code existence** (is every specified symbol real?) | **7** | 1 finding — Spec 03 §5 region similarity never built; **owner dropped it**, code removed |
| **Unreferenced / dead code** | **7** | 3 files; 2 removed, 1 kept as evidence |
| Schema **downgrade** (old build opens a newer DB) | 7 | clean — GRDB no-ops, columns nullable, backfills self-heal |
| Nil-`dbQueue` fallout (what runs when the DB fails to open) | 7 | clean — every consumer `guard`s and no-ops; the delete path can't be called at all |
| Observer / resource lifetime (leaks, un-removed observers) | 7 | clean — both `NotificationCenter` sites are static + install-once |
| Accessibility on the surfaces THIS branch added | 7 | broadly labelled; the one gap was in dead code |
| Cross-process DB access (multi-instance, share extension) | 7 | clean for shipping; **dev-machine hazard** — see note below |
| **Driving the running GUI** (XCUITest, not osascript) | **7b** | G1 partially closed; 10 surfaces confirmed by screenshot |
| **Per-hover layout cost in a custom `Layout`** | **7b** | **R7-4 — the tag chip row re-measured every chip per hover frame** |
| Vacuous test assertions (can this test fail?) | 7b | 7 of 10 UI tests asserted only "a window exists"; all strengthened |
| **Per-frame work inside a SwiftUI body** | **8** (2026-08-02) | 2 findings — every preset and every snapshot decoded its stored JSON on every render, i.e. every frame of a slider drag |
| Event-monitor lifetime & event stealing | 8 | clean — the viewer's Escape monitor yields to `modalPresented` and is removed on disappear |
| Explicit animation-task lifecycle (hand-stepped animators) | 8 | clean after fix — cancelled on re-trigger, on gesture start and on disappear; `[weak self]` |
| Clamp coverage after moving a value to a new writer | 8 | 1 finding — Edit's zoom-out stopped clamping the pan when `setZoom` moved to the animator |
| Dead code created by the round's OWN diff | 8 | 4 findings removed |
| UI tests left stale by a rename | 8 | 2 findings — a card renamed and one deleted while its test still named them |
| **Instrument before theorising** (trace a GPU/run-loop symptom rather than reasoning about it) | **9** (2026-08-02) | The lens itself is the finding: 3 rounds of plausible theories each produced a wrong fix, one actively worse. One trace answered it and disproved the most convincing theory. |
| Dead code created by the round's OWN diff | 9 | 2 findings — `PerImageState.zoom`/`.center` written nowhere after the crop drag went, with identity transforms still applied per frame; `CanvasPointMath` orphaned by the canvas refactor |
| A constant derived from ONE consumer of a shared resource | 9 | 1 finding — `minWindowWidth` was sized from Preview's single info column; Edit shares the window and spends two panels, leaving 60pt of picture at the minimum |
| Architecture map vs. the filesystem (do the listed files exist?) | 9 | 1 finding in this round's own diff; 3 pre-existing, all fixed |
| **UI-test aim: does the test depend on WINDOW SIZE?** | **9** | 6 tests failed with the app working perfectly — a magic `(0.55, 0.5)` window fraction, in 10 places across both drive suites |
| **Accessibility STRUCTURE changed by a refactor** | **9** | 1 finding — moving the Quality row into a shared `readout()` helper gave it `children: .combine`, so `staticTexts["Quality"]` stopped existing and its test failed. The app was right; combining is correct for VoiceOver. Same trap the estimate row had already documented. |
| **Hand-stepped animator that steps the WRONG value** | **12** (2026-08-03) | 1 finding — the column re-fit stepped `chromeProgress`, which had already settled, so all 13 frames recomputed an identical inset. It animated nothing; the photo snapped while the code and the comments claimed a glide. The thing that CHANGED has to be the thing that is walked. |
| Dead code created by the round's OWN diff | 12 | 1 finding — `EditorWorkspace.column(of:)` existed only to be tested |
| Allocation on a per-frame path | 12 | 2 findings — `isEmpty` built a filtered array to ask whether anything survived it, on the canvas's per-frame inset path; `rowShift` did the same once per row per drag frame |
| **Can this assertion fail? (run the negative)** | **12** | 1 finding — the new clipping guard compared the last row to the WINDOW, which is hundreds of points taller than the card, so it would have passed on the exact bug it was written for. Rewritten against the card's own frame (the presenter's ScrollView) and **proven by removing the padding and watching it fail** |
| Operability of a new MODE without a mouse | 12 | 1 finding — reorder was drag-only, and its VoiceOver hint promised a gesture such a user cannot perform. Move Up / Move Down / Move to Other Column actions added on the same model calls the drag uses |
| **A test that AIMS by window fraction rather than locating** | **12** | 1 finding, pre-existing — `testCompareSideBySideOpens` still clicked two tiles at `(0.28, 0.24)` and `(0.59, 0.50)`, "measured from a real screenshot". Round 9 removed this pattern everywhere else and missed this one. Resetting the window frame re-aimed it and it failed reporting *"Compare is broken"* — compare was fine. Now uses `app.photoTiles(limit: 2)`. **A sweep for `withNormalizedOffset` in the drive suites is the mechanical form of this lens** and is worth re-running whenever a test is added |
| **Test state that outlives the test** | **12** | 2 findings, the second caught in the act. The window-resizing test restored the frame only on the happy path — then, with a `defer` added, it STILL broke the suite: the restore was a RELATIVE drag (+420), which is not a restore when the window did not start where you assumed. It left the window at 532pt, and `testCompareSideBySideOpens` — untouched, two tests away — failed because two tiles no longer fit. **A relative undo is not an undo.** The resize was deleted: it proved nothing the constant-height padding check did not, and a drive test must not mutate global UI state it cannot reliably put back. |
| **What ELSE did a table rebuild take?** (indexes, triggers, views) | **13** (2026-08-03) | The lens generalises round 13's own bug. `DROP TABLE files` silently took v13's partial GPS index — created by a LATER migration than the table. Triggers and views: none exist, clean. **Any future rebuild must re-create the full list, not just the ones the migration itself knows about.** |
| **A new branch nobody wrote a test for** | **13** | 1 finding — the rename/move ORPHAN-ADOPTION branch, the thing that keeps edits attached across a rename, had zero tests. 4 added and negative-tested (disabling the branch fails them). |
| Vacuous assertion in the round's OWN tests | 13 | 2 findings. A "stranded rows" count excluded `'/A'` and `'/B'` — every folder in its own fixture — so it was 0 by construction. And an index-restore test dropped the index then ran the CREATE by hand, asserting that SQLite works rather than that the MIGRATION repairs anything; it now stops at v24 so it can fail. |
| **Copy-by-SELECT from a source that may not exist** | **13** | 1 finding — v24 copied each split row's FTS entry with `INSERT … SELECT … FROM files_fts`, which yields NOTHING when the source row is missing, and `backfillBasenameFTS` runs only inside v9. Those copies would have been unfindable by name forever, silently. INSERT-if-missing added to v25 and negative-tested. **`INSERT…SELECT` is a no-op on an empty source — that is a silent branch.** |
| Architecture map vs. the round's own new files | 13 | 2 findings — `InheritDonor.swift`, `AnalysisReuse.swift` absent from the map. Same rot round 9 found. |
| **Order dependence introduced by a change** | **13** | Clean, but newly load-bearing: an external rename is only adopted (rather than forked) because `PathReconciler.reconcile` marks the old path dead BEFORE `scheduleIndexing` runs. Verified. Degrades safely if that ever inverts — the edits still inherit, leaving a transient orphan row that `pruneUnreachable` collects after its 180-day window. |
| **A DELETE whose safety lives only in a comment** | **14** (2026-08-03) | 3 claims untested on v24's stranded-row sweep. All hold — but running the negative **falsified the stated reason**: removing the `parent_dir IS NOT NULL` guard changes nothing, because SQL's three-valued logic already spares NULL rows (`NULL <> '/A'` is NULL, not true). The comment credited the guard; the comment was wrong. Corrected, guard kept as belt-and-braces, and the test re-aimed at the rewrite that WOULD destroy tags (`COALESCE(parent_dir,'')`), verified to fail against it. **A negative test checks your explanation, not just your code.** |
| Strings orphaned by the round's own edit | 12 | 1 finding — a reworded accessibility hint left its old key in the catalog |
| **A stored pair the consumer reads as ONE unit** | **15** (2026-08-04) | 1 finding — `edit_luts` hands `(size, blob)` to `CIColorCubeWithColorSpace`, which reads size³ × 4 floats and checks neither. The importer guarantees the pair; a restored `.muselibrary` writes the row by plain INSERT and does not |
| **Clamp coverage at the RENDER STAGE, not the param struct** | **15** | 1 finding — every stage called `.clamped()` except geometry, which took its params raw. Crop, `quarterTurns` and `straightenDegrees` all reached the renderer unbounded; a degenerate crop renders an EMPTY extent |
| **Default-actor isolation on a pure helper** | **15** | 4 findings. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` means a helper that just forgets `nonisolated` is main-isolated with nothing at the call site to show it. `VisionServices` did its decode off-main and then the whole tail of `VisionTagger.analyze` resumed ON MAIN — **measured 22 ms per 4096×2731 image, once per analyzed photo**. Same for `BackupDocument`, so both the export encode and the restore decode of a whole-library archive were pinned to main |
| **The write FLAG behind a no-overwrite promise** | **15** | 1 finding — `collisionSafeURL` promises "an export can never overwrite a file the user already has"; the write used `.atomic`, which does. Verified by running all three flag combinations: `.atomic` replaces, `.withoutOverwriting` refuses, and **the pair fatalErrors** — so the obvious hardening edit crashes the app |
| **A purpose string on the wrong TARGET** | **15** | 1 finding — `NSPhotoLibraryUsageDescription` was an `INFOPLIST_KEY_` on MuseShareExtension, which contains no Photos code, while the app that calls `PHPhotoLibrary.requestAuthorization` shipped without one. A project-wide grep finds it and says nothing is wrong |
| **User paths in the unified system log** | **15** | 3 findings — `NSLog`'s `%@` arguments are PUBLIC in the unified log, readable by other processes and captured in every sysdiagnose. Folder and file names were going there on every rename/create failure, from an app whose privacy label is "Data Not Collected" |
| Can this assertion fail? (run the negative), on the ROUND'S OWN audit checks | 15 | 1 finding, caught in the act — `TCC-1` matched the purpose string as a SUBSTRING, and the injected violation renamed the key to `…DescriptionXX`, which still contains it. The check passed on its own violation. Re-aimed at `<key>…</key>` and re-injected by DELETING the key |

## Part 2 — lenses NOT yet run

Append here the moment you think of one, even if you are not running it now —
an unrun lens on the list is worth more than a good idea that evaporates.

| Lens | Why it might matter |
|---|---|
| ~~Sparkle update path integrity on THIS branch~~ | **RUN, round 15 — clean.** Feed is HTTPS, `SUPublicEDKey` present, `SUEnableInstallerLauncherService` paired with the two mach-lookup entitlements the sandboxed installer needs, and there is **no `NSAppTransportSecurity` override anywhere** — so ATS is enforced and the feed cannot silently downgrade. `Commerce/` adds no updater surface. |
| ~~TOCTOU on user paths~~ | **RUN, round 15.** All 34 `fileExists` sites swept. The `fileExists` → `moveItem`/`copyItem` pairs (FolderOps, FileMover, AppState+FileOps, the export passthrough) are SAFE by construction — those APIs refuse an existing destination, so the race loses to an error, never to data. The `fileExists` → `write(to:.atomic)` pairs were NOT: three sites fixed, see the write-flag lens above. `ApplePhotosImportModel.collisionName` consults only an in-memory set and never the disk, but its suffix branch is unreachable behind the `fileExists` check above it — left alone, noted here so it isn't re-derived. |
| ~~Long-session memory growth (retain cycles, not allocation shape)~~ | **RUN, round 15 — clean.** Every Combine `sink` on `AppState` and `WorkThrottleStore` captures `[weak self]`; the one `Timer.scheduledTimer` does too; both `ToolbarFade` `NotificationCenter` observers are static and install-once (as round 7 found), and the three `AppState` observers are `[weak self]` on a singleton that lives for the process anyway. |
| A non-Sendable type that WANTS to move off-main | `ClipEngine.embedImage` runs a 6 ms-per-image preprocess on the main actor (measured). It can't simply be wrapped in a `Task.detached` because `CVPixelBuffer` isn't `Sendable` — moving it needs preprocess and prediction to go behind an actor together. Recorded in `docs/possible-updates.md`; the shape generalises to any main-isolated holder of non-Sendable resources. |
| ~~Preference-key lifecycle (renamed/removed ids left in a stored set)~~ | **RUN, round 15 — harmless by construction, closing it.** `editorExpandedSections2` is read ONLY as `expanded.contains(<a known id>)` — at the disclosure bindings and in `updateStatsVisibility`. Nothing ever iterates the set, so a stale id is never queried and costs a few bytes in UserDefaults, nothing more. Round 12 had already shown the newer `editorWorkspace` key clean for a different reason (its loader drops unknown ids). Neither key needs a pruner. |
| A re-key that orphans data instead of migrating it | **Round 11 found one.** Changing a cache/derived-data KEY makes the old entries unreachable, not gone — and unreachable data still counts against a cap. Any key or format version bump needs something that deletes the old shape. **Round 13 re-ran this against the sidecar rename (`<hash>.json` → `<hash>__<basename>.json`) and it does NOT apply: the legacy name is still READ as a fallback, so the old shape stays reachable by design, and nothing enumerates or parses `.muse` filenames. Deliberately not deleted — see the durable-constraints note.** |
| Data staged outside what the cap measures | **Round 11 found one.** A directory renamed aside for background deletion is a SIBLING of the cache root, so `enforceDiskCap` — which measures only inside the root — can never reclaim it if a crash strands it. |
| ~~Two-instance runs during GUI testing~~ | **CLOSED, round 15.** `MuseUITests/SingleInstanceGuard.swift` fails in `setUp` — before `app.launch()` — naming the offending pid and saying outright that this is a test-environment problem, not a defect in whatever fails next. Wired into all three drive suites. **Negative-tested live**: with a second Muse running it failed with exactly that message; with none, the same test passed. |

**Round 9 — the drive suites' own fragility has now cost three rounds.** Every
photo-opening test aimed itself with a fixed window fraction, `(0.55, 0.5)`.
macOS RESTORES the window frame between runs, so a developer resizing the
window by hand — or a change to the window's minimum size — silently re-aims
every one of them; on the ragged masonry grid the fraction landed in the GAP
between two tiles, which clears the selection instead of opening anything. Six
tests failed, and they failed reporting *"hero viewer has no 'Edit' toggle"* —
pointing at the editor, which had just been rewritten. A plausible, wrong
signal aimed straight at the code most likely to be suspected.

This is the same suite that previously (a) pressed Return, which only selects,
and passed anyway because it asserted "a window exists", and (b) asserted
nothing falsifiable in 7 of 10 tests. **The pattern is that these tests fail in
ways that accuse the app.** Fixed by finding the tile as an ELEMENT
(`MuseUITests/GridTileFinder.swift` — tiles are buttons labelled with their
filename) and clicking its own centre. No test now depends on the window's size.
Rule going forward: **a drive test must locate what it clicks, never compute
it.**

**Round 9 note — the architecture map had pre-existing rot (now fixed).** A `.swift` name in
`docs/architecture-map.md` that no longer exists on disk: three are stale
CURRENT-file listings from earlier commits (`MetadataImportSheet.swift`,
`CoordinateReader.swift`, `CoordinateBackfill.swift` — the last two are already
described as deleted in prose elsewhere, so only the first is misleading). Round
Round 9 first fixed only the entry its own diff broke, to keep the change
scoped; the owner then asked for the rest, so all three are corrected — the
Spec 01 section listed `CoordinateReader`/`CoordinateBackfill` as current while
the Spec 02 section said they were deleted, and `MetadataImportSheet.swift` had
been superseded by the shared import run/report cards.

**Deliberately NOT mechanized** (add it to Part 3's list): a grep for
`.swift` names that don't exist on disk cannot tell a stale CURRENT-file
listing from a legitimate historical mention — and the map is full of the
latter on purpose ("`RegionMath` was here until…", "`CullStore` went the same
way"), because recording why something was removed is the map's job. A check
that fires on those is one people learn to ignore. The sweep is worth RUNNING
by hand in a review round; the triage is the human part.

**Round 7 correction.** An earlier draft of this file recorded "no unrun lenses
identified" — written before actually looking, and wrong. The five above came
out of ten minutes of genuinely trying. Treat "I can't think of one" as a signal
to look harder, not as an exit condition; the exit condition is this table being
empty *after* a real attempt.

When this section is empty and the audit is green, **static review is done**.
Further confidence has to come from running the app, not from reading it.

---

## Round 10 (2026-08-02) — the editor adjustments batch

Ran against the batch's own diff. Two lenses moved out of Part 2 as a result.

**"Geometry computed in two places" — RUN, and it paid.** The sweep found the
crop card writing rects in one coordinate space and the renderer reading them
in another. `EditRenderer.applyGeometry` crops FIRST and then flips and
quarter-turns, so `GeometryParams.crop` is in SOURCE coordinates — but the
editor displays the photo with those turns already applied, and the overlay
stored what the user drew straight into `crop`. Rotate a landscape photo 90°,
crop the top of what you see, and you got the LEFT band of the original. This
is the exact failure `applyGeometry`'s own comment predicts, written by someone
who saw it coming and could not enforce it from there.

Fixed with an explicit space conversion (`CropDragMath.sourceRect(fromDisplay:)`
/ `displayRect(fromSource:)` / `displayAspect(source:quarterTurns:)`), applied
at every boundary: Apply, preset fitting, the aspect lock, and re-entry.
Round-tripped in tests over all four turns × both flips.

**The same sweep found a second instance of the same class.** Side-by-side
compare makes the canvas twice as wide as the photo
(`EditorCanvasGeometry.contentAspect`), so a crop frame drawn over it spans
both panes and maps to nothing real — and nothing prevented both modes being
on. Crop, compare, the eyedropper and tone-zone targeting are now mutually
exclusive: one owner of the canvas at a time, enforced in `didSet` on all four.

**"Undo/redo coherence" — RUN.** The pending crop rect is expressed in display
space, which the draft's own rotation defines, so any geometry change
invalidates it. The crop card cannot know about every path that replaces the
draft wholesale — applying a preset, pasting adjustments, restoring a snapshot,
Reset, undo, redo — so the resync moved into `EditSession.draft`'s `didSet`,
which is the one place all of them pass through.

**Also fixed, from the batch's own QA:** the aspect lock enforced in normalized
space (a 1:1 lock on a 3:2 photo produced a 1.5:1 rect — and the test covering
it asserted `w == h`, which is the bug restated); `AutoToneStats.targetSpread`
at 0.62 against a normal photo's ~0.9, so Auto Light drove contrast NEGATIVE on
almost every image; and the tone-zone hover firing on card expansion, because
`.onHover` fires when a view appears under a stationary cursor.

**Lens worth adding, not yet run:** *a control's coordinate space vs the
renderer's*. Distinct from "geometry computed in two places" — that is about
duplicated math, this is about the same math being correct in two different
frames of reference. The crop bug was invisible to the duplication sweep
because there was no duplication; there was one calculation, in the wrong space.

---

## Round 7 findings (2026-08-01)

**R7-1 (med) — Spec 03 §5 "Region similarity" was specified and never built.**
The spec describes a full feature: crosshair cursor over the hero stage, a drag
that draws a marquee, `RegionSearch.minSide = 24`, embed the crop, run a similar
search labelled "region", and an Escape branch that exits region mode instead of
the viewer. What exists is `Components/RegionMath.swift` — the pure geometry
helper — **and nothing else**. No `regionMode`, no `RegionSearch`, no marquee,
no crosshair. Verified by symbol sweep across `Muse/` (app + tests).

This is the branch's THIRD instance of the same failure: the grid cull badge
(caught in round 1, slice 6) and the five modals with no Escape branch (round 1,
F16) were the first two. The pattern is specific and worth naming — the *pure,
testable* part of a feature lands, gets unit tests, and the UI that would make it
reachable does not. Tests pass, so nothing complains.

**RESOLVED 2026-08-01 — the owner dropped the feature.** `RegionMath.swift` and
its tests are deleted. The reasoning is worth keeping, because it is the argument
against building it rather than an oversight: whole-photo "Find Similar Photos"
already ships (a CLIP `similar:` search off the grid's right-click menu), and
anything with a NAME is already reachable by typing it, since auto-tagging covers
a fixed vocabulary. Region mode would only have added "more like this crop" for
visual qualities that have no word — a narrow refinement of a feature that works.
**Spec 03 §5 is cancelled, not pending. A future round must not re-file it as a
gap**, and must not "restore" `RegionMath` as accidentally-deleted dead code.

**R7-2 (low) — two dead view files removed.** `Views/BreadcrumbView.swift` (53
lines, phase 0.5, unreferenced, and its doc comment promised clickable
navigation the plain `Text` segments never implemented) and
`Views/ImageDetailPanel.swift` (15 lines, self-described "Phase 0 placeholder",
superseded by `ViewerInfoColumn`). Both had zero references; the project uses
Xcode 16 `fileSystemSynchronized` groups so neither had a `pbxproj` entry to
update. Release build stays green.

**R7-3 (note, not a fix) — multi-instance is a DEV hazard, and it is live on
this machine.** `Database.swift`'s comment states the design assumption
outright: *"Single writer, single process."* That assumption is sound for
shipping — the share extension genuinely does not open the database (verified:
no GRDB, no `Database.` reference in `MuseShareExtension/`), and LaunchServices
will not start a second instance of the same bundle by ordinary means.

But GRDB's `busyMode` defaults to `.immediateError` and Muse never overrides it,
so a cross-process write collision throws `SQLITE_BUSY` **immediately, with no
retry** — and a great many writes are wrapped in `try?`. Two instances were
running on the dev machine during this review (launched via `open -n` / Xcode).
Consequence for the G1 runtime pass: **quit all but one instance before driving
the app**, or you will chase phantom "my edit didn't save" bugs that are an
artifact of the test setup, not defects. Not filed as a code change, because for
a shipping user the situation is unreachable.

---

## Part 3 — what is deliberately NOT mechanized, and why

Not every rule can be a grep, and pretending otherwise produces checks that cry
wolf until they are ignored. These stay human:

- **Architecture-map entries vs. the filesystem.** The map deliberately keeps
  historical mentions of deleted files (why something went, so it isn't
  re-added), and no grep separates those from a stale current listing. Sweep it
  by hand in a round; don't automate the triage. (Round 9.)
- **"Manual tags beat vision tags."** A semantic precedence rule, enforced by a
  `UNIQUE` constraint and branching. Pinned by tests, not greppable.
- **Fail-closed root visibility** (`Housekeeping.pruneUnreachable`,
  `PathReconciler.rootReachable`). The bug is a missing *guard*, and "is this
  guard present and correct" is a code-reading question. `HousekeepingTests` and
  `PathReconcilerTests` are the enforcement.
- **The shared-row SPLIT on edit-in-place.** Correctness depends on which branch
  runs under which alive-path count. `IndexerReconcileTests` guards both
  directions.
- **Localization coverage.** `xcodebuild -exportLocalizations` already reports
  untranslated counts; a grep would duplicate it badly, and the standing trap
  (a concatenation where only one half is wrapped) is invisible to both.
- **Drive metadata stripping.** The invariant is "every uploaded image is
  stripped *and re-verified clean*, fail-closed" — a property of a runtime
  sequence, not of the source text. `DriveSharePublishGuardTests` covers it.

---

## Appendix — the mechanized checks

`scripts/audit-invariants.sh`, 20 checks. Each was a rule broken once, shipped,
and paid for. Run it from the repo root; exit 0 means green.

| ID | Rule |
|---|---|
| `AV-1` | No bare `AVURLAsset(url:)`/`AVPlayer(url:)` — reference-movie egress |
| `AV-2` | QuickLook confined to 4 reviewed entry points — video **and** audio |
| `NET-1` | `URLSession` confined to the 4 sanctioned network paths |
| `NET-2` | Remote bodies bounded before they land in memory |
| `NET-3` | Drive OAuth stays PKCE, secretless, `drive.file` |
| `INT-1` | No `Int(x.rounded())` on file-declared numbers |
| `DEL-1` | `removeItem`/`unlink` confined to Muse's own temp+cache paths |
| `OUT-1` | `RenderedOutput`'s init stays `fileprivate` (the export choke point) |
| `DEC-1` | Every full-raster decode site guards its budget |
| `ENT-1` | `Muse-Debug.entitlements` carries no iCloud keys |
| `EDIT-1` | `Editing/` imports neither AppKit nor SwiftUI |
| `ARCH-1` | `Float16` stays inside `#if arch(arm64)` — Intel must compile |
| `DOC-1` | CLAUDE.md never claims work is unmerged that git says IS merged |
| `DOC-2` | CLAUDE.md's named release tag is the newest real tag in git |
| `HDR-1` | No sRGB render path that can't tone-map an HDR source |
| `PFI-1` | The one-alive-path-per-file tests still exist |
| `PFI-2` | `content_hash` is not UNIQUE outside the frozen v1 migration |
| `EXP-1` | No `.atomic` write into a user-chosen destination (it overwrites) |
| `EXP-2` | `.atomic` is never combined with `.withoutOverwriting` (Foundation traps) |
| `TCC-1` | PhotoKit use is matched by a purpose string on the APP target |

**Every check has been negative-tested**: verified green on a clean tree, then
verified to FAIL when its violation is injected. A checker that has never failed
is not known to work. If you add a check, negative-test it the same way.

Two notes on scope, so they are not re-litigated:

- `EDIT-1` duplicates `EditingModuleImportTests` on purpose. That test **skips**
  on this machine — the test host is the sandboxed app, and the checkout lives
  in `~/Documents`, which the sandbox denies. A source-tree check inside the
  suite passes vacuously exactly where it is needed. The script has no sandbox.
- `NET-2` deliberately excludes `Sharing/Drive/`. Those calls are
  OAuth-authenticated, user-initiated, TLS to googleapis.com, returning small
  JSON — unlike the announcements feed, which is automatic, at every launch, and
  unauthenticated. Reasoning is in the script at the exclusion.


---

## Round 12 (2026-08-03) — the editor workspace

Ran the registry against `feat/next-155`. Seven findings, all in this round's
own work, plus two Part 2 lenses closed.

**The one worth remembering: a hand-stepped animator can step the wrong value
and look exactly like a working one.** `stepCanvasRefit` walked
`chromeProgress` frame by frame to make the photo glide into a freed column.
But `chromeProgress` describes the hide-UI eye, and by the time a column
emptied it had already settled at 1 — so thirteen frames each recomputed an
identical inset. The photo snapped. Nothing failed, no test caught it, and the
code, the commit message and the spec all said "glides". The fix was to make
the EMPTIEDNESS itself continuous (`panelInsets(leftEmptied:rightEmptied:)`,
0…1) and walk that, because the emptiness is what changed.

The general shape: **when hand-stepping an animation, check that the value you
are stepping is the value the target actually reads to produce the difference
you want.** Stepping a settled value is a no-op that costs 13 frames of work
and reads as an animation in the source.

**The second worth remembering: `assertNoRowIsClipped` would have passed on the
bug it was written for.** It compared the last row's bottom to
`app.windows.firstMatch` — the window, hundreds of points taller than the card
— so any content anywhere in the card satisfied it. This was written in the
same session that had just deleted a different vacuous assertion, which is the
point: knowing about the failure mode does not prevent it. What does prevent it
is **running the negative** — removing the fix and confirming the test goes red.
That is now the standard for any guard written for a specific bug, and it is
how this one was rewritten (against the presenter's ScrollView, which IS the
card's rect) and confirmed.

**The third worth remembering: a relative undo is not an undo.** The
window-resizing test shrank the window by 420pt and restored it by dragging
+420 back. With a `defer` around it that looks airtight — but if the window did
not start where the test assumed, the "restore" moves it somewhere new. It left
the frame at 532pt, macOS persisted that, and a test two positions away
(`testCompareSideBySideOpens`, untouched by this branch) failed because two
grid tiles no longer fit. The failure pointed at compare; the cause was a
padding test. Round 9 already recorded that these suites *"fail in ways that
accuse the app"*; this is the same shape with the suite accusing itself. The
resize is gone — it proved nothing the padding check did not.

**And the pre-existing one it flushed out.** Resetting the window frame made
`testCompareSideBySideOpens` fail — a test this branch never touched. It was
still aiming at two tiles by window fraction, the pattern round 9 removed
everywhere else and missed here, and it failed saying *"Compare is broken"*
when compare was perfect. `GridTileFinder` grew `photoTiles(limit:)` and the
test now locates both tiles. One `withNormalizedOffset` remains in the suites
(a drag across the middle of the canvas, which needs a region rather than an
element) and is benign.

**Also fixed:** dead code created by this round's own diff (`column(of:)`);
two per-frame allocations on the canvas and drag paths; reorder mode being
mouse-only while its VoiceOver hint promised a drag; a window-resizing test that
restored the frame only when it passed; and a localization key orphaned by
rewording that same hint.

---

## Round 15 (2026-08-04) — the standing registry, plus six new lenses

Ran against `feat/next-155`. The audit was green at 17/17 going in, and the
unit suite at 2,146; both are the starting point, not the result.

**The one worth remembering: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes
a forgotten keyword a performance bug with no visible cause.** This project
opts every declaration into main-actor isolation unless it says `nonisolated`.
The codebase knows that and marks its hot paths carefully — `VisionServices` is
`nonisolated`, its Vision work genuinely runs off-main, and
`HybridClusterer.cluster` is both `nonisolated func` AND wrapped in a
`Task.detached` at the call site. But `VisionTagger`, which *calls*
`VisionServices`, was never marked. So the decode, classify and OCR ran
off-main exactly as designed, and then every line after the `await` — the
palette k-means, the classification curation, the colour naming, the style
classify — resumed on the main thread. Measured: **22 ms per 4096×2731 image,
once per analyzed photo.**

Nothing in the source shows it. There is no `await` at the call site to notice,
no warning, no test that can observe it. It is invisible to reading and to the
suite alike, which is why the fix is pinned by **compile-time** tests
(`AnalysisIsolationTests`): each body calls the helpers from a `nonisolated`
context with no `await`, so a regression stops the file compiling rather than
failing an assertion. The same lens found `BackupDocument` — a pure JSON codec
— main-isolated, which pinned both the export encode and the restore decode of
a whole-library archive to the main thread no matter how far off-main the
caller believed it had moved them.

**The second: verify the flag, don't reason about it.** `collisionSafeURL`
carries an unusually clear promise in its own comment — "an export can never
overwrite a file the user already has — the one way this feature could destroy
data" — and then the write used `.atomic`. Rather than argue about how narrow
the window is, all three combinations were run:

| flag | result |
|---|---|
| `.atomic` | no throw, existing file **replaced** |
| `.withoutOverwriting` | throws, existing file intact |
| `[.atomic, .withoutOverwriting]` | **fatalError** — "withoutOverwriting is not supported with atomic" |

That third row is why `EXP-2` exists. The intuitive way to harden an atomic
write is to add the exclusive flag beside it, and that edit crashes the app.
A check that fires on the fix people will reach for is worth more than one that
fires on the bug.

**The third: a check can pass on its own violation, and mine did.** `TCC-1`
greps for `NSPhotoLibraryUsageDescription`. The negative test renamed the key to
`NSPhotoLibraryUsageDescriptionXX` — which still contains the string — and the
check stayed green. Caught only because the negative test was actually run
rather than assumed. Re-aimed at `<key>…</key>` and re-injected by deleting the
key outright. Round 12 recorded that knowing about vacuous assertions does not
prevent writing them; this is the third round in a row to prove it.

**Also fixed:** the `edit_luts` `(size, blob)` pair, trusted from a restored
archive into a Core Image filter that reads `size³ × 4` floats without checking
either (refused at `LutRegistry`, the render choke point, AND filtered at the
restore boundary); the geometry render stage, the only one of eleven that never
called `.clamped()`; `NSPhotoLibraryUsageDescription` set on the share
extension — which contains no Photos code — while the app that calls PhotoKit
had none; three `NSLog`/`print` sites publishing user folder and file names to
the unified system log; and `LutStore.importCubes`, which parsed up to 64 MB of
`.cube` text on the main actor.

**Ended at:** audit 20/20 (three new checks, all negative-tested), unit suite
2,167 green, Release build warning-free.
