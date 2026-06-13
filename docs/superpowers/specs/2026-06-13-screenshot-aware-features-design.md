# Screenshot-aware features — design

**Date:** 2026-06-13
**Status:** Approved design, ready for implementation planning
**Scope:** Two features inspired by the "Pool" screenshot app, adapted to Muse's
local-first, zero-network, free, Apple-Intelligence-native identity.

## Background

The Pool app and its research argue that screenshots are a uniquely rich signal of
a person's intent and taste. The business thesis behind it is a cloud data-harvesting
play (collect the signal, sell the intelligence layer) — the opposite of Muse. But the
*user-facing* observation is real and Muse is well positioned to serve it **on-device,
for the user, sold to no one.**

We evaluated five candidate ideas and kept the two that pass a strict test —
**"does it help the user *do* something (find / organize / act)?"** rather than merely
*"tell them something about themselves"* (the latter is the data-selling output with no
user value). The kept features:

- **Feature 1 — Screenshot intent-typing → collections** (primary).
- **Feature 4 — Galaxy "taste map" trial** (small, may be cut after we see it).

### Explicitly out of scope

- **Burst detection / session metrics / "things you keep coming back to"** — these are
  insight/metric outputs whose value accrues to a data buyer, not the user. Dropped.
- **Feature 5 — surfacing a source link from a screenshot.** Investigated and dropped.
  Empirically verified on the user's real files: a screenshot (`Screenshot 2026-…png`)
  carries **no** source URL — not in pixels, not in EXIF, not in extended attributes.
  iOS/macOS never write the originating page URL into a screenshot. The only on-device
  link signal is `kMDItemWhereFroms`, which exists for **downloaded** images
  (verified on `HKkB3jGaMAAqaX0.jpeg`), not screenshots. Recovering a screenshot's origin
  requires a networked reverse-image search + paid API — the exact network/cost feature
  Muse rules out. The user's value ("link to the original source") only exists for real
  screenshots via that impossible path, so #5 was cut.

## Constraints (inherited from Muse identity)

- **Zero network.** Sandbox has no `network.client`. All work on-device.
- **Free, no cost** to the developer or user. No metered APIs.
- **Apple-Intelligence-native, gracefully degrading.** Foundation Models is gated to
  macOS 26+ capable Macs; Muse runs on 14.6+. Features that need FM must degrade like the
  existing FM-gated collection namer does.
- **Privacy.** OCR text and all derived signal stay on the machine. "Data Not Collected."

---

## Feature 1 — Screenshot intent-typing → collections

### Summary

Screenshots get automatically classified by *what they're for* (recipe, shopping, place,
receipt, …) and grouped into collections named for those buckets. This gives screenshots
an **intent** label that the existing visual/semantic clustering can't produce, because
intent lives in the OCR text, not the pixels' look.

### Decisions (all confirmed)

| Decision | Choice |
|---|---|
| Scope | **Screenshots only** (Option A). Non-screenshot images are untouched. |
| Grouping | **Hybrid** — fixed buckets where confident, emergent clustering for the rest. |
| Buckets | All 10 (below). |
| Gating | **FM-gated; emergent-only fallback** on non-AI Macs (matches existing namer). |
| Engine integration | **Clean two-track** (Approach 3): typed screenshots go to their intent collection and are excluded from emergent clustering. |
| Data model | New `intent` column on `FileRow`. |
| UI | **Identical** to existing collections — no new UI. |

### The 10 fixed buckets

`recipe` · `shopping` · `places` · `receipt` · `quote` · `article` · `conversation` ·
`event` · `design` · `code`

Display names: Recipes, Shopping, Places, Receipts, Quotes, Articles, Conversations,
Events, Design, Code. (Display-name map is static; no FM call needed to name intent
collections.)

### Data model

- Add `intent: String?` to `FileRow` (one bucket key, or `nil`).
- Add `intent_model_version: String?` (lets us re-classify later without re-running Vision;
  also drives the one-time backfill).
- Migration `v5_intent` adds both columns (nullable, no backfill in the migration itself).

### The classifier

- New `IntentClassifier` in `Intelligence/Core/` (alongside `CollectionNaming`, which it
  mirrors in structure and availability gate)
  (`#available(macOS 26.0, *)` + `SystemLanguageModel.default.availability == .available`).
- **Input:** the OCR text (first ~600 chars) + top vision classification labels. Both are
  already computed during the Vision pass.
- **Prompt:** constrained single-label classification into one of the 10 keys **or `none`**,
  via `LanguageModelSession` (same usage pattern as the namer). Response validated against
  the 10 keys; anything off-list → `nil`.
- **Prefer-`none` bias:** the prompt instructs the model to choose `none` when unsure.
  A misfiled screenshot is worse than an unsorted one; `nil` simply routes to emergent.
- **Output:** one bucket key or `nil`. No confidence column in v1 — the none-bias is the
  gatekeeper. (A confidence threshold can be added later if buckets feel loose.)
- **No heuristic fallback** (decision A): non-AI Macs leave `intent = nil`.

### Analysis flow

In `AnalyzePipeline.analyzeOne`, immediately after the Vision block writes
`caption`/`dominant_color`/etc. (same `Task.detached` pass):

1. If the file is **not** a screenshot (existing `StyleKind` "screenshot" rule) →
   `intent = nil`; done.
2. If it **is** a screenshot **and** FM is available → run `IntentClassifier` →
   write `intent` + `intent_model_version`.
3. If FM is unavailable → leave `intent = nil` (flows to emergent).

**Incremental + backfill.** Vision re-runs only when `analyzed_hash ≠ content_hash`.
- New/changed screenshots are classified in the normal pass.
- Screenshots analyzed *before this feature shipped* (their `analyzed_hash` already matches,
  so Vision won't re-run) are handled by a **one-time backfill** on launch: find screenshots
  where `intent_model_version` is null, and run **only the classifier** (OCR text already
  stored — no re-Vision). Cheap, runs once.

### Collection building

Extends `CollectionsEngine.recluster()` with an **intent pass that runs before** the
existing emergent clustering:

**Intent pass (new):**
1. Fetch alive screenshots with non-nil `intent`, grouped by bucket key.
2. For each bucket with **≥ 3 members** (tunable default), ensure a collection with a
   *stable id* `intent:<key>`, `model_version = "intent-v1"`, and the fixed display name.
   Membership = those screenshots, `added_by = "auto"`.
3. Below 3 members: no collection yet; the screenshots keep their `intent` value and surface
   once the bucket fills. They are not lost (still in folder, grid, search).

**Emergent track (existing, one change):**
- The emergent clusterer's input set becomes *all files **minus** screenshots that have a
  confident intent* — done by filtering the input, simpler than per-file exclusions. This is
  the clean two-track separation: typed screenshots never pollute an emergent cluster.
- A typed screenshot is excluded from emergent **immediately**, even before its bucket hits 3,
  so collections don't reshuffle under the user as buckets fill.
- Everything else (untyped screenshots, all non-screenshot images) clusters and FM-names
  exactly as today.

**Reconcile / alive / manual edits:**
- Intent collections ride the existing alive-aware counting + reconcile pass (deleting
  screenshots shrinks/hides them automatically).
- Not protected like manual collections, but the stable id means reconcile updates membership
  rather than churning the collection.
- Manual member removal writes to `collection_exclusions` and is respected.
- If the user **renames** an intent collection, pin the name so reconcile won't clobber it
  (same protection manual edits already get).

### UI

- **No new UI.** Intent collections render with the existing Cosmos card (mosaic · name ·
  count), the existing in-collection editable header, hide, and manual add/remove.
- The only differences are under the hood: membership decided by `intent`, initial name from
  the static map. Once surfaced they behave like any auto collection (renamable + hideable).

---

## Feature 4 — Galaxy "taste map" trial

### Summary

Reframe the existing Galaxy similarity view as a private "taste map," and — the part worth
trialing — **color each screenshot node by its intent bucket** so the clusters become legible.
Non-screenshot nodes stay neutral grey (they have no intent). This directly reuses Feature 1's
`intent` label.

### Decisions

- **Color nodes by intent bucket** (Option B). Screenshots tint by bucket; everything else
  neutral.
- Trial status: small and isolated; if it doesn't land in practice, removing it is just
  reverting the node-color logic. No data-model dependency beyond the `intent` column.

### Implementation notes

- In `GalaxyView` / `GalaxyModel`, when assigning a node's color, look up the file's `intent`
  and map to a fixed per-bucket color; `nil` intent → existing neutral treatment.
- Optional (defer unless trivial): a small legend. Not required for the trial.
- Depends on Feature 1 (needs the `intent` column populated). Build Feature 1 first.

---

## Testing

- **Classifier:** label-validation (off-list / `none` → `nil`); prefer-none behavior on
  ambiguous input.
- **Gating:** on a non-FM path, `intent` stays `nil` and emergent clustering still works.
- **Backfill:** pre-existing analyzed screenshots get classified once without re-running Vision.
- **Two-track:** a typed screenshot appears in exactly one intent collection and **not** in any
  emergent cluster; an untyped screenshot still clusters emergently.
- **Threshold:** a bucket with <3 members produces no collection; the 3rd member surfaces it.
- **Reconcile/alive:** deleting screenshots shrinks/hides intent collections; manual removal and
  rename survive a reconcile.
- **Galaxy:** screenshot nodes colored by bucket; non-screenshot nodes neutral; removal is clean.

## Affected files (anticipated)

- `Database/Records.swift` — `FileRow.intent`, `FileRow.intent_model_version`.
- `Database/Database.swift` — migration `v5_intent`.
- `Intelligence/Core/IntentClassifier.swift` — **new**, FM-gated classifier.
- `Intelligence/AnalyzePipeline.swift` — call classifier after Vision; backfill pass.
- `Intelligence/Collections/CollectionsEngine.swift` — intent pass + emergent input filtering.
- `Intelligence/Collections/` (CollectionStore) — stable-id intent collections, name pinning.
- `Views/Spatial/GalaxyModel.swift` / `GalaxyView.swift` — color nodes by intent.
- Tests under `MuseTests/` for the cases above.
