import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import test from 'node:test';

const execFileAsync = promisify(execFile);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const script = path.join(repoRoot, 'scripts/check_broker_audit.mjs');
const fixture = (name) => path.join(repoRoot, 'test/fixtures/broker-audit', name);
const policyDates = JSON.parse(await readFile(fixture('policy-dates.json'), 'utf8'));

test('accepts the current expiry-dated uuid exception', async () => {
  const result = await run('allowed-audit.json', 'allowed-lock.json', {
    asOf: policyDates.lastAllowedDate,
  });
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /5 exact uuid@9\.0\.1 paths/);
});

test('accepts only the exact known npm peer metavulnerability edge', async () => {
  const result = await run('allowed-audit-with-peer-meta.json', 'allowed-lock.json');
  assert.equal(result.code, 0, result.stderr);
});

for (const [name, audit, lock, message] of [
  ['rejects a new advisory', 'new-advisory-audit.json', 'allowed-lock.json', /uuid full audit edges changed/],
  ['rejects high severity', 'high-severity-audit.json', 'allowed-lock.json', /uuid severity is not exactly moderate/],
  ['rejects an extra audit path', 'extra-path-audit.json', 'allowed-lock.json', /firebase-admin full audit edges changed/],
  ['rejects an extra locked path', 'allowed-audit.json', 'extra-path-lock.json', /firebase-admin locked vulnerable edges changed/],
  ['rejects a rerouted audit graph', 'rerouted-audit.json', 'allowed-lock.json', /@google-cloud\/storage full audit edges changed/],
  ['rejects a rerouted lock graph', 'allowed-audit.json', 'rerouted-lock.json', /@google-cloud\/storage locked vulnerable edges changed/],
  ['rejects a changed uuid lock state', 'allowed-audit.json', 'changed-uuid-lock.json', /uuid@9\.0\.1/],
  ['rejects a missing allowed dependency path', 'allowed-audit.json', 'missing-path-lock.json', /@google-cloud\/storage locked vulnerable edges changed/],
  ['rejects malformed audit JSON', 'malformed-audit.json', 'allowed-lock.json', /malformed or unreadable/],
]) {
  test(name, async () => {
    const result = await run(audit, lock);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, message);
  });
}

test('rejects the exception deterministically after expiry', async () => {
  const result = await run('allowed-audit.json', 'allowed-lock.json', {
    asOf: policyDates.firstExpiredDate,
  });
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /exception expired on 2026-08-31/);
});

test('rejects a rerouted peer-normalized audit graph', async () => {
  const result = await run('allowed-audit.json', 'allowed-lock.json', {
    coreAudit: 'rerouted-audit.json',
  });
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /@google-cloud\/storage peer-normalized audit edges changed/);
});

async function run(audit, lock, { asOf, coreAudit = 'allowed-audit.json' } = {}) {
  const args = [
    script,
    '--audit', fixture(audit),
    '--core-audit', fixture(coreAudit),
    '--lock', fixture(lock),
  ];
  if (asOf) args.push('--as-of', asOf);
  try {
    const result = await execFileAsync('node', args);
    return { code: 0, ...result };
  } catch (error) {
    return { code: error.code ?? 1, stdout: error.stdout ?? '', stderr: error.stderr ?? '' };
  }
}
