import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import test from 'node:test';

const execFileAsync = promisify(execFile);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const script = path.join(repoRoot, 'scripts/check_broker_audit.mjs');
const fixture = (name) => path.join(repoRoot, 'test/fixtures/broker-audit', name);

test('accepts the current expiry-dated uuid exception', async () => {
  const result = await run('allowed-audit.json', 'allowed-lock.json');
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /GHSA-w5hq-g745-h8pq/);
});

for (const [name, audit, lock, message] of [
  ['rejects a new advisory', 'new-advisory-audit.json', 'allowed-lock.json', /approved uuid advisory graph/],
  ['rejects high severity', 'high-severity-audit.json', 'allowed-lock.json', /approved uuid advisory graph/],
  ['rejects a changed uuid lock state', 'allowed-audit.json', 'changed-uuid-lock.json', /uuid@9\.0\.1/],
  ['rejects a missing allowed dependency path', 'allowed-audit.json', 'missing-path-lock.json', /locked path is missing/],
  ['rejects malformed audit JSON', 'malformed-audit.json', 'allowed-lock.json', /malformed or unreadable/],
]) {
  test(name, async () => {
    const result = await run(audit, lock);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, message);
  });
}

async function run(audit, lock) {
  try {
    const result = await execFileAsync('node', [script, '--audit', fixture(audit), '--lock', fixture(lock)]);
    return { code: 0, ...result };
  } catch (error) {
    return { code: error.code ?? 1, stdout: error.stdout ?? '', stderr: error.stderr ?? '' };
  }
}
