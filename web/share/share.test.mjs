// share.test.mjs  — run: node web/share/share.test.mjs
import assert from 'node:assert';
import { deflateSync, strToU8 } from './fflate.module.js';
import { decodeManifest, validateManifest, isExpired, thumbURL, VALID_ID, sanitizeText,
         layoutOf, manifestFetchURL, acceptFetchedManifest, acceptFetchedLayoutSettings,
         readCapped, SIZER_BY_LAYOUT, remoteManifestID, isPortfolioManifest,
         isTallEditorialImage, editorialRowForIndex, isValidDateOnly } from './share.js';
import { driveDownloadURL } from '../../functions/drive-json/[id].js';

// Decompression-bomb guard: the fragment is attacker-suppliable, so a tiny
// compressed payload that inflates past the cap must NOT allocate unbounded
// memory — it's truncated to garbage and rejected (null), not hung.
{
  const bomb = deflateSync(new Uint8Array(8 * 1024 * 1024)); // 8MB zeros -> tiny
  const framed = new Uint8Array(bomb.length + 1); framed[0] = 1; framed.set(bomb, 1);
  const frag = Buffer.from(framed).toString('base64').replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
  const t0 = Date.now();
  assert.strictEqual(decodeManifest(frag), null, 'decompression bomb rejected');
  assert.ok(Date.now() - t0 < 1000, 'bomb handled promptly (bounded, no hang)');
}

const sample = { i:'Intro', l:'Sent by', n:'The Project', d:'2026-04-01',
  e:'2026-04-04', g:['aaaaaaaaaaaaaaaaaaaa','bbbbbbbbbbbbbbbbbbbb'], p:'cccccccccccccccccccc' };
const b64url = Buffer.from(JSON.stringify(sample)).toString('base64')
  .replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');

// Legacy (uncompressed) links — produced by app builds before compression — must
// still decode. The first byte is JSON's '{' (0x7B), never the 0x01 marker.
assert.deepStrictEqual(decodeManifest(b64url), sample, 'legacy uncompressed round-trip decode');
assert.strictEqual(decodeManifest('!!!notbase64'), null, 'garbage → null');

// New URLs are unambiguous, short pointers. The `r:` marker prevents an old
// base64url manifest (same alphabet as Drive ids) being mistaken for an id.
const remoteID = 'r:' + 'a'.repeat(33);
assert.strictEqual(remoteManifestID(remoteID), 'a'.repeat(33), 'short pointer id extracted');
assert.strictEqual(remoteManifestID('a'.repeat(33)), null, 'unprefixed legacy fragment is not a pointer');
assert.strictEqual(remoteManifestID('r:short'), null, 'malformed pointer rejected');
assert.strictEqual(remoteManifestID(b64url), null, 'legacy manifest remains on legacy decode path');

// Compressed links: [0x01 marker][raw deflate of the JSON], base64url. Mirrors
// what the Swift app emits (verified cross-language: Swift COMPRESSION_ZLIB ↔
// fflate inflateSync).
function compress(obj) {
  const deflated = deflateSync(strToU8(JSON.stringify(obj)));
  const withMarker = new Uint8Array(deflated.length + 1);
  withMarker[0] = 1; withMarker.set(deflated, 1);
  return Buffer.from(withMarker).toString('base64').replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
}
const withNames = { ...sample, f:['Sunset_final.jpg','IMG_4821.png'] };
assert.deepStrictEqual(decodeManifest(compress(withNames)), withNames, 'compressed round-trip decode');
assert.deepStrictEqual(decodeManifest(compress(sample)), sample, 'compressed decode without filenames');

// Filenames (`f`) are optional; when present they must be a string array matching
// the image count exactly (no mis-pairing of a name to the wrong image).
assert.ok(validateManifest(withNames), 'valid with matching filenames');
assert.ok(validateManifest(sample), 'valid without filenames (f optional)');
assert.ok(!validateManifest({ ...sample, f:['only-one'] }), 'filenames length mismatch rejected');
assert.ok(!validateManifest({ ...sample, f:[1, 2] }), 'non-string filenames rejected');
assert.ok(!validateManifest({ ...sample, f:'notarray' }), 'non-array filenames rejected');

// Hardening (low-sev): bound attacker-supplied display strings + ids so a single
// field can't be a multi-MB node within the inflate budget.
assert.ok(!validateManifest({ ...sample, i: 'x'.repeat(4097) }), 'oversized intro field rejected');
assert.ok(validateManifest({ ...sample, i: 'x'.repeat(4096) }), 'intro at the field cap accepted');
assert.ok(!validateManifest({ ...sample, f: [ 'x'.repeat(1025), 'ok.jpg' ] }), 'oversized filename rejected');
assert.ok(!VALID_ID.test('a'.repeat(201)), 'over-long id rejected (upper bound)');
assert.ok(VALID_ID.test('a'.repeat(200)), 'id at the upper bound accepted');

// sanitizeText strips bidi-override / zero-width / control chars (anti-spoofing)
// while leaving normal text intact.
assert.strictEqual(sanitizeText('invoice\u202Egnp.scr'), 'invoicegnp.scr', 'RTL override stripped');
assert.strictEqual(sanitizeText('a\u200Bb\uFEFFc\u0007d'), 'abcd', 'zero-width + control chars stripped');
assert.strictEqual(sanitizeText('Sunset_final.jpg'), 'Sunset_final.jpg', 'normal filename untouched');

const noPdf = { ...sample }; delete noPdf.p;
assert.ok(validateManifest(noPdf), 'valid without pdfID (app no longer uploads a PDF)');
assert.ok(!validateManifest({ ...sample, g:['short'] }), 'bad id rejected');
assert.ok(!validateManifest({ ...sample, g:[] }), 'empty grid rejected');
// The fragment is unsigned + attacker-supplyable; an over-large grid would flood
// the recipient's browser with <img>/network requests. Cap it.
const bigGrid = Array.from({ length: 1001 }, () => 'aaaaaaaaaaaaaaaaaaaa');
assert.ok(!validateManifest({ ...sample, g: bigGrid }), 'oversized grid rejected');
const maxGrid = Array.from({ length: 1000 }, () => 'aaaaaaaaaaaaaaaaaaaa');
assert.ok(validateManifest({ ...sample, g: maxGrid }), 'grid at the cap accepted');
// `e` must be strict date-only — a value with a time component would make
// isExpired fail OPEN (Invalid Date < now === false). Reject it at validation.
assert.ok(!validateManifest({ ...sample, e:'2026-04-04T12:00:00' }), 'datetime e rejected (no fail-open)');
assert.ok(!validateManifest({ ...sample, e:'2026/04/04' }), 'non-ISO date rejected');
assert.ok(!validateManifest({ ...sample, e:'not-a-date' }), 'garbage date rejected');
assert.ok(isValidDateOnly('2028-02-29'), 'real leap day accepted');
assert.ok(!isValidDateOnly('2026-02-29'), 'impossible non-leap day rejected');
assert.ok(!isValidDateOnly('2026-02-31'), 'normalized overflow day rejected');
assert.ok(!isValidDateOnly('2026-13-01'), 'month 13 rejected');
assert.ok(!validateManifest({ ...sample, e:'2026-02-31' }), 'manifest rejects impossible date');
assert.ok(isExpired({ ...sample, e:'2020-01-01' }, new Date('2026-01-01')), 'past → expired');
assert.ok(!isExpired(sample, new Date('2026-04-02')), 'before expiry → live');
assert.ok(VALID_ID.test('aaaaaaaaaaaaaaaaaaaa'), 'id regex ok');
assert.ok(!VALID_ID.test('short'), 'short id rejected');
assert.ok(thumbURL('aaaaaaaaaaaaaaaaaaaa').startsWith('https://drive.google.com/thumbnail?id='), 'thumb url');

// VALID_ID's charset is the ONLY thing keeping thumbURL injection-proof (the id
// is interpolated into the Drive URL): pin that no URL-significant character
// gets through — no scheme (:), path (/ .), query (& ? =), host (@), or space.
for (const ch of [':', '/', '.', '&', '?', '=', '@', '#', ' ', '%', '"', "'", '<', '>']) {
  const id = 'aaaaaaaaaa' + ch + 'aaaaaaaaaa';
  assert.ok(!VALID_ID.test(id), `id containing "${ch}" rejected`);
  assert.ok(!validateManifest({ ...sample, g: [id] }), `manifest with "${ch}" id rejected`);
}

// A framed (0x01) fragment whose DEFLATE stream is corrupt must yield null,
// never a throw that breaks the page script.
{
  const junk = new Uint8Array(64).fill(0xAB); junk[0] = 1;
  const frag = Buffer.from(junk).toString('base64').replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
  assert.strictEqual(decodeManifest(frag), null, 'corrupt DEFLATE with marker → null');
}

// Invalid pdf id (`p`) must fail validation like a bad grid id would.
assert.ok(!validateManifest({ ...sample, p: 'short' }), 'bad pdf id rejected');
assert.ok(!validateManifest({ ...sample, p: 42 }), 'non-string pdf id rejected');

// Expiry boundary: the link stays live THROUGH the displayed expiry day
// (local end-of-day rule) and reads expired the day after.
assert.ok(!isExpired(sample, new Date('2026-04-04T23:00:00')), 'live through the expiry day');
assert.ok(isExpired(sample, new Date('2026-04-05T01:00:00')), 'expired the day after');

// ---------------------------------------------------------------- Spec 07 v2

// `y` (layout): absent or any short string is accepted — an UNKNOWN value is
// forward-compat (layoutOf falls back to grid), not a rejection.
assert.ok(validateManifest({ ...sample, y: 'sheet' }), 'known layout accepted');
assert.ok(validateManifest({ ...sample, y: 'essay' }), 'essay layout accepted');
assert.ok(validateManifest({ ...sample, y: 'stack' }), 'editorial stack layout accepted');
assert.ok(validateManifest({ ...sample, y: 'future-layout' }), 'unknown layout tolerated (forward-compat)');
assert.ok(!validateManifest({ ...sample, y: 123 }), 'non-string layout rejected');
assert.ok(!validateManifest({ ...sample, y: 'x'.repeat(17) }), 'over-long layout rejected');

// `s` (body text) is display text and takes the field cap.
assert.ok(validateManifest({ ...sample, s: 'An intro paragraph.' }), 'body text accepted');
assert.ok(validateManifest({ ...sample, s: 'x'.repeat(4096) }), 'body text at the cap accepted');
assert.ok(!validateManifest({ ...sample, s: 'x'.repeat(4097) }), 'oversized body text rejected');

assert.strictEqual(layoutOf({}), 'grid', 'absent layout → grid');
assert.strictEqual(layoutOf({ y: 'grid' }), 'grid');
assert.strictEqual(layoutOf({ y: 'sheet' }), 'sheet');
assert.strictEqual(layoutOf({ y: 'essay' }), 'essay');
assert.strictEqual(layoutOf({ y: 'stack' }), 'stack');
assert.strictEqual(layoutOf({ y: 'unknown-future-value' }), 'grid', 'unknown layout → grid');

// Editorial keeps one width except for distinctly tall portrait frames.
assert.ok(!isTallEditorialImage(1600, 1200), 'landscape keeps the standard width');
assert.ok(!isTallEditorialImage(1200, 1500), '4:5 portrait keeps the standard width');
assert.ok(isTallEditorialImage(1000, 1500), '2:3 portrait steps down');
assert.ok(!isTallEditorialImage(0, 1500), 'missing dimensions never classify as tall');
assert.deepStrictEqual(Array.from({ length: 10 }, (_, i) => editorialRowForIndex(i)),
  [1, 1, 2, 2, 3, 4, 4, 5, 5, 6], 'five-image Editorial phrase repeats over three rows');

// The essay layout has no density control; grid keeps its shipped 1–6 range.
assert.strictEqual(SIZER_BY_LAYOUT.grid.min, 1);
assert.strictEqual(SIZER_BY_LAYOUT.grid.max, 6);
assert.ok(SIZER_BY_LAYOUT.essay.max <= SIZER_BY_LAYOUT.essay.min, 'essay sizer disabled');
assert.ok(SIZER_BY_LAYOUT.stack.max <= SIZER_BY_LAYOUT.stack.min, 'editorial sizer disabled');

// `u` points only at a public, Muse-created layout.json sidecar.
assert.ok(validateManifest({ ...sample, u: 'u'.repeat(20) }), 'layout sidecar id accepted');
assert.ok(!validateManifest({ ...sample, u: 'short' }), 'bad layout sidecar id rejected');
assert.strictEqual(acceptFetchedLayoutSettings('{"y":"grid"}'), 'grid');
assert.strictEqual(acceptFetchedLayoutSettings('{"y":"stack"}'), 'stack');
assert.strictEqual(acceptFetchedLayoutSettings('{"y":"essay"}'), null, 'hidden layout rejected');
assert.strictEqual(acceptFetchedLayoutSettings('{"y":"stack","extra":true}'), 'stack');
assert.strictEqual(acceptFetchedLayoutSettings('not json'), null);
assert.strictEqual(acceptFetchedLayoutSettings('x'.repeat(4097)), null, 'layout settings bounded');

// `e` stays REQUIRED for classic (non-portfolio) manifests — the fail-open guard.
{
  const noExpiry = { ...sample }; delete noExpiry.e;
  assert.ok(!validateManifest(noExpiry), 'classic manifest without e rejected');
  assert.ok(!validateManifest({ ...sample, e: '' }), 'classic manifest with empty e rejected');
}

// `m` present ⇒ portfolio ⇒ never expires, `e` ignored.
{
  const portfolio = { ...sample, m: 'm'.repeat(20), e: '' };
  assert.ok(validateManifest(portfolio), 'portfolio manifest with empty e accepted');
  assert.ok(validateManifest({ ...portfolio, e: 'ignored' }), 'portfolio tolerates a junk e');
  assert.ok(!validateManifest({ ...sample, m: 'too-short' }), 'malformed manifest id rejected');
  assert.ok(!validateManifest({ ...sample, m: 123 }), 'non-string manifest id rejected');
  assert.ok(isPortfolioManifest(portfolio), 'legacy m marks a portfolio');
}

// New fetched portfolios identify themselves with `k`; classic remote
// manifests remain expiry-strict.
{
  const portfolio = { ...sample, e: '', k: 'portfolio' };
  assert.ok(validateManifest(portfolio), 'portfolio kind permits no expiry');
  assert.ok(isPortfolioManifest(portfolio), 'k marks a portfolio');
  assert.ok(!validateManifest({ ...sample, k: 'unknown' }), 'unknown kind rejected');
  assert.ok(!isPortfolioManifest(sample), 'classic manifest is not a portfolio');
}

// opts.portfolio waives `e` for manifests fetched FROM Drive (they never carry
// an `m` of their own — that's the app's job).
{
  const fetched = { ...sample, e: '' };
  assert.ok(validateManifest(fetched, { portfolio: true }), 'fetched manifest validates with opts');
  assert.ok(!validateManifest(fetched), 'same object without opts stays strict');
}

assert.match(manifestFetchURL('a'.repeat(20)),
  /^\/drive-json\/a{20}$/,
  'manifest fetch URL shape');
assert.match(manifestFetchURL('a'.repeat(20), 123), /\?v=123$/, 'cache revision appended');
{
  const upstream = new URL(driveDownloadURL('a'.repeat(20), '1722912345678'));
  assert.strictEqual(upstream.hostname, 'drive.usercontent.google.com');
  assert.strictEqual(upstream.searchParams.get('id'), 'a'.repeat(20));
  assert.strictEqual(upstream.searchParams.get('v'), '1722912345678',
                     'layout cache revision reaches the upstream Drive URL');
  const untrustedRevision = new URL(driveDownloadURL('a'.repeat(20), 'x&confirm=no'));
  assert.strictEqual(untrustedRevision.searchParams.get('v'), null,
                     'untrusted revision is not reflected upstream');
}

// acceptFetchedManifest: bounded, validated, and never chains.
{
  const ok = JSON.stringify(sample);
  assert.strictEqual(acceptFetchedManifest(ok).i, sample.i, 'valid fetched body accepted');
  assert.strictEqual(acceptFetchedManifest(JSON.stringify({ ...sample, e: '' })), null,
                     'fetched classic remains expiry-strict');
  assert.strictEqual(acceptFetchedManifest(JSON.stringify({ ...sample, e: '', k: 'portfolio' })).k,
                     'portfolio', 'fetched portfolio kind accepted');
  assert.strictEqual(acceptFetchedManifest('{not json'), null, 'invalid JSON rejected');
  assert.strictEqual(acceptFetchedManifest(JSON.stringify({ i: 'x' })), null, 'structurally invalid rejected');
  const huge = JSON.stringify({ i: 'x'.repeat(600 * 1024) });
  assert.strictEqual(acceptFetchedManifest(huge), null, 'oversized body rejected (bounded read)');
  const chained = JSON.stringify({ ...sample, e: '', m: 'z'.repeat(20) });
  assert.strictEqual(acceptFetchedManifest(chained, { portfolio: true }).m, undefined,
                     'fetched m stripped — exactly one fetch');
}

// readCapped: the byte cap has to bite BEFORE the body is buffered, since the
// fetched id comes from the unsigned fragment.
{
  const capped = await readCapped(new Response('hello'), 1024);
  assert.strictEqual(capped, 'hello', 'small body read whole');

  const declared = new Response('x'.repeat(100), { headers: { 'content-length': '999999' } });
  assert.strictEqual(await readCapped(declared, 1024), null,
                     'declared Content-Length over the cap is refused without reading');

  // No Content-Length: the stream itself has to be cut off.
  const stream = new ReadableStream({
    start(controller) {
      const chunk = new Uint8Array(4096).fill(65);
      for (let i = 0; i < 4; i++) controller.enqueue(chunk);
      controller.close();
    },
  });
  assert.strictEqual(await readCapped(new Response(stream), 1024), null,
                     'undeclared oversized body is cancelled mid-stream');
}

console.log('share.js: all tests passed');
