# Muse 1.5

## ✨ New

**Three ways to lay out the grid**

- **Columns · Rows · Grid** — pick the packing that suits the folder: classic masonry columns, justified rows (every row the same height, like a contact sheet), or a uniform square grid. One images-per-row slider drives all three.
- **Photos draw on the page, not on a card** — image tiles no longer sit on a background plate, so the selection ring, hover and star badge hug the picture itself. The collection PDF export follows the same layout you see on screen.
- **Spacing and corner radius** moved into Settings → Grid, and the corner radius carries through into the viewer.

**A calmer, more consistent interface**

- **Every dialog is now an in-window card** — no more system alerts drifting over the window. Confirmations, errors and name prompts all appear as the same centred card, sized to the window.
- **Emoji collection symbols** — a collection's icon can be any emoji, alongside the SF Symbol set.
- **Autocomplete when adding a tag or a collection**, so you stop making near-duplicates. Typing the name of a collection that already exists adds to it instead of creating a twin.
- **Icons on every menu command**, keyboard shortcuts on the frequent ones, and Settings reachable from the toolbar.
- **Sort direction** is its own menu; the sidebar picked up tighter geometry and a wash of the app's current mood colour.
- **File facts in the viewer's INFO card** — size, format, dimensions and megapixels.

## ⚡️ Faster

- **Analysis is dramatically faster on large images.** A 115-megapixel scan used to take 111 seconds to analyze; it now takes under a second. Files are analyzed three at a time, decoded once per pass, and similarity clustering is up to 96× faster on big libraries.
- **Colours are read correctly** — colour extraction is pinned to sRGB, so RAW files no longer produce wrong colour tags and colour-search matches.
- **The hero viewer opens and closes cleanly.** Large images no longer stall the app mid-flight, reopen themselves on Escape, or fly to the wrong place. Big files now decode progressively so they land sharp.
- **The progress pill means background work only** — it no longer appears and refills every time you scroll.

## 🛠 Fixes & improvements

- A whole-codebase audit round (18 areas). The fixes worth naming:
  - **Audio files never reach QuickLook**, closing the same privacy gap already closed for video — a planted audio file could otherwise phone home on mere folder open.
  - **Star ratings stay mutually exclusive across devices** — an iCloud merge could previously leave a photo with two ratings.
  - **Stale thumbnails** could survive an edit in two places, including the Duplicates modal — the picture you delete on is now always current.
  - **Duplicates** re-asserts the never-delete-a-whole-group rule at the moment of deletion.
  - A file Muse can't decode no longer re-queues itself for analysis on every visit to its folder.
- Modals sit centred instead of 16pt off-centre, and the Symbol & Color picker's two tabs are exactly the same size.
- Similar-tag suggestions no longer key off an arbitrary file.
- **The update dialog now tells you what changed** — these notes are what you're reading in it.
- French localization for all of the above.

---

**Privacy:** Muse collects no data. The only network activity is Sparkle auto-updates and the opt-in, user-initiated Google Drive publish (images go to *your* Drive via the least-privilege `drive.file` scope; the developer receives nothing).

**License:** Muse is source-available under the PolyForm Shield License — free to read, run, and modify, just not to build a competing product.
