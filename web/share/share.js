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
  }
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
