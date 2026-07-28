# Hero viewer open/close — investigation record

**Date:** 2026-07-28
**Branch:** `feat/next-140`
**Status:** RESOLVED. All five reported issues found and fixed. Kept because the
*method* is the reusable part, and because four of the five root causes are
counter-intuitive enough to be re-introduced by a well-meaning edit.

The load-bearing rules extracted from this are in CLAUDE.md's durable
constraints; the narrative is in `docs/session-log.md`.

---

## Hard-won method note — read before touching this view

Across the whole investigation, **every fix found by reading code and reasoning
was wrong, and every fix found by instrumenting the running app was right.**

- Open flicker: six reasoned attempts, all wrong. Two A/B substitutions found it
  in two builds.
- Close stall: three reasoned attempts, all wrong. One `sample` profile found it
  immediately — a single property setter holding the main thread for 282 ms.
- Close→reopen→close: three more reasoned attempts, all wrong, including two
  plausible-sounding animation theories. A state trace showed the close sequence
  was *clean*, which eliminated the entire category and pointed straight at a
  geometry write instead.

**For anything in this view: instrument or substitute. Do not reason.**

What works:
- **`sample <pid> <seconds> <ms> -file out.txt`** on the running app, then
  aggregate leaf frames per symbol. This is what surfaced
  `AppState.viewerDismissing.setter` at 282 ms — a result no amount of reading
  would have produced.
- **A timeline trace** — ms-stamped state transitions appended to a file. NOTE:
  Muse is **sandboxed**, so a hardcoded `/tmp` path is silently denied. Write to
  `NSTemporaryDirectory()` and read from
  `~/Library/Containers/com.tarrats.Muse/Data/tmp/`. NSLog is NOT a substitute —
  its output did not reach `log stream` here at all.
- **Env-var A/B switches** (`MUSE_NO_MATERIAL`, `MUSE_NO_PARTING`) launched via
  `open -a <app> --env KEY=1`, substituting one component at a time.

A note on cost: a profile is only useful if the bug happens *during* the capture
window. Two captures were wasted on windows where the app sat idle.

---

## The five causes

### 1. Open flicker — TWO independent causes

- Animating **opacity on `.ultraThinMaterial`** re-composites the blur every
  frame. Fixed by never fading the material in; only its tint animates.
- The tint's **opacity changed at the same time as its colour**
  (`0.45 → 0.78` as the palette resolved). Fixed by holding tint opacity
  constant.

Both live in `ViewerBackdrop`, which now takes a real `closing` flag rather than
a "not yet visible" one.

### 2. Flight endpoint was the raw tile rect, not the drawn-image rect

`sourceRect` fell back to `sourceFrame.size` when `image` was still nil — and
`fitWithin(frame.size, frame)` returns *the frame itself*. So the open flight
departed from the raw tile rect, violating the 2026-07-07 durable constraint.

A landscape image letterboxes heavily inside a squarer tile, so its true drawn
rect is far shorter than the tile; starting from the tile rect made the flight
too short — same duration, less distance, so it read as "almost instant" with a
wrong curve. Portrait letterboxes less, so it looked nearer correct. **This is
aspect geometry, not file size** — an earlier explanation blaming the 115 MP
fixture's size was wrong (that fixture was also the only portrait one, a real
confound).

Fixed by deriving the endpoint from the file's TRUE pixel dimensions
(`ImageHeaderSizeCache`), so it is correct from the first frame and identical on
open and close.

### 3. Filesystem I/O from a SwiftUI computed property

The header read added for (2) was called from `sourceRect` — a computed property
re-evaluated on every body pass, i.e. every frame of an animating flight — and
memoized in an `NSCache`, which evicts under exactly the memory pressure a
659 MB image open creates. Measured 17.7 ms per read on `bigscan_115mp.tif`.

Fixed by resolving once into view state, from a never-evicting table warmed
off-main by the thumbnail pass.

### 4. A 282 ms main-thread stall mid-close

`appState.viewerDismissing = true` was wrapped in `withAnimation`. The flag is
`@Published` on the monolithic `AppState`, so the write re-evaluates the whole
shell — sidebar rows, every mounted tile, the tag chips — and inside a global
animation transaction SwiftUI builds animated transitions for all of it
synchronously.

Symptom: the image froze part-shrunk with the backdrop still up, then jumped. On
the largest files the block swallowed the entire flight, which read as "it closes
instantly with no animation."

Nothing needed the transaction: the toolbar returns via `ToolbarFade` (an AppKit
alpha fade driven by an `.onChange`) and the tile reveal is a value-scoped
`.animation(_:value:)`.

### 5. Close → reopen → close

`loadFullRes()` ends with `withAnimation { displayRect = fitRect }` — the write
that flies the image out to full screen once the sharp decode lands. It had **no
`isClosing` guard.** A 115 MP TIFF decodes in ~600 ms and an open-then-Escape
closes at ~450–600 ms, so on big scans the decode routinely arrived *inside* the
close flight, animated the shrinking image back out, and then the unmount snapped
it away. Small files always decoded before a close could start, which is why only
the scans showed it.

Two wrong theories were tried first (an animation reversal, then the mid-flight
retarget). The state trace ruled both out by showing a clean single close.

---

## Fixture generators

`scratchpad/perf/` has `MakeFixtures.swift`, `Round2.swift`/`Round3.swift`
(fresh unanalyzed files — vary the `shift` values for new content hashes),
`Bench.swift`, `OpenCost.swift`, `PalCompare.swift`, `ClusterBench.swift`.
Fixture folders live on the Desktop. Files must have UNIQUE pixel content or they
dedupe onto one content-hash row and won't re-analyze.

**For flight-geometry work specifically:** generate a MATCHED pair — same pixel
count, one portrait and one landscape — in a fixed-aspect grid layout. The
round2/round3 fixtures are not suitable: their only portrait file is also the
biggest, which is what caused the size-vs-aspect confusion in the first place.

## Still open (cosmetic, low priority)

- The right-hand info column can settle in steps during open, as `details`
  (~50 ms), `metadata`, and `naturalSize` land separately. `loadDetails()` now
  runs all three concurrently, which improved it; whether any visible stepping
  remains has not been re-verified since the stall fixes landed.
