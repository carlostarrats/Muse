# Muse 1.3

## ✨ New

**Share a collection — two ways**

- **Google Drive link sharing** — Sign into Google and press Publish to upload a collection's images into a tidy folder in *your own* Drive, then share a link to a clean, branded web gallery. Recipients can switch the page backdrop (light / grey / dark) and save a PDF by printing the page (they choose the paper size). Includes a fill-out form (page title, your name, expiry date) and a **Manage Drive Shares…** menu to open or unpublish links. Shares auto-expire on the date you set.
- **iCloud link sharing** — "Share iCloud Link" copies a collection into your iCloud and hands off to the native share sheet for Copy Link. A **Manage iCloud Shares…** menu lists past shares and lets you delete them to reclaim space.
- **Google Drive sign-in/out lives in Settings**, with account switching.

**Filtering & browsing**

- **Always-visible active-tag filter bar** — when tags are filtering the grid, a clearable bar shows exactly which tags are active, with a ✕ on each pill and a Clear-all.

**Collection PDF export**

- **Paper-size picker** in the PDF "Save to…" flow, with native dimensions shown next to each name.

## 🛠 Fixes & improvements

- Typing in the New/Rename dialogs no longer lags on slower Macs.
- Switching folders now hard-cuts in instantly instead of fading.
- Hero viewer action buttons fit longer labels properly, with a clearer red Delete.
- Expand/collapse buttons now swap +/− (not +/×), with an instant glyph swap.
- Updated app icon throughout.
- Accessibility pass on the new sharing and export controls (VoiceOver labels for the paper-size and expiry pickers; decorative error glyphs hidden from VoiceOver).
- French localization for all of the above.
- Security hardening on both share paths (iCloud folder-name traversal/collision/race protection; Drive token, keychain, CSP, and partial-folder-cleanup review).
- About modal refreshed to cover collection sharing, with a corrected privacy line.
- Manage-shares lists prune stale rows when a share's folder is gone, and won't orphan a share if a delete fails.

---

**Privacy:** Muse still collects no data. The only network activity is Sparkle auto-updates and the opt-in, user-initiated Google Drive publish (images go to *your* Drive via the least-privilege `drive.file` scope; the developer receives nothing).
