# Localization (French v1) — Design

**Date:** 2026-06-20
**Status:** Approved (brainstorm), pending implementation plan
**Branch (planned):** `feat/localization-french` (or next `feat/next-NN`)

## 1. Goal

Make Muse display in the user's macOS language instead of English-only,
**starting with French**, in a way that:

- follows the operating system's language choice automatically (no in-app
  language picker, no new UI the user interacts with),
- localizes **both** the app's own interface chrome **and** the AI-generated
  tags (which dominate the tag set, so leaving them English would feel broken
  to a French user),
- behaves correctly for **bilingual users** who switch system language or mix
  languages,
- adds **no measurable runtime cost**,
- is built as an **additive, isolated layer** that can be removed cleanly at
  three independent granularities if the trial isn't enjoyable,
- and lays infrastructure where **adding the next language is "add a column,"**
  not new engineering.

French is the only language shipped in v1. The infrastructure is
language-agnostic; later languages reuse all of it.

## 2. Background / current state (as-built)

- **No localization today.** Zero `.xcstrings`/`.strings` catalogs in the app's
  own source. `project.pbxproj` has `developmentRegion = en`,
  `knownRegions = (en, Base)`. No `NSLocalizedString`/`String(localized:)` calls.
  Every UI label is a hardcoded English string literal. (The only `.lproj`
  folders in the tree belong to the Sparkle dependency, not the app.)
- **AI tags are already canonical-English.** `VisionServices.classify` uses
  `VNClassifyImageRequest`; tag labels are the request's `identifier` values,
  drawn from a **fixed, finite, enumerable taxonomy**
  (`VNClassifyImageRequest.knownClassifications(forRevision:)`, ~1,300 terms).
  This is what makes AI-tag localization tractable: the complete output
  vocabulary is known ahead of time and can be translated once.
- **`TagRow` has a `source` column** (`"manual"` vs `"vision"`) and identity is
  `(file_id, parent_dir)` with `UNIQUE(file_id, parent_dir, label)`. Tags are
  stored by their canonical label string. **No schema change is needed** for
  this feature — storage stays canonical-English.
- **Tag display** flows through `AppState.tagChipRows` → `TagChipsRow` (chips),
  the multi-tag banner pills (`feat/next-45`), the hero viewer tag list
  (`ViewerInfoColumn`), the collection PDF export pills (`feat/next-46`), and
  VoiceOver labels. All key off the canonical label string.
- **Search** (`SearchService`) matches tags via `TagRow.label LIKE '%query%'`
  plus FTS5 over filename/caption/OCR, plus semantic embeddings.
- **AI collection names** come from `CollectionNaming.swift`:
  `FoundationModelNamer` (gated to Apple Intelligence Macs, macOS 26+) or the
  `TagFallbackNamer` (top tag, capitalized) — both currently English.
- **UI string surface:** ~230 user-facing string literals
  (`Text`/`Button`/`Label`/`.help`/`.accessibilityLabel`/`Section`) across ~56
  UI files. Bounded.
- **Formatters:** ~8 `*Formatter`/`.formatted(` call-sites today (sizes, dates).
- **Min macOS 14.6** — String Catalogs author in Xcode 15+ and compile back
  cleanly to this deployment target; `String(localized:)` requires macOS 12+.

## 3. Core principle

**Everything the app controls is localized at *display time*, computed from the
current locale — never baked into stored data.** Stored data (DB tags, FTS,
collection rows) stays canonical-English. Localization is a presentation layer
on top. This single principle is what delivers:

- **Consistency:** UI chrome and AI tags flip together with the system language,
  because both resolve the current language when drawn.
- **Dual-speaker correctness:** switching system language re-resolves display;
  nothing is stuck in a stale language; no data migration is ever needed.
- **Removability:** removing the layer can never strand or corrupt user data,
  because no translated data was ever written.

User-typed content (manual tags, hand-named collections) is the user's own words
and is **never** translated — it passes through verbatim, exactly as every macOS
app behaves (Finder folder names, Photos albums). This is correct, not a gap.

## 4. Components

### A. UI chrome → String Catalog

- Add a `Localizable.xcstrings` String Catalog to the Muse target.
- **Keep English string literals inline in code as the keys.** SwiftUI
  auto-localizes `Text`/`Label`/`.help`/`.accessibilityLabel` literals
  (`LocalizedStringKey`). Do **not** refactor to symbolic keys
  (`NSLocalizedString("add_folder")`) — inline literals are what make removal a
  one-file delete and keep the English baseline intact in source.
- Add `fr` to the project's `knownRegions`; keep `en` as development region.
- Seed the French column via machine translation, then review. Untranslated
  entries fall back to English automatically (graceful, never blank).
- Audit for **String-typed** user-facing values that are NOT auto-localized
  (e.g. a `String` built then shown, or non-`LocalizedStringKey` API overloads);
  route those through `String(localized:)` explicitly.
- **Removal:** delete the catalog + drop `fr` from `knownRegions` → English,
  code untouched.

### B. AI-tag vocabulary → `VocabularyLocalizer` (chosen approach: bundled table)

A single isolated component is the entire AI-tag localization surface.

- **Bundled resource** `VisionVocabulary.json`: `{ canonical: { "fr": term } }`,
  generated **once at build/authoring time** by enumerating
  `VNClassifyImageRequest.knownClassifications` and machine-translating, then
  reviewed. Shipped in the app bundle. (Generation is a dev-time step/script,
  not runtime — preserves the no-network policy in the shipped, sandboxed app.)
- **`VocabularyLocalizer`** (new, `Intelligence/` or `Localization/`):
  - resolves the effective app language via `Bundle.main.preferredLocalizations`
    (this honors the macOS **per-app language override**),
  - `display(_ canonical: String) -> String` — forward lookup; **identity** if
    the term is unknown or the language is English. So manual/user tags and
    any untranslated vision term pass through unchanged.
  - `canonicalize(_ token: String) -> String?` — reverse lookup over a
    **cached, lazily-built, case-insensitive** reverse map for the current
    language; `nil` if the token isn't a known localized term.
  - loads the table once, caches both maps; pure/synchronous lookups.
- **Display call-sites route the canonical label through `display(_:)`:** tag
  chips (`TagChipsRow`), multi-tag banner pills, hero viewer tag list, PDF
  export pills, and the VoiceOver labels for each. **All internals stay
  canonical** — `activeTagLabels`, chip-count dictionaries, DB queries, the
  multi-tag intersection, and the `.id`/`gridSignature` keys are unchanged.
  Localization is purely the rendered string.
- **Display is source-agnostic** (keyed on the canonical string, not
  `TagRow.source`): a manual tag that happens to equal a vision term will
  display localized. This is rare and semantically harmless, and keeping the
  seam a pure `String -> String` transform is what makes it trivially
  removable. (Counts already aggregate per label across mixed-source files, so
  a single string transform is the only consistent place to localize.)
- **Removal:** make `display`/`canonicalize` identity (or delete call-sites) →
  AI tags revert to English. No data touched.

### C. Search bridge

- In `SearchService.search`, before the tag `LIKE` match, map each query token
  through `VocabularyLocalizer.canonicalize`. Search **both** the canonicalized
  term (if it resolves) **and** the raw token — so `plage` finds files tagged
  canonical `beach`, while French filenames/OCR/captions still match on the raw
  token. FTS and semantic paths are unchanged.
- Contained to the tag-matching step; ordering/scope logic untouched.

### D. AI collection names in-language

- `FoundationModelNamer`: add the effective language to the instructions/prompt
  (e.g. "Reply in {language}.") so generated titles come out in French on AI
  Macs.
- `TagFallbackNamer`: route the chosen top-tag name through
  `VocabularyLocalizer.display` so the fallback name is localized too.
- A name, once generated, is stored as the collection's name and thereafter is
  user data — it does **not** re-translate on a later language switch. This is
  the intended "user content is stable" behavior.

### E. Locale-aware formatting

- Audit the ~8 formatter call-sites plus any hand-built size/date strings
  (notably `FileMetadata`, the hero subtitle `size · dimensions`, `FolderStat`
  display, the Info card). Ensure they use the **current locale** (the default
  for `ByteCountFormatter` / `Date.FormatStyle` / `DateFormatter`) rather than a
  pinned `Locale(identifier:)` or manual string assembly — so a French user
  sees `1,5 Mo` and French date order.

### F. Testing

- Pure-logic unit tests (repo convention: pure logic is tested, UI views are
  not):
  - `VocabularyLocalizer`: forward lookup, reverse lookup, identity fallback for
    unknown terms, English = identity, case-insensitivity, manual/user-tag
    passthrough.
  - Search-bridge token mapping: a localized query token canonicalizes; an
    unknown token is left as-is; both terms are searched.
- French UI is smoke-checked manually (and/or pseudolocalization) — UI is not
  unit-tested per convention.

## 5. Removability (explicit, three independent kill-switches)

1. **Pull one language (UI):** remove `fr` from `knownRegions` → those users
   fall back to English. Code + data untouched.
2. **Pull all UI localization:** delete the catalog, revert `knownRegions` to
   English-only.
3. **Pull AI-tag localization only:** make `VocabularyLocalizer.display` /
   `canonicalize` identity (keep UI localized). AI tags revert to English.

No user data is ever written in translated form, so any of these is safe and
non-destructive.

## 6. Performance

No measurable runtime cost. UI-chrome lookups are O(1) catalog lookups at view
render (what every macOS app does). Tag display is one dictionary lookup per
on-screen chip; the full ~1,300-entry table is a few KB in memory. Search adds
one lookup per query token. Critically, all string localization happens at the
**view-render layer** — never inside the virtualized grid's `MasonryGeometry`
precompute (the O(n) hot path the codebase guards), which operates on frames and
counts, not translated words.

## 7. Adding languages later

Infrastructure (catalog, vocabulary table + `VocabularyLocalizer`, search
bridge, formatters) is built once and is language-agnostic. Each new language is:
add it to `knownRegions`, fill its String Catalog column, add its column to
`VisionVocabulary.json`. No code or architecture changes; the search bridge and
all display sites work for any language for free. New app strings added later
need translating per active language (tooling flags untranslated entries; they
fall back to English meanwhile).

## 8. Out of scope (v1)

- Languages other than French (infrastructure supports them; not shipped yet).
- **Caption localization** — the Vision caption stays canonical English: it is
  an internal FTS search signal, not prominent UI, and localizing it would
  break FTS matching.
- OCR'd text (already in whatever language the image contains).
- Live/runtime machine translation in the shipped app (would break the
  update-only no-network policy and raise the min-OS; rejected — translation is
  build-time only).
- An in-app language picker (macOS System Settings provides language selection
  and a native per-app override; building our own would be needless surface).
- Right-to-left languages (not relevant to French; SwiftUI handles RTL
  automatically if such a language is added later).

## 9. Rejected alternatives

- **Vocabulary in a String Catalog (vs. bundled JSON):** forward display would
  be OS-automatic, but search needs the *reverse* (localized→canonical) map,
  which a catalog can't provide — you'd still enumerate every known term to
  build it, splitting the vocabulary across two mechanisms. The bundled-table
  approach gives both directions from one source and isolates the whole feature
  behind one removable component.
- **Storing both canonical + localized tags in the DB:** rejected — reintroduces
  a data migration, stale-language-on-switch, and broken dual-speaker behavior,
  and makes removal data-destructive. Display-time localization avoids all of it.
- **Symbolic string keys for UI chrome:** rejected — invasive to add and to
  undo; inline-literal auto-extraction keeps the English baseline in source and
  removal trivial.
