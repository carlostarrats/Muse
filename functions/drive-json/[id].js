// Same-origin bridge for Muse's public manifest.json/layout.json files.
//
// The sender already made these files anyone-readable in Drive. This Function
// stores nothing and has no credential: it only removes browser-specific CORS /
// attachment-response differences from the recipient path. The strict id shape,
// response-size cap, timeout, and JSON content type keep it a tiny JSON bridge,
// not an open proxy.

const VALID_ID = /^[A-Za-z0-9_-]{20,200}$/;
const MAX_BYTES = 512 * 1024;
const TIMEOUT_MS = 6000;

/// Build the public Drive download URL. A bounded numeric revision is forwarded
/// from layout.json reads so Google's media cache sees a distinct upstream URL
/// after a Manage Shares PATCH; keeping it only on the same-origin Function URL
/// would not vary the actual Drive request.
export function driveDownloadURL(id, revision = null) {
  const url = new URL('https://drive.usercontent.google.com/download');
  url.searchParams.set('id', id);
  url.searchParams.set('export', 'download');
  url.searchParams.set('confirm', 't');
  if (typeof revision === 'string' && /^\d{1,20}$/.test(revision)) {
    url.searchParams.set('v', revision);
  }
  return url.toString();
}

export async function onRequestGet({ params, request }) {
  const id = typeof params.id === 'string' ? params.id : '';
  if (!VALID_ID.test(id)) {
    return new Response('Not found', { status: 404, headers: { 'X-Muse-Bridge': 'invalid-id' } });
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), TIMEOUT_MS);
  try {
    const revision = request ? new URL(request.url).searchParams.get('v') : null;
    const url = driveDownloadURL(id, revision);
    const upstream = await fetch(url, { signal: controller.signal, cache: 'no-store' });
    if (!upstream.ok) {
      return new Response('Not found', {
        status: 404,
        headers: { 'X-Muse-Bridge': `upstream-${upstream.status}` },
      });
    }

    const declared = Number(upstream.headers.get('content-length'));
    if (Number.isFinite(declared) && declared > MAX_BYTES) {
      return new Response('Response too large', { status: 413 });
    }

    const reader = upstream.body?.getReader();
    if (!reader) return new Response('Unavailable', { status: 502 });
    const chunks = [];
    let total = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.length;
      if (total > MAX_BYTES) {
        await reader.cancel();
        return new Response('Response too large', { status: 413 });
      }
      chunks.push(value);
    }

    const body = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      body.set(chunk, offset);
      offset += chunk.length;
    }
    return new Response(body, {
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
      },
    });
  } catch {
    return new Response('Unavailable', {
      status: 502,
      headers: { 'X-Muse-Bridge': 'fetch-error' },
    });
  } finally {
    clearTimeout(timeout);
  }
}
