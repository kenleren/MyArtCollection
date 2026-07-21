import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import test from 'node:test';
import { checkExpiryForTest } from '../scripts/check_broker_audit.mjs';

const execFileAsync = promisify(execFile);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const script = path.join(repoRoot, 'scripts/check_broker_audit.mjs');
const fixture = (name) => path.join(repoRoot, 'test/fixtures/broker-audit', name);
const policyDates = await readJsonFixture('policy-dates.json');
const adversarialCases = await readJsonFixture('adversarial-cases.json');

test('accepts the exact current npm audit and lock graph before expiry', async () => {
  const result = await run(fixture('allowed-audit.json'), fixture('allowed-lock.json'));
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /5 exact uuid@9\.0\.1 paths/);
});

test('rejects a stale Firebase Admin remediation target', async () => {
  const temporaryDirectory = await mkdtemp(path.join(os.tmpdir(), 'broker-stale-fix-'));
  try {
    const audit = await readJsonFixture('allowed-audit.json');
    audit.vulnerabilities['@google-cloud/firestore'].fixAvailable.version = '14.1.0';
    const auditPath = path.join(temporaryDirectory, 'audit.json');
    await writeFile(auditPath, JSON.stringify(audit));
    const result = await run(auditPath, fixture('allowed-lock.json'));
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, /@google-cloud\/firestore full audit fix metadata changed/);
  } finally {
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
});

test('accepts only the exact known full-audit peer metadata edge', async () => {
  const temporaryDirectory = await mkdtemp(path.join(os.tmpdir(), 'broker-peer-audit-'));
  try {
    const auditPath = path.join(temporaryDirectory, 'audit.json');
    await writeFile(auditPath, JSON.stringify(await createPeerAudit()));
    const result = await run(auditPath, fixture('allowed-lock.json'));
    assert.equal(result.code, 0, result.stderr);
  } finally {
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
});

test('accepts only the known omitted-peer count in peer-omitted metadata', async () => {
  const temporaryDirectory = await mkdtemp(path.join(os.tmpdir(), 'broker-core-audit-'));
  try {
    const coreAudit = await readJsonFixture('allowed-audit.json');
    coreAudit.metadata.vulnerabilities.moderate = 9;
    coreAudit.metadata.vulnerabilities.total = 9;
    const coreAuditPath = path.join(temporaryDirectory, 'core-audit.json');
    await writeFile(coreAuditPath, JSON.stringify(coreAudit));
    const result = await run(fixture('allowed-audit.json'), fixture('allowed-lock.json'), {
      coreAuditPath,
    });
    assert.equal(result.code, 0, result.stderr);
  } finally {
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
});

test('accepts only the exact peer node when npm retains it under omit=peer', async () => {
  const temporaryDirectory = await mkdtemp(path.join(os.tmpdir(), 'broker-retained-peer-'));
  try {
    const coreAuditPath = path.join(temporaryDirectory, 'core-audit.json');
    await writeFile(coreAuditPath, JSON.stringify(await createPeerAudit()));
    const result = await run(fixture('allowed-audit.json'), fixture('allowed-lock.json'), {
      coreAuditPath,
    });
    assert.equal(result.code, 0, result.stderr);
  } finally {
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
});

test('accepts the exception deterministically on its last allowed date', () => {
  assert.doesNotThrow(() => checkExpiryForTest(policyDates.lastAllowedDate));
});

const expectedFailures = new Map([
  ['top-level-error', /top-level npm error/],
  ['unknown-top-level-field', /full audit top-level fields changed/],
  ['untrusted-advisory-origin', /exact trusted GitHub advisory origin and path/],
  ['extra-advisory-field', /uuid full audit edges changed/],
  ['extra-uuid-node-and-effect', /uuid full audit effects changed/],
  ['new-advisory', /exact trusted GitHub advisory origin and path/],
  ['high-severity', /uuid severity is not exactly moderate/],
  ['extra-audit-edge', /firebase-admin full audit edges changed/],
  ['rerouted-audit-edge', /@google-cloud\/storage full audit edges changed/],
  ['missing-audit-field', /uuid full audit vulnerability fields changed/],
  ['changed-audit-metadata', /full audit metadata vulnerability counts changed/],
  ['unsupported-vulnerability-count', /bounded schema/],
  ['malformed-dependency-metadata', /dependency count total is not a nonnegative integer/],
  ['extra-dependency-metadata-field', /dependency fields changed/],
  ['extra-peer-node', /firebase-functions peer metadata nodes changed/],
  ['extra-peer-effect', /firebase-functions peer metadata effects changed/],
  ['rerouted-peer-edge', /firebase-functions peer metadata edges changed/],
  ['missing-peer-reverse-effect', /firebase-admin full audit effects changed/],
  ['extra-peer-reverse-effect', /firebase-admin full audit effects changed/],
  ['unexpected-derived-fix-target', /@google-cloud\/firestore full audit fix metadata changed shape/],
  ['extra-derived-fix-field', /@google-cloud\/firestore full audit fix metadata fields changed/],
  ['rerouted-root-peer', /broker root dependency declarations changed/],
  ['extra-lock-edge', /firebase-admin locked vulnerable edges changed/],
  ['rerouted-lock-range', /@google-cloud\/storage locked vulnerable edges changed/],
  ['changed-uuid-version', /node_modules\/uuid version changed/],
  ['missing-lock-path', /@google-cloud\/storage locked vulnerable edges changed/],
  ['nested-rerouted-uuid', /uuid installation paths changed/],
  ['extra-nested-uuid', /uuid installation paths changed/],
  ['changed-package-integrity', /node_modules\/gaxios integrity changed/],
]);

for (const adversarialCase of adversarialCases) {
  test(`rejects ${adversarialCase.description}`, async () => {
    const result = await runMutationCase(adversarialCase);
    assert.notEqual(result.code, 0);
    assert.match(result.stderr, expectedFailures.get(adversarialCase.id));
  });
}

test('rejects a standalone npm audit exit-1 error response', async () => {
  const result = await run(fixture('npm-error-audit.json'), fixture('allowed-lock.json'));
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /top-level npm error/);
});

test('rejects a peer-omitted npm audit exit-1 error response', async () => {
  const result = await run(fixture('allowed-audit.json'), fixture('allowed-lock.json'), {
    coreAuditPath: fixture('npm-error-audit.json'),
  });
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /peer-omitted audit reported a top-level npm error/);
});

test('rejects malformed audit JSON', async () => {
  const result = await run(fixture('malformed-audit.json'), fixture('allowed-lock.json'));
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /malformed or unreadable/);
});

test('rejects the exception deterministically after expiry', () => {
  assert.throws(
    () => checkExpiryForTest(policyDates.firstExpiredDate),
    /exception expired on 2026-08-31/,
  );
});

for (const [label, asOf, message] of [
  ['invalid calendar date', policyDates.invalidCalendarDate, /not a valid calendar date/],
  ['timestamp-shaped clock input', policyDates.invalidClockInput, /must use YYYY-MM-DD/],
]) {
  test(`rejects ${label} in the deterministic expiry harness`, () => {
    assert.throws(() => checkExpiryForTest(asOf), message);
  });
}

test('does not expose the deterministic clock override on the production CLI', async () => {
  const result = await run(
    fixture('allowed-audit.json'),
    fixture('allowed-lock.json'),
    { extraArgs: ['--as-of', policyDates.lastAllowedDate] },
  );
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /usage:/);
});

async function runMutationCase(adversarialCase) {
  const temporaryDirectory = await mkdtemp(path.join(os.tmpdir(), 'broker-audit-policy-'));
  try {
    const audit = await readJsonFixture('allowed-audit.json');
    const coreAudit = await readJsonFixture('allowed-audit.json');
    const lock = await readJsonFixture('allowed-lock.json');
    for (const mutation of adversarialCase.mutations) {
      if (mutation.target === 'audit') {
        applyMutation(audit, mutation);
        applyMutation(coreAudit, mutation);
      } else if (mutation.target === 'peerAudit') {
        if (!audit.vulnerabilities['firebase-functions']) {
          const peerAudit = await createPeerAudit();
          Object.assign(audit, peerAudit);
        }
        applyMutation(audit, mutation);
      } else {
        applyMutation(lock, mutation);
      }
    }
    const auditPath = path.join(temporaryDirectory, 'audit.json');
    const coreAuditPath = path.join(temporaryDirectory, 'core-audit.json');
    const lockPath = path.join(temporaryDirectory, 'package-lock.json');
    await Promise.all([
      writeFile(auditPath, JSON.stringify(audit)),
      writeFile(coreAuditPath, JSON.stringify(coreAudit)),
      writeFile(lockPath, JSON.stringify(lock)),
    ]);
    return await run(auditPath, lockPath, { coreAuditPath });
  } finally {
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
}

function applyMutation(document, mutation) {
  const pathParts = [...mutation.path];
  const finalPart = pathParts.pop();
  let parent = document;
  for (const part of pathParts) parent = parent[part];
  if (mutation.operation === 'set') parent[finalPart] = mutation.value;
  else if (mutation.operation === 'delete') delete parent[finalPart];
  else if (mutation.operation === 'append') parent[finalPart].push(mutation.value);
  else throw new Error(`Unknown fixture mutation: ${mutation.operation}`);
}

async function readJsonFixture(name) {
  return JSON.parse(await readFile(fixture(name), 'utf8'));
}

async function createPeerAudit() {
  const audit = await readJsonFixture('allowed-audit.json');
  audit.vulnerabilities['firebase-functions'] = await readJsonFixture('allowed-peer-metadata.json');
  audit.vulnerabilities['firebase-admin'].effects = ['firebase-functions'];
  audit.metadata.vulnerabilities.moderate = 9;
  audit.metadata.vulnerabilities.total = 9;
  return audit;
}

async function run(
  auditPath,
  lockPath,
  { coreAuditPath = fixture('allowed-audit.json'), extraArgs = [] } = {},
) {
  const args = [
    script,
    '--audit', auditPath,
    '--core-audit', coreAuditPath,
    '--lock', lockPath,
    ...extraArgs,
  ];
  try {
    const result = await execFileAsync('node', args);
    return { code: 0, ...result };
  } catch (error) {
    return { code: error.code ?? 1, stdout: error.stdout ?? '', stderr: error.stderr ?? '' };
  }
}
