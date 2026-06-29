// share.js — pure manifest logic (browser + node). The page imports the render
// glue; tests import only these pure functions.
export const VALID_ID = /^[A-Za-z0-9_-]{20,}$/;

export function decodeManifest(fragment) {
  if (!fragment) return null;
  try {
    let s = fragment.replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    const json = (typeof atob === 'function')
      ? decodeURIComponent(escape(atob(s)))
      : Buffer.from(s, 'base64').toString('utf8');
    return JSON.parse(json);
  } catch { return null; }
}

export const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/;

export function validateManifest(m) {
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
  // Require a strict date-only `e` (YYYY-MM-DD). isExpired/formatDate append a
  // local time component; a value that already carried a time would yield an
  // Invalid Date and make isExpired fail OPEN (never expire). Reject it here.
  if (typeof m.e !== 'string' || !DATE_ONLY.test(m.e) || isNaN(Date.parse(m.e))) return false;
  for (const k of ['i', 'l', 'n', 'd']) if (typeof m[k] !== 'string') return false;
  return true;
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

// Browser-only render glue (skipped under node).
if (typeof document !== 'undefined') {
  const m = decodeManifest(location.hash.slice(1));
  const root = document.getElementById('app');
  const set = (id, text) => { const el = document.getElementById(id); if (el) el.textContent = text; };
  if (!m || !validateManifest(m)) {
    root.dataset.state = 'unavailable';
  } else if (isExpired(m, new Date())) {
    root.dataset.state = 'expired';
    set('intro', m.i); set('label', m.l); set('name', m.n);
  } else {
    root.dataset.state = 'live';
    set('intro', m.i); set('label', m.l); set('name', m.n);
    set('expires', `Expires ${formatDate(m.e)}`);
    // "Save PDF" = print the page. The recipient's print dialog chooses the
    // paper size and Save-as-PDF; the print stylesheet lays out just the images.
    const save = document.getElementById('save');
    if (save) save.addEventListener('click', () => window.print());
    const grid = document.getElementById('grid');
    for (const id of m.g) {
      const img = document.createElement('img');
      img.loading = 'lazy'; img.src = thumbURL(id); img.alt = '';
      grid.appendChild(img);
    }
    setupBackdropSwitcher();
    setupGridSizer();
    setupLightbox();
  }
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
  const closeBtn = document.getElementById('lightbox-close');
  // The page content behind the dialog (everything but the lightbox itself).
  const background = [document.getElementById('app'), document.querySelector('.legal')].filter(Boolean);
  let lastFocus = null;
  const open = (src) => {
    bimg.src = src;
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
    background.forEach((el) => { el.inert = false; });
    document.documentElement.style.overflow = '';
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  };
  grid.addEventListener('click', (e) => {
    const img = e.target.closest('img');
    if (img && img.src) open(img.src);
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
  dots.forEach(d => d.addEventListener('click', () => apply(d.dataset.bg)));
}

// Grid sizer (screen-only): a custom shadcn-style slider that sets the grid's
// column density (1–6, default 4) by writing a target --tile-min on the grid (the
// grid itself stays responsive via auto-fill), and remembers the choice across
// visits. Custom (not <input range>) so click-to-jump works in Safari; supports
// drag + arrow keys, and exposes ARIA slider state.
function setupGridSizer() {
  const slider = document.getElementById('cols');
  const grid = document.getElementById('grid');
  if (!slider || !grid) return;
  const MIN = 1, MAX = 6;
  const track = slider.querySelector('.slider-track');
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const clamp = (n) => Math.min(MAX, Math.max(MIN, Math.round(n)));
  const pctFromX = (x) => {
    const r = track.getBoundingClientRect();
    return Math.min(1, Math.max(0, (x - r.left) / r.width));
  };
  const pctForCols = (c) => (c - MIN) / (MAX - MIN);

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
  let curCols = clamp(parseInt(saved, 10) || 4);

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

  let dragging = false;
  const dragTo = (x) => {
    const p = pctFromX(x);
    setThumb(p);                          // thumb follows the pointer 1:1 (no hard stops)
    setCols(clamp(MIN + p * (MAX - MIN))); // grid recolumns live, FLIP-animated
  };
  slider.addEventListener('pointerdown', (e) => {
    dragging = true;
    slider.classList.add('dragging');
    slider.setPointerCapture(e.pointerId);
    slider.focus();
    dragTo(e.clientX);
  });
  slider.addEventListener('pointermove', (e) => { if (dragging) dragTo(e.clientX); });
  const endDrag = () => {
    if (!dragging) return;
    dragging = false;
    slider.classList.remove('dragging');
    setThumb(pctForCols(curCols));        // snap the thumb to the closest logical spot (glides)
  };
  slider.addEventListener('pointerup', endDrag);
  slider.addEventListener('pointercancel', endDrag);
  slider.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowLeft' || e.key === 'ArrowDown') { setCols(clamp(curCols - 1)); setThumb(pctForCols(curCols)); e.preventDefault(); }
    else if (e.key === 'ArrowRight' || e.key === 'ArrowUp') { setCols(clamp(curCols + 1)); setThumb(pctForCols(curCols)); e.preventDefault(); }
  });
}
