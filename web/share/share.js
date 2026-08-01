// share.js — pure manifest logic (browser + node). The page imports the render
// glue; tests import only these pure functions.
import { inflateSync, strFromU8 } from './fflate.module.js';

// Upper-bounded: real Drive ids are ~33 chars. Without a max, a crafted fragment
// (within the inflate cap) could carry multi-MB "ids" that build multi-MB img.src
// URLs. 200 is far above any real id.
export const VALID_ID = /^[A-Za-z0-9_-]{20,200}$/;

// Caps on attacker-supplied display strings (signature fields / filenames), so a
// single field can't be a multi-MB text node even within the inflate budget.
const MAX_FIELD = 4096;
const MAX_NAME = 1024;

// Neutralize bidi-override / zero-width / control characters in attacker-supplied
// display text (filenames + signature), so a crafted name can't visually reorder
// itself (e.g. an RTL override hiding a ".scr" extension as ".txt"). textContent
// already blocks markup; this blocks visual spoofing. Pairs with `unicode-bidi:
// isolate` on the captions in CSS.
export function sanitizeText(s) {
  // C0/C1 controls + DEL, zero-width + bidi marks (200B-200F), bidi
  // embeddings/overrides (202A-202E), word-joiner range (2060-2064), bidi
  // isolates/deprecated (2066-206F), and BOM (FEFF).
  return String(s).replace(/[\u0000-\u001F\u007F-\u009F\u061C\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u206F\uFEFF]/g, '');
}

// base64url → bytes (browser atob / node Buffer).
function b64urlToBytes(fragment) {
  let s = fragment.replace(/-/g, '+').replace(/_/g, '/');
  while (s.length % 4) s += '=';
  if (typeof atob === 'function') {
    const bin = atob(s);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return bytes;
  }
  return new Uint8Array(Buffer.from(s, 'base64'));
}

// Bounds the decompressed size. The fragment is unsigned + attacker-suppliable,
// so a crafted "zip bomb" (tiny compressed payload that inflates to gigabytes)
// would otherwise let inflate allocate unbounded memory and hang the recipient's
// browser. fflate fills at most this buffer (it truncates past it rather than
// growing), so a bomb yields garbage → JSON.parse throws → null. A real manifest
// (≤1000 images + filenames) is well under this.
const MAX_INFLATED = 4 * 1024 * 1024;

// The manifest fragment is either raw UTF-8 JSON (legacy links, first byte '{' =
// 0x7B) or [0x01 marker][raw-DEFLATE of the JSON] (compressed links the app emits
// when that's smaller). The app picks whichever is shorter; we detect via the
// marker so both keep working. DEFLATE is raw RFC-1951 — matches Swift's
// COMPRESSION_ZLIB (verified cross-language).
export function decodeManifest(fragment) {
  if (!fragment) return null;
  try {
    const bytes = b64urlToBytes(fragment);
    const json = bytes[0] === 0x01
      ? strFromU8(inflateSync(bytes.subarray(1), { out: new Uint8Array(MAX_INFLATED) }))
      : strFromU8(bytes);
    return JSON.parse(json);
  } catch { return null; }
}

export const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/;

// Portfolio manifests (Spec 07 §2) live in the user's own Drive so a share can
// be updated in place without its URL changing. This browser API key is
// quota-only and API-restricted to the Drive API; it grants access to nothing
// that isn't already public (the files it reads are anyone-readable by design).
// It is NOT a secret — the binding invariant is that no secret and no OAuth
// credential ever ships on this page.
const DRIVE_API_KEY = 'REPLACE_AT_DEPLOY';
// Bounded read, same guard class as MAX_INFLATED: the fetched body is remote
// and attacker-influenceable in the same way the fragment is.
const MAX_MANIFEST_BYTES = 512 * 1024;
const MANIFEST_FETCH_TIMEOUT_MS = 6000;

export function validateManifest(m, opts = {}) {
  if (!m || typeof m !== 'object') return false;
  if (!Array.isArray(m.g) || m.g.length === 0) return false;
  // Cap the grid: the manifest rides an unsigned URL fragment, so anyone handing
  // a victim a link controls m.g. Without a bound, a crafted fragment with tens
  // of thousands of valid-looking IDs would make the page build that many <img>
  // elements and fire that many Drive requests, hanging the recipient's browser.
  // A real Muse share is far smaller than this.
  if (m.g.length > 1000) return false;
  if (!m.g.every(id => VALID_ID.test(id))) return false;
  if (m.p != null && !VALID_ID.test(m.p)) return false;
  // Filenames are optional; when present they must be a string array exactly as
  // long as the image list, so each name pairs with the right image (the whole
  // point — a mismatched array is treated as a malformed/tampered manifest).
  if (m.f != null) {
    if (!Array.isArray(m.f) || m.f.length !== m.g.length) return false;
    if (!m.f.every(s => typeof s === 'string' && s.length <= MAX_NAME)) return false;
  }
  // Spec 07 optional keys. Unknown layout VALUES are allowed (forward-compat:
  // an older page render of a newer link falls back to grid via layoutOf) — but
  // the key, when present, must be a short string. `s` is display text, so it
  // takes the field cap.
  if (m.y != null && (typeof m.y !== 'string' || m.y.length > 16)) return false;
  if (m.s != null && (typeof m.s !== 'string' || m.s.length > MAX_FIELD)) return false;
  if (m.m != null && !VALID_ID.test(m.m)) return false;
  // Require a strict date-only `e` (YYYY-MM-DD). isExpired/formatDate append a
  // local time component; a value that already carried a time would yield an
  // Invalid Date and make isExpired fail OPEN (never expire). Reject it here.
  // A PORTFOLIO manifest (`m` present) is non-expiring by design and carries no
  // meaningful `e`; opts.portfolio covers manifests fetched from Drive, which
  // never ride a fragment and so have no `m` of their own. The strict branch is
  // never loosened for anything else — that's the fail-open guard.
  const portfolio = opts.portfolio === true || m.m != null;
  if (!portfolio) {
    if (typeof m.e !== 'string' || !DATE_ONLY.test(m.e) || isNaN(Date.parse(m.e))) return false;
  } else if (m.e != null && m.e !== '') {
    if (typeof m.e !== 'string' || m.e.length > 32) return false;   // tolerated, ignored
  }
  for (const k of ['i', 'l', 'n', 'd']) if (typeof m[k] !== 'string' || m[k].length > MAX_FIELD) return false;
  return true;
}

/// Resolve the page layout from a manifest. Wire values must match
/// DriveShareManifest.swift's DriveShareLayout.rawValue exactly.
export function layoutOf(m) {
  return (m && (m.y === 'sheet' || m.y === 'essay')) ? m.y : 'grid';
}

/// A portfolio's live manifest lives in the owner's Drive; the fragment carries
/// its file id (`m`) plus a full inline snapshot. This is the ONLY fetch this
/// page ever makes.
export function manifestFetchURL(id) {
  // VALID_ID-gated by the caller; the charset makes interpolation URL-safe
  // (the thumbURL rule class).
  return `https://www.googleapis.com/drive/v3/files/${id}?alt=media&key=${DRIVE_API_KEY}`;
}

/// Pure: parse + bound + validate a fetched manifest body. null → the caller
/// falls back to the inline snapshot. Exported for tests.
export function acceptFetchedManifest(text) {
  if (typeof text !== 'string' || text.length > MAX_MANIFEST_BYTES) return null;
  try {
    const obj = JSON.parse(text);
    if (obj && typeof obj === 'object') delete obj.m;   // exactly one fetch — never chain
    return validateManifest(obj, { portfolio: true }) ? obj : null;
  } catch { return null; }
}

// Inclusive of the whole displayed day, parsed at LOCAL end-of-day so the
// share doesn't flip to "expired" a day early in western time zones (matches
// formatDate's local-midnight parse).
export function isExpired(m, now) { return new Date(m.e + 'T23:59:59') < now; }

// Written-out month avoids locale day/month ambiguity (e.g. "Jan 24, 2026").
// Forced to en-US so it's identical for every viewer. Parse at local midnight
// so the day never shifts across time zones.
export function formatDate(iso) {
  const d = new Date(iso + 'T00:00:00');
  if (isNaN(d)) return iso;
  return new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' }).format(d);
}
// Larger size for crisp printing (the page is printed to make the PDF).
export function thumbURL(id) { return `https://drive.google.com/thumbnail?id=${id}&sz=w2048`; }

// Column-density bounds per layout. Contact sheets want to go denser; the essay
// column has no density control at all (the sizer is hidden in CSS and skipped
// here). Re-applied on EVERY render, since a portfolio re-fetch can change the
// layout in place.
let sizerBounds = { min: 1, max: 6, default: 4 };
export const SIZER_BY_LAYOUT = {
  grid:  { min: 1, max: 6, default: 4 },   // the pre-Spec-07 behavior, made explicit
  sheet: { min: 3, max: 10, default: 6 },
  essay: { min: 0, max: 0, default: 0 },   // sizer hidden; values unused
};

// Browser-only render glue (skipped under node).
if (typeof document !== 'undefined') {
  const inline = decodeManifest(location.hash.slice(1));
  const root = document.getElementById('app');
  const set = (id, text) => { const el = document.getElementById(id); if (el) el.textContent = sanitizeText(text); };

  // One tile-builder DOM path serves all three layouts — the layout itself is
  // pure CSS off `data-layout`. Clearing and rebuilding is what makes the
  // portfolio re-fetch a plain second call rather than a second code path.
  const buildGrid = (m) => {
    const grid = document.getElementById('grid');
    if (!grid) return;
    grid.replaceChildren();
    // Filenames ride the manifest (key `f`) only when the app included them, and
    // only used when they pair 1:1 with the images. Each tile is a real <button>
    // so it's keyboard-operable (Enter/Space → click, which the delegated grid
    // listener handles) and announced as a control; its accessible name is the
    // filename. The optional caption (sanitized) sits under the image.
    const names = (Array.isArray(m.f) && m.f.length === m.g.length) ? m.f : null;
    m.g.forEach((id, idx) => {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'tile';
      const img = document.createElement('img');
      img.loading = 'lazy'; img.alt = '';
      img.draggable = false;   // casual-download deterrent (see installImageDownloadDeterrents)
      // Each tile shows a shimmering skeleton (CSS `.tile::before`) until its
      // Drive thumbnail paints; `.loaded` drops the skeleton and fades the image
      // in. Handlers are attached BEFORE `src` so a cached image that completes
      // synchronously still clears the skeleton, and `img.complete` covers the
      // same race for good measure. `error` reveals too, so a thumbnail that
      // fails (404/expired Drive file) doesn't leave a perpetual shimmer.
      const reveal = () => btn.classList.add('loaded');
      img.addEventListener('load', reveal);
      img.addEventListener('error', reveal);
      img.src = thumbURL(id);
      if (img.complete && img.naturalWidth) reveal();
      btn.appendChild(img);
      const name = names ? sanitizeText(names[idx]) : '';
      if (name) {
        const cap = document.createElement('span');
        cap.className = 'tile-name';
        cap.textContent = name;   // textContent — never innerHTML
        btn.appendChild(cap);
      }
      btn.setAttribute('aria-label', name || `Image ${idx + 1}`);
      grid.appendChild(btn);
    });
  };

  const renderLive = (m) => {
    root.dataset.state = 'live';
    root.dataset.layout = layoutOf(m);
    set('intro', m.i); set('label', m.l); set('name', m.n);
    set('body', m.s ?? '');
    // A portfolio never expires, so it says so rather than showing a date.
    set('expires', m.m != null ? '' : `Expires ${formatDate(m.e)}`);
    buildGrid(m);
    setupGridSizer();
  };

  if (!inline || !validateManifest(inline)) {
    root.dataset.state = 'unavailable';
  } else if (inline.m == null && isExpired(inline, new Date())) {
    root.dataset.state = 'expired';
    set('intro', inline.i); set('label', inline.l); set('name', inline.n);
  } else {
    // "Save PDF" = print the page. The recipient's print dialog chooses the
    // paper size and Save-as-PDF; the print stylesheet lays out just the images.
    const save = document.getElementById('save');
    if (save) save.addEventListener('click', () => window.print());
    // Render the INLINE snapshot immediately — no blank waiting state, ever.
    renderLive(inline);
    setupBackdropSwitcher();
    setupLightbox();
    installImageDownloadDeterrents();
    // Only a portfolio consults Drive, and only to replace what's already on
    // screen. Any failure (offline, quota, API change) keeps the snapshot.
    if (inline.m != null && VALID_ID.test(inline.m)) {
      resolveManifest(inline).then((resolved) => {
        if (resolved !== inline) renderLive(resolved);
      });
    }
  }
}

/// Fetch a portfolio's live manifest.json, bounded and time-limited. Returns
/// the inline snapshot unchanged on ANY failure — the page must never end up
/// blank because Drive was slow.
async function resolveManifest(inline) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), MANIFEST_FETCH_TIMEOUT_MS);
  try {
    const resp = await fetch(manifestFetchURL(inline.m), { signal: controller.signal });
    if (!resp.ok) return inline;
    const fetched = acceptFetchedManifest(await resp.text());
    // Keep the pointer so the page still knows it's a portfolio (the fetched
    // copy has had its own `m` stripped — exactly one fetch, no chaining).
    return fetched ? { ...fetched, m: inline.m } : inline;
  } catch {
    return inline;   // offline / API change / quota — degrade to last-published state
  } finally {
    clearTimeout(timeout);
  }
}

// Image-download deterrents. Raises the bar against the most casual grab — the
// right-click "Save Image As…" menu and drag-to-desktop — for people who wouldn't
// know any other way. Delegated at the document so ONE pair of listeners covers
// the grid thumbnails AND the lightbox image (cost independent of image count),
// including any image added later. Paired with `-webkit-user-drag/user-select:
// none` in CSS and `img.draggable = false`.
//
// This is DELIBERATELY SHALLOW and cannot be otherwise: the Drive thumbnail URL
// is reachable directly (it's in the Network tab, and the file ids ride the share
// link's #fragment), and the original file is anyone-readable on Drive by design
// (see the Drive-share security notes — that's exactly why uploads are EXIF/GPS
// stripped). So nothing here stops a determined recipient; it only deters the
// least technical viewer, which is the whole intent.
function installImageDownloadDeterrents() {
  document.addEventListener('contextmenu', (e) => {
    if (e.target instanceof HTMLImageElement) e.preventDefault();
  });
  document.addEventListener('dragstart', (e) => {
    if (e.target instanceof HTMLImageElement) e.preventDefault();
  });
}

// Click-to-enlarge: a viewport-blur overlay showing the clicked image, reusing
// the already-loaded thumbnail (no new request). One reused overlay + a single
// delegated listener, so cost is independent of image count. Close via the ×,
// Esc, or a click on the backdrop. While open it behaves as a proper modal: the
// page behind is made `inert` (non-focusable / hidden from AT), page scroll is
// locked, focus moves into the dialog and is trapped, and returns on close.
function setupLightbox() {
  const box = document.getElementById('lightbox');
  const grid = document.getElementById('grid');
  if (!box || !grid) return;
  const bimg = document.getElementById('lightbox-img');
  const bname = document.getElementById('lightbox-name');
  const closeBtn = document.getElementById('lightbox-close');
  // The page content behind the dialog (everything but the lightbox itself).
  const background = [document.getElementById('app'), document.querySelector('.legal')].filter(Boolean);
  let lastFocus = null;
  const open = (src, name) => {
    bimg.src = src;
    if (bname) bname.textContent = name || '';   // filename under the enlarged image
    // Announce the filename as the dialog's accessible name so a screen reader
    // conveys which image is open on focus.
    box.setAttribute('aria-label', name ? `Image preview: ${name}` : 'Image preview');
    box.hidden = false;
    background.forEach((el) => { el.inert = true; });   // inert background (focus + AT)
    document.documentElement.style.overflow = 'hidden'; // scroll lock
    lastFocus = document.activeElement;
    closeBtn.focus();
  };
  const close = () => {
    if (box.hidden) return;
    box.hidden = true;
    bimg.removeAttribute('src');
    if (bname) bname.textContent = '';
    background.forEach((el) => { el.inert = false; });
    document.documentElement.style.overflow = '';
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  };
  // A tile is a <button>, so keyboard activation (Enter/Space) fires a click that
  // bubbles here too — one handler covers mouse + keyboard.
  grid.addEventListener('click', (e) => {
    const tile = e.target.closest('.tile');
    if (!tile) return;
    const img = tile.querySelector('img');
    if (!img || !img.src) return;
    const cap = tile.querySelector('.tile-name');
    open(img.src, cap ? cap.textContent : '');
  });
  closeBtn.addEventListener('click', close);
  box.addEventListener('click', (e) => { if (e.target === box) close(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') close(); });
  // Focus trap: the dialog has a single focusable control, so keep Tab on it
  // (works even where `inert` is unsupported).
  box.addEventListener('keydown', (e) => {
    if (e.key === 'Tab') { e.preventDefault(); closeBtn.focus(); }
  });
}

// Backdrop switcher (screen-only): apply a shade, mark the active dot, and
// remember the viewer's choice across visits.
function setupBackdropSwitcher() {
  const dots = document.querySelectorAll('.bg-switcher .dot');
  const apply = (name) => {
    document.documentElement.setAttribute('data-bg', name);
    dots.forEach(d => d.setAttribute('aria-pressed', String(d.dataset.bg === name)));
    try { localStorage.setItem('museBg', name); } catch { /* private mode */ }
  };
  let saved = null;
  try { saved = localStorage.getItem('museBg'); } catch { /* private mode */ }
  apply(['light', 'grey', 'dark'].includes(saved) ? saved : 'light');
  dots.forEach(d => d.addEventListener('click', () => {
    const bg = d.dataset.bg;
    if (['light', 'grey', 'dark'].includes(bg)) apply(bg);
  }));
}

// Grid sizer (screen-only): a custom shadcn-style slider that sets the grid's
// column density (1–6, default 4) by writing a target --tile-min on the grid (the
// grid itself stays responsive via auto-fill), and remembers the choice across
// visits. Custom (not <input range>) so click-to-jump works in Safari; supports
// drag + arrow keys, and exposes ARIA slider state.
// Re-entrant: a portfolio re-fetch can change the layout in place, so this runs
// again with different bounds. Listeners are installed once (guarded by
// `dataset.wired`); the bounds/initial paint are re-derived every call.
function setupGridSizer() {
  const slider = document.getElementById('cols');
  const grid = document.getElementById('grid');
  if (!slider || !grid) return;
  const app = document.getElementById('app');
  const bounds = SIZER_BY_LAYOUT[app ? app.dataset.layout : 'grid'] || SIZER_BY_LAYOUT.grid;
  if (bounds.max <= bounds.min) return;   // essay: no density control at all
  // Module-scoped so the once-wired drag/key listeners always read the CURRENT
  // layout's bounds rather than the ones captured on the first call.
  sizerBounds = bounds;
  const MIN = () => sizerBounds.min, MAX = () => sizerBounds.max;
  slider.setAttribute('aria-valuemin', String(bounds.min));
  slider.setAttribute('aria-valuemax', String(bounds.max));
  const track = slider.querySelector('.slider-track');
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const clamp = (n) => Math.min(MAX(), Math.max(MIN(), Math.round(n)));
  const pctFromX = (x) => {
    const r = track.getBoundingClientRect();
    return Math.min(1, Math.max(0, (x - r.left) / r.width));
  };
  const pctForCols = (c) => (c - MIN()) / (MAX() - MIN());

  // The grid is responsive (auto-fill on a target tile size). Translate the
  // chosen column density into the tile size that yields exactly c columns at
  // the CURRENT grid width; auto-fill then reflows the count as the window
  // resizes. GAP must match the CSS column-gap. (-1px biases against rounding up
  // to c+1 columns at the selection width.)
  const GAP = 20;
  const tileMinFor = (c) => {
    const w = grid.clientWidth || 800;
    return Math.max(40, (w - (c - 1) * GAP) / c - 1);
  };
  const setTile = (c) => grid.style.setProperty('--tile-min', `${tileMinFor(c)}px`);

  let saved = null;
  try { saved = localStorage.getItem('museCols'); } catch { /* private mode */ }
  let curCols = clamp(parseInt(saved, 10) || bounds.default);

  // Recolumn with a FLIP morph: capture each near-viewport tile's frame, apply
  // the new column count, then animate the tiles from their old frame to the new
  // one (grow/shrink + slide) via a transform transition. Bounded to the visible
  // tiles, so the cost stays flat regardless of how many images the share holds;
  // off-screen tiles just reflow. reduceMotion → instant.
  const recolumn = (c) => {
    const tiles = grid.children;
    const vh = window.innerHeight;
    const animated = [], first = [];
    if (!reduceMotion) {
      for (const t of tiles) {
        const r = t.getBoundingClientRect();
        if (r.bottom > -0.5 * vh && r.top < 1.5 * vh) { animated.push(t); first.push(r); }
      }
    }
    setTile(c);
    animated.forEach((t, i) => {
      const f = first[i], l = t.getBoundingClientRect();
      const s = l.width ? f.width / l.width : 1;
      t.style.transition = 'none';
      t.style.transformOrigin = 'top left';
      t.style.transform = `translate(${f.left - l.left}px, ${f.top - l.top}px) scale(${s})`;
    });
    void grid.offsetWidth; // flush the inverted transforms before playing
    animated.forEach((t) => {
      t.style.transition = 'transform 0.22s ease';
      t.style.transform = '';
    });
  };

  const setThumb = (p) => slider.style.setProperty('--range-pct', `${p * 100}%`);
  const setCols = (c) => {
    if (c === curCols) return;
    curCols = c;
    slider.setAttribute('aria-valuenow', String(c));
    try { localStorage.setItem('museCols', String(c)); } catch { /* private mode */ }
    recolumn(c);
  };

  // Initial paint (no animation).
  setTile(curCols);
  slider.setAttribute('aria-valuenow', String(curCols));
  setThumb(pctForCols(curCols));

  // Listeners only once — a re-render must not stack a second copy of each.
  if (slider.dataset.wired === '1') return;
  slider.dataset.wired = '1';

  let dragging = false;
  const dragTo = (x) => {
    const p = pctFromX(x);
    setThumb(p);                          // thumb follows the pointer 1:1 (no hard stops)
    setCols(clamp(MIN() + p * (MAX() - MIN()))); // grid recolumns live, FLIP-animated
  };
  slider.addEventListener('pointerdown', (e) => {
    dragging = true;
    slider.classList.add('dragging');
    // Suppress the browser's drag-to-select while the slider is dragged — a
    // pointer drag that begins on the slider would otherwise rubber-band a
    // text/image selection across the grid behind it. Scoped to the drag only
    // (removed in endDrag), so normal selection is untouched. See .sizer-dragging.
    document.documentElement.classList.add('sizer-dragging');
    slider.setPointerCapture(e.pointerId);
    slider.focus();
    dragTo(e.clientX);
  });
  slider.addEventListener('pointermove', (e) => { if (dragging) dragTo(e.clientX); });
  const endDrag = () => {
    if (!dragging) return;
    dragging = false;
    slider.classList.remove('dragging');
    document.documentElement.classList.remove('sizer-dragging');
    setThumb(pctForCols(curCols));        // snap the thumb to the closest logical spot (glides)
  };
  slider.addEventListener('pointerup', endDrag);
  slider.addEventListener('pointercancel', endDrag);
  slider.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') { setCols(clamp(curCols - 1)); setThumb(pctForCols(curCols)); e.preventDefault(); }
    else if (e.key === 'ArrowRight' || e.key === 'ArrowUp') { setCols(clamp(curCols + 1)); setThumb(pctForCols(curCols)); e.preventDefault(); }
  });
}
