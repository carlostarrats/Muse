// share.test.mjs  — run: node web/share/share.test.mjs
import assert from 'node:assert';
import { deflateSync, strToU8 } from './fflate.module.js';
import { decodeManifest, validateManifest, isExpired, thumbURL, VALID_ID, sanitizeText } from './share.js';

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
assert.ok(isExpired({ ...sample, e:'2020-01-01' }, new Date('2026-01-01')), 'past → expired');
assert.ok(!isExpired(sample, new Date('2026-04-02')), 'before expiry → live');
assert.ok(VALID_ID.test('aaaaaaaaaaaaaaaaaaaa'), 'id regex ok');
assert.ok(!VALID_ID.test('short'), 'short id rejected');
assert.ok(thumbURL('aaaaaaaaaaaaaaaaaaaa').startsWith('https://drive.google.com/thumbnail?id='), 'thumb url');
console.log('share.js: all tests passed');
