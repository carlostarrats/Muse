// share.test.mjs  — run: node web/share/share.test.mjs
import assert from 'node:assert';
import { decodeManifest, validateManifest, isExpired, thumbURL, VALID_ID } from './share.js';

const sample = { i:'Intro', l:'Sent by', n:'The Project', d:'2026-04-01',
  e:'2026-04-04', g:['aaaaaaaaaaaaaaaaaaaa','bbbbbbbbbbbbbbbbbbbb'], p:'cccccccccccccccccccc' };
const b64url = Buffer.from(JSON.stringify(sample)).toString('base64')
  .replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');

assert.deepStrictEqual(decodeManifest(b64url), sample, 'round-trip decode');
assert.strictEqual(decodeManifest('!!!notbase64'), null, 'garbage → null');
assert.ok(validateManifest(sample), 'valid manifest');
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
