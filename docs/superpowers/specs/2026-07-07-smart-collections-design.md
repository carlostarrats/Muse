# Smart collections — rule-driven collection membership

**Date:** 2026-07-07
**Status:** Design approved, pending spec review
**Scope:** A collection whose membership is defined by **rules** (mail-style) instead of hand-picked files, resolved **live** from the database every time it's shown. Rules over the axes Muse already stores: rating, color, tags, kind, date, filename, size.

## Summary

Right-click a collection → **"Make Smart… / Edit Rules…"**, or **"New Smart Collection…"** from the Collections-page **+**. This opens a mail-style rule builder: a top-level **Match All / Match Any** toggle over a list of rules. A smart collection stores **only its rule set** (JSON on the `collections` row) — it holds **no member rows**. Membership is computed **live** by running the rules against the DB whenever the collection's count or contents are needed. It is therefore always current by construction and can never go stale — there is no re-evaluation trigger to build.

Smart collections are ordinary `collections` rows, so they appear in the sidebar and inherit the existing appearance (icon/color, `v10`), sort order (`v8`), and cover (`v6`) systems for free. They differ from manual/auto collections only in *where their members come from*.

### v1 rule types

| Rule | Matches against | Backing data |
|---|---|---|
| **Rating** | ≥ / = / ≤ N stars | star-glyph tag per `(file_id, parent_dir)` (`StarRating`) |
| **Color** | color name or hex | `files.palette` via the color-search matcher (shared with the color-search spec) |
| **Tags** | has / doesn't have label | `tags` table |
| **Kind** | image / pdf / video / audio / raw / … | `files.kind` |
| **Date** | created/modified within N days / before / after | `files.created_at` / `files.modified_at` |
| **Filename** | contains "…" | alive `paths.absolute_path` basename |
| **Size** | > / < N MB | `files.size_bytes` |

## Non-goals (v1)

- **No per-folder scope.** A smart collection matches the whole reachable library (like search's "All folders"). Folder-scoping is a v2 axis.
- **No materialized membership / triggers.** Live query only (see §3). Upgrade path noted, not built.
- **No new rule types beyond the seven above.** Intent buckets, image dimensions, and "has a note" are deferrable — the data exists but they'd bloat the first modal (YAGNI).
- **No reuse of the dead `smart_searches` table** (see §1).
- Smart collections do **not** participate in AI reclustering (they have no `auto` members to rebuild).

---

## 1. What already exists (verified)

- **`collections`** table + `collection_members (collection_id, file_id, added_by)` where `added_by ∈ {auto, manual}` (`Database.swift` `v3`/`v4`). Auto members are rebuilt on reclustering; manual survive. **Smart collections use neither** — they store rules and resolve live.
- **`CollectionStore`** (`Intelligence/Collections/CollectionStore.swift`) — CRUD; `createManual`, `addFile`/`removeFile` (`added_by='manual'`), `setHidden` (the durable delete), `setAppearance` (`v10`), `setCover` (`v6`), `persistOrder` (`v8`). Membership resolution for existing collections happens here.
- **`CollectionsEngine`** — reclustering + reachability (`hasReachableContent`, `reachableFileCount`). Must learn to **skip smart collections** when reclustering, and to resolve them via the new resolver for counts/contents.
- **Reachability gating** is already load-bearing (durable constraint): a collection's visibility/count is gated on `hasReachableContent`. The resolver's output must pass through the same reachability filter.
- **`StarRating`** — a rating is a mutually-exclusive `★`-run tag per `(file_id, parent_dir)`; `RatingLoader` reads them. The rating rule reuses this.
- **`AssetKind`** — the kind taxonomy for the kind rule.
- **Dead table:** `smart_searches (id, name, query_json)` exists in `v1_schema` (`Database.swift:126`) but has **zero Swift references** — leftover scaffolding. **Not reused** (smart collections must be `collections` rows to get sidebar/appearance/sort). Left in place (dropping it is unrelated churn); a future cleanup migration may remove it.
- **Color matcher** — the `ColorQuery`/`LabColor`/`PaletteMatch` units from the color-search spec. The color rule reuses them (soft dependency, see §7).

---

## 2. Storage — `v12_smart_collections`

A single nullable column on `collections`:

```sql
ALTER TABLE collections ADD COLUMN smart_rules TEXT;   -- JSON SmartRuleSet; NULL = not smart
```

- **`smart_rules IS NOT NULL` ⇒ smart collection.** No separate flag, no member rows.
- Existing manual/auto collections have `smart_rules = NULL` and are entirely unaffected.
- Backup/restore (`Backup/`) must carry `smart_rules` on the collection record (§6).

### Rule model (pure, `Codable`, unit-tested)

```swift
struct SmartRuleSet: Codable, Equatable {
    enum Match: String, Codable { case all, any }
    var match: Match
    var rules: [SmartRule]
}

enum SmartRule: Codable, Equatable {
    case rating(op: Comparison, stars: Int)          // Comparison: .atLeast/.equal/.atMost
    case color(ColorTerm)                            // .name(String) | .hex(String)
    case tag(op: HasOp, label: String)               // .has / .hasNot
    case kind(KindGroup)                             // maps to one or more AssetKind
    case date(field: DateField, op: DateOp)          // .created/.modified ; .withinDays(Int)/.before(Date)/.after(Date)
    case filename(contains: String)
    case size(op: Comparison, bytes: Int64)
}
```

Pure helpers: JSON round-trip, `isValid` (e.g. stars 1…5, non-empty label/filename, positive size), and a human summary string (for the sidebar tooltip / modal). All unit-tested; no I/O.

---

## 3. Resolution — live query (`SmartCollectionResolver`)

The heart of the feature. Given a `SmartRuleSet`, return the matching, **reachable** file IDs (and, for the grid, `FileNode`s), computed fresh each call.

```swift
enum SmartCollectionResolver {
    static func memberIDs(_ set: SmartRuleSet, db: Database) throws -> [String]
    static func count(_ set: SmartRuleSet, db: Database) throws -> Int
}
```

**Grain:** collections hold **`file_id`s** (content-hash rows), location-agnostic — but tags/ratings are per `(file_id, parent_dir)`. So a `file_id` **satisfies a tag/rating rule if ANY of its locations does** (`EXISTS` a `(file_id, parent_dir)` row satisfying it). This matches how collections already work (a member is a content row, not a location) and is the only sane grain for a location-agnostic membership set. Content/path-level rules:

| Rule | Predicate |
|---|---|
| rating | `EXISTS` a tag row for the file whose `StarRating` value satisfies the comparison |
| tag | `EXISTS` (has) / `NOT EXISTS` (hasNot) a tag row with that label, any location |
| color | `files.palette` decoded → `PaletteMatch` (in-memory pass, as in color-search §2.4) |
| kind | `files.kind IN (…)` |
| date | `files.created_at`/`modified_at` compared |
| filename | `EXISTS` an alive `paths` row whose basename contains the term |
| size | `files.size_bytes` compared |

- **Match.all → AND**, **Match.any → OR** across rule predicates. Rules that map cleanly to SQL are composed in one `WHERE`; the color rule (which needs the palette decode) is applied as an in-memory filter over the candidate rows, same as the color-search path.
- Output is filtered to **reachable, alive** files (join `paths … is_alive = 1`, then the existing reachability rule) so a smart collection never lists a tile behind an unplugged/absent root — consistent with the reachability durable constraint.

### 3.1 Counts (the one perf watch-point)

The sidebar shows a count per collection. Resolving *every* smart collection live on every sidebar render — each potentially doing a palette scan — could add up. Mitigation:

- **Cache the resolved count per smart collection**, recomputed lazily and **invalidated** on the signals that can change membership: `tagsVersion` bumps (tag/rating edits), index changes (new/removed files), and rule edits. Model this on the existing `FolderStatCache` / `reachableFileCount` caching (debounced, off the render path).
- **Opening** a smart collection always re-resolves live (fresh grid), so the cache is a count-only optimization; contents are never stale.
- This cache is the extent of the "meaty part." It is far smaller than the trigger-driven membership rebuild that materialized storage (the rejected alternative) would have required.

---

## 4. UI

### 4.1 Rule builder — `SmartCollectionRulesView` (sheet)

A mail-rules-style modal, presented via the existing `.windowFittedSheetHeight` (its content is a scrolling rule list — see the durable fixed-height-sheet constraint):

- Header: **Name** field + **Match [All ▾ / Any]** toggle ("Match **all** of the following rules").
- A list of **rule rows**, each: `[type ▾] [operator ▾] [value control]` + a **−** to remove. Value control adapts to type (star stepper, color text field accepting a name or `#hex`, tag field, kind menu, date controls, filename text field, size stepper + MB).
- **+ Add Rule** appends a row.
- Footer: **Cancel** / **Save** (Save disabled until name non-empty and every rule `isValid`).

Draft state is **local `@State`** (per the durable "never bind a per-keystroke control to `AppState`" rule); it commits to `AppState`/`CollectionStore` only on Save.

### 4.2 Entry points

- **Collections page `+`** → menu: "New Collection" / **"New Smart Collection…"** → opens the builder empty.
- **Right-click a collection row:**
  - manual/auto collection → **"Make Smart…"** → builder; on Save the collection's `smart_rules` is set and its `collection_members` are dropped (see §5).
  - smart collection → **"Edit Rules…"** → builder pre-filled from `smart_rules`.

### 4.3 Distinguishing smart collections

Smart collections default to a **distinct icon** (a rules/funnel-badged variant, subject to the icon set) so they read differently from hand-made collections in the sidebar, while still honoring the `v10` appearance system (the user can override icon/color). No separate sidebar section — they live in the normal COLLECTIONS list.

### 4.4 Localization

Every new string — menu items, modal labels, rule-type/operator names, the match toggle, the confirm dialog — is localized (French). Rule-type and operator display names built from enums use `String(localized:)`; any value echoed into a summary uses `NSLocalizedString` per the localization conventions.

---

## 5. Interaction with existing systems

- **Reclustering:** `CollectionsEngine` must **skip** `smart_rules IS NOT NULL` collections (they have no `auto` members to rebuild). Confirm the recluster query filters them out.
- **Make Smart on a manual collection:** converting **replaces** hand-picked membership with rules. Show a confirm: *"Replace the N items you added with rule-based membership? This can't be undone."* On confirm, set `smart_rules` and `DELETE FROM collection_members WHERE collection_id = ?`. (Chosen over disallowing conversion because the user specifically wanted right-click-on-a-collection; the confirm prevents silent data loss.)
- **Delete:** reuse the existing collection delete path the sidebar already uses. `setHidden` exists to stop the AI reclusterer regenerating a deleted cluster; a smart collection is never regenerated, so a hard delete is also safe — but keep **one** deletion path for consistency (whatever manual collections use today).
- **Backup/restore:** the collection backup record gains `smart_rules`; restore re-creates it. Members are *not* backed up for a smart collection (there are none) — it re-resolves on the restoring machine, which is the correct behavior (membership follows that library's files).
- **Selection/reachability:** opening a smart collection routes through the same `setActiveCollection` path as any collection, so the existing selection-clear + reachability-filter + `activeCollectionFiles` bookkeeping (durable constraints) apply unchanged.

---

## 6. Testing

- **`SmartRuleSetTests`** (pure) — JSON round-trip for every rule type; `isValid` boundaries (stars 0/1/5/6, empty label, zero/negative size); `Match.all`/`.any` composition; human-summary strings.
- **`SmartCollectionResolverTests`** (fixture DB) — each rule type resolves the right `file_id`s; AND vs OR composition; the "any location satisfies" grain for tag/rating rules; reachability filtering excludes unreachable files; `count` matches `memberIDs.count`; color rule reuses the color-search matcher and its fixtures.
- **Migration test** — `v12_smart_collections` adds the column, leaves existing collections `smart_rules = NULL`, round-trips a value.
- No UI test (modal is view code); all resolution + rule logic is covered by the pure/fixture units.

---

## 7. Open items & sequencing

- **Color rule soft-depends on the color-search spec.** Ship rating/tag/kind/date/filename/size first; the **color** rule slots in for free once `PaletteMatch` exists. Recommended order: **color search first**, then smart collections with color included from the start.
- **Count-cache mechanism** (§3.1) — exact invalidation wiring is settled in the implementation plan; the design is "cache + invalidate on tagsVersion/index/rule-edit," modeled on `FolderStatCache`.
- **Folder-scoping** and the **v2 rule types** (intent / dimensions / has-note) are explicitly deferred.
