import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

import {
  canonicalPayloadV1,
  canonicalizeRfc8785,
  validateCanonicalPayloadV1,
} from '../src/canonical_payload.js';
import type { BrokerRequest } from '../src/contracts.js';
import { request } from './test_helpers.js';

interface CanonicalFixture {
  contract_version: string;
  vectors: Array<{
    name: string;
    request: BrokerRequest;
    canonical_json: string;
    sha256: string;
  }>;
}

test('canonical-payload-v1 golden vectors match RFC 8785 bytes and SHA-256', async () => {
  const fixture = JSON.parse(
    await readFile(new URL('../../fixtures/canonical-payload-v1.json', import.meta.url), 'utf8'),
  ) as CanonicalFixture;
  assert.equal(fixture.contract_version, 'canonical-payload-v1');

  for (const vector of fixture.vectors) {
    const canonical = canonicalPayloadV1(vector.request);
    assert.equal(canonical.json, vector.canonical_json, vector.name);
    assert.deepEqual(canonical.bytes, Buffer.from(vector.canonical_json, 'utf8'), vector.name);
    assert.equal(canonical.sha256, vector.sha256, vector.name);
    assert.equal(validateCanonicalPayloadV1(vector.request), undefined, vector.name);
  }
});

test('canonicalization sorts object properties and preserves array order', () => {
  assert.equal(
    canonicalizeRfc8785({ z: [3, 2, 1], a: { y: true, x: -0 } }),
    '{"a":{"x":0,"y":true},"z":[3,2,1]}',
  );
});

test('request_id and payload_hash are excluded from canonical bytes', () => {
  const first = request();
  const second = { ...first, request_id: '22222222-2222-4222-8222-222222222222', payload_hash: 'f'.repeat(64) };
  assert.equal(canonicalPayloadV1(first).json, canonicalPayloadV1(second).json);
});

test('hash mismatch, noncanonical base64, and byte-count mismatch fail closed', () => {
  assert.equal(validateCanonicalPayloadV1(request({ payload_hash: 'f'.repeat(64) })), 'payload_hash_mismatch');
  assert.equal(
    validateCanonicalPayloadV1(request({
      image: { mime_type: 'image/jpeg', byte_size: 3, long_edge_px: 1600, content_base64: 'AQID\n' },
    })),
    'invalid_image_encoding',
  );
  assert.equal(
    validateCanonicalPayloadV1(request({
      image: { mime_type: 'image/jpeg', byte_size: 4, long_edge_px: 1600, content_base64: 'AQID' },
    })),
    'invalid_image_encoding',
  );
});

test('lone Unicode surrogates and hints under image-only consent fail closed', () => {
  const malformedUnicode = request({
    consent_scope: 'image_plus_draft_hints',
    draft_hints: { title_hint: 'valid before mutation' },
  });
  malformedUnicode.draft_hints!.title_hint = '\ud800';
  assert.equal(
    validateCanonicalPayloadV1(malformedUnicode),
    'invalid_unicode',
  );
  assert.equal(
    validateCanonicalPayloadV1(request({ draft_hints: { title_hint: 'not consented' } })),
    'invalid_request_payload',
  );
});
