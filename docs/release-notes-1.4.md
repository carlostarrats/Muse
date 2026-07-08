# Muse 1.4

## ✨ New

**Smart collections**

- **Rule-driven collections** — define a collection by rules (rating, color, tag, kind, date, filename, or size), combined with **Match All** or **Match Any**, and it fills and updates itself live from your library — always current, never stale. Make an existing collection smart, edit its rules, or create one fresh from the Collections **+**.

**Finding things**

- **Color search** — type a hex value in the search field (e.g. `#3a7bd5`), or paste a whole palette copied from the viewer's Colors card, to find images that perceptually match.
- **Import keywords & ratings** (File menu) — read IPTC/XMP keywords and star ratings written by Lightroom, Bridge, or Capture One into your existing files (embedded or `.xmp` sidecar), as Muse tags and ratings. Your existing Muse edits always win.
- **XMP Sidecars filter** — a new kind-filter row to hide `.xmp` sidecar cards in RAW-workflow folders.

**In the viewer**

- **Per-file notes** — jot a free-text note on any image, filterable and searchable, with a copy button.
- **Collapsible Colors card** — collapse the palette card; the choice sticks across files.

**Personalize**

- **Collection icon & color** — right-click a collection → Change Symbol & Color… to give it its own SF Symbol and color.

## 🛠 Fixes & improvements

- Smart-collection **manual refresh button**, revealed only when there's an update to re-resolve (and it honors Reduce Motion).
- Pre-release health and security audit across the features added since 1.3.
- French localization for all of the above.

---

**Privacy:** Muse still collects no data. The only network activity is Sparkle auto-updates and the opt-in, user-initiated Google Drive publish (images go to *your* Drive via the least-privilege `drive.file` scope; the developer receives nothing).

**License:** Muse is now source-available under the PolyForm Shield License (was MIT) — free to read, run, and modify, just not to build a competing product.
