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
assert.ok(!validateManifest({ ...sample, g:['short'] }), 'bad id rejected');
assert.ok(!validateManifest({ ...sample, g:[] }), 'empty grid rejected');
assert.ok(isExpired({ ...sample, e:'2020-01-01' }, new Date('2026-01-01')), 'past → expired');
assert.ok(!isExpired(sample, new Date('2026-04-02')), 'before expiry → live');
assert.ok(VALID_ID.test('aaaaaaaaaaaaaaaaaaaa'), 'id regex ok');
assert.ok(!VALID_ID.test('short'), 'short id rejected');
assert.ok(thumbURL('aaaaaaaaaaaaaaaaaaaa').startsWith('https://drive.google.com/thumbnail?id='), 'thumb url');
console.log('share.js: all tests passed');
