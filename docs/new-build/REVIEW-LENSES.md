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
| Self-QA of the round's own diff | 3, 6 | 4 + 1 defects in the review's own work |
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
| **Spec → code existence** (is every specified symbol real?) | **7** | **1 finding — Spec 03 §5 region similarity never built** |
| **Unreferenced / dead code** | **7** | 3 files; 2 removed, 1 kept as evidence |
| Schema **downgrade** (old build opens a newer DB) | 7 | clean — GRDB no-ops, columns nullable, backfills self-heal |
| Nil-`dbQueue` fallout (what runs when the DB fails to open) | 7 | clean — every consumer `guard`s and no-ops; the delete path can't be called at all |
| Observer / resource lifetime (leaks, un-removed observers) | 7 | clean — both `NotificationCenter` sites are static + install-once |
| Accessibility on the surfaces THIS branch added | 7 | broadly labelled; the one gap was in dead code |
| Cross-process DB access (multi-instance, share extension) | 7 | clean for shipping; **dev-machine hazard** — see note below |

## Part 2 — lenses NOT yet run

Append here the moment you think of one, even if you are not running it now —
an unrun lens on the list is worth more than a good idea that evaporates.

| Lens | Why it might matter |
|---|---|
| Disk-full / write-failure behaviour | Every `try?` around a write turns a full disk into silent data loss. Untested. |
| Sparkle update path integrity on THIS branch | The appcast/EdDSA path has not been re-reviewed since Spec 01 added `Commerce/`. |
| TOCTOU on user paths | A file swapped between the `fileExists` check and the read. Round 5 covered prefixes, not timing. |
| Undo/redo coherence across editor + delete-undo | Two independent undo stacks now exist; nobody has checked they don't confuse each other. |
| Long-session memory growth (retain cycles, not allocation shape) | Round 6 checked allocation *shape*; SwiftUI/Combine retain cycles are a different failure. |

**Round 7 correction.** An earlier draft of this file recorded "no unrun lenses
identified" — written before actually looking, and wrong. The five above came
out of ten minutes of genuinely trying. Treat "I can't think of one" as a signal
to look harder, not as an exit condition; the exit condition is this table being
empty *after* a real attempt.

When this section is empty and the audit is green, **static review is done**.
Further confidence has to come from running the app, not from reading it.

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

`RegionMath.swift` is **deliberately kept** rather than deleted: it is a correct,
tested component of an unbuilt feature, and deleting it would erase the evidence
that the feature is missing. It is unreferenced by the app on purpose.

**Deciding what to do with R7-1 is the owner's call, not a review's** — building
the feature is new product work with UX judgment in it, not a bug fix.

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

`scripts/audit-invariants.sh`, 12 checks. Each was a rule broken once, shipped,
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
