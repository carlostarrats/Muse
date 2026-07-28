# Hero viewer open/close polish — handoff

**Date:** 2026-07-28
**Branch:** `feat/next-140` (analysis performance; all perf work committed + verified)
**Status:** three OPEN cosmetic issues in the hero viewer, owner-reported, not yet fixed.

These are **pre-existing** and unrelated to the performance work. They surfaced
because the analysis fix (111 s → 0.6 s) left the viewer's wash exposed long
enough to actually look at it.

---

## Hard-won method note — read before touching this view

Six attempts were spent on the open-flicker by READING CODE and reasoning. All
six were wrong. Two A/B substitutions found it in two builds.

**For anything in this view: instrument or substitute. Do not reason.**

What worked:
- `BackdropTrace`-style timeline logging (ms-stamped state transitions written to
  a file). NOTE: Muse is **sandboxed** — a hardcoded `/tmp` path is silently
  denied. Use `NSTemporaryDirectory()` and read from
  `~/Library/Containers/com.tarrats.Muse/Data/tmp/`.
- Env-var A/B switches (`MUSE_NO_MATERIAL`, `MUSE_NO_PARTING`) launched via
  `open -a <app> --env KEY=1`, to substitute one component at a time.

What didn't: reading the code and forming a theory. Five separate plausible
theories, all wrong.

---

## OPEN ISSUE 1 — close pauses just before finishing

**Report:** "it gets small, and then right before it gets fully finished,
there's a pause." Initially described as random; later as consistently
just-before-the-end.

**Not yet investigated.** Interacting timings in the close path, all tuned and
all documented in CLAUDE.md's durable constraints:
- backdrop fade-OUT is 0.3s, deliberately UNDER the 0.36s subtree unmount
- the return flight (`HeroStage.close()`), which lands on the tile's DRAWN-IMAGE
  rect via `ViewerGeometry.fitWithin`, not the raw tile rect
- `PartingField` converge (easeOut — an easeInOut read as stop-start jitter)
- `ToolbarFade` re-assert + the toolbar recolour
- `startClose()` owns the whole close; Escape must ONLY set `viewerClosing`

**Suggested approach:** trace-stamp every close milestone (startClose,
backdropVisible=false, flight start/end, onCloseFinished, finishClose,
unmount) and find the gap. A pause "right before fully finished" smells like
something awaited between flight-end and unmount.

## OPEN ISSUE 2 — open motion curve differs landscape vs portrait

**Report:** "the landscape images in the open, the motion curve is different...
opens faster... not nearly as nice as the curve for a portrait."

**An earlier explanation that this was purely file SIZE (the only portrait
fixture is also the 115 MP one) is probably WRONG** — the owner is describing the
CURVE, not the duration.

**Real candidate mechanism:** the flight starts/lands on the DRAWN-IMAGE rect
(`ViewerGeometry.fitWithin(image.size, sourceFrame)`), not the tile rect. In a
fixed-aspect grid layout a landscape image letterboxes differently from a
portrait one inside the same tile, so flight distance and scale ratio genuinely
differ by aspect. Same duration + different distance = different apparent curve.

**To verify:** generate a MATCHED pair (same pixel count, one portrait one
landscape) and compare. If the curves still differ, it's the fitWithin geometry,
not size.

## OPEN ISSUE 3 — right-hand info column flickers during open

**Report:** "when the image is opening, I see the information on the right hand
side, there's a kind of flickerish thing happening."

**NEW — appeared/was noticed after the backdrop work.** Not yet investigated.

Candidates (unverified):
- `ViewerInfoColumn` re-renders as `details` (~50ms), `metadata`, and
  `naturalSize` each land separately, resizing the column each time.
- `paletteResolved` gates placeholder swatches specifically so the actions row
  mounts in its final position — if that's mis-timing now, the row shifts.
- `chromeVisible` fades at 0.4s with a 0.15s delay, overlapping those state
  landings.

**Check first whether this predates `feat/next-140`** (stash the branch, open a
large image on `main`). If it predates it, it's a separate bug; if not, suspect
the `loadDetails` reordering — quickPalette is now lazy (DB-miss only) rather
than started concurrently.

---

## What IS done, committed and verified on this branch

Performance (the branch's actual job), all measured not assumed:
- Analysis **111,147 ms → 620 ms** on a 115 MP scan; peak memory +1,077 MB → +105 MB.
  Output identical — same labels, feature print, dominant colour, and 918/918 OCR
  chars on a document scan.
- RAW `dominant_color` was WRONG (unmanaged read of ITU-R 2100 PQ). Fixed; RAW
  colour values shift on re-analysis, which is the fix landing.
- Clustering: exact same algorithm, tiled `vDSP_mmul`. 10x/62x/96x at n=500/2000/5000.
  Differs from the scalar reference only for pairs within ~3e-7 of the threshold.
- Analyze loop 3-wide; recluster gated on embeddings written.
- **A regression I introduced and reverted:** weighting thumbnail permits by size
  made folder-open 2.6x SLOWER (592 ms → 1562 ms). The memory pressure it
  defended against was hypothesised, never measured.
- Unified progress pill (`WorkProgress`), monotonic, completes to 100% before
  dismissing. **Finish-to-100% is NOT yet owner-verified** — needs a fresh folder.
- Hero-open flicker: TWO independent causes, both fixed (see ViewerBackdrop docs).

## Fixture generators

`scratchpad/perf/` has `MakeFixtures.swift`, `Round2.swift`/`Round3.swift`
(fresh unanalyzed files — vary the `shift` values for new content hashes),
`Bench.swift`, `OpenCost.swift`, `PalCompare.swift`, `ClusterBench.swift`.
Fixture folders live on the Desktop. Files must have UNIQUE pixel content or they
dedupe onto one content-hash row and won't re-analyze.
