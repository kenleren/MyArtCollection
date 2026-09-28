import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import test from 'node:test';

const require = createRequire(import.meta.url);
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

test('patched UUID retains the CommonJS v4 API at each Google dependency edge', () => {
  for (const consumer of ['google-gax', 'gaxios', 'teeny-request']) {
    const consumerRequire = createRequire(require.resolve(consumer));
    const uuid = consumerRequire('uuid');
    assert.match(uuid.v4(), uuidPattern, consumer);
    const buffer = new Uint8Array(16);
    assert.equal(uuid.v4({}, buffer), buffer, consumer);
  }
  const { makeUUID } = require('google-gax/build/src/util.js');
  assert.match(makeUUID(), uuidPattern);
});

test('gaxios builds multipart requests with patched UUID without network access', async () => {
  const { Gaxios } = require('gaxios');
  let boundary = '';
  let body = '';
  const client = new Gaxios({
    fetchImplementation: async (_url: string, options: {
      headers: Record<string, string>;
      body: AsyncIterable<Uint8Array>;
    }) => {
      boundary = options.headers['Content-Type'].split('boundary=')[1];
      for await (const chunk of options.body) body += Buffer.from(chunk).toString();
      return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
    },
  });
  await client.request({
    url: 'https://dependency-compatibility.invalid/upload',
    method: 'POST',
    multipart: [{ headers: { 'Content-Type': 'application/json' }, content: '{"fixture":true}' }],
  });
  assert.match(boundary, uuidPattern);
  assert.ok(body.includes(`--${boundary}`));
  assert.ok(body.includes('{"fixture":true}'));
});

test('patched qs handles attacker-controlled isBuffer through Express and body-parser edges', () => {
  for (const consumer of ['express', 'body-parser']) {
    const consumerRequire = createRequire(require.resolve(consumer));
    const qs = consumerRequire('qs');
    const parsed = qs.parse('x%5Bconstructor%5D%5BisBuffer%5D=y', { plainObjects: true });
    assert.doesNotThrow(() => qs.stringify(parsed), consumer);
    assert.deepEqual(qs.parse('collector=Alex&tag=painting'), { collector: 'Alex', tag: 'painting' });
  }
});
