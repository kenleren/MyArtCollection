import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import test from 'node:test';
import { checkCleanAudit } from '../scripts/check_broker_audit.mjs';

const execFileAsync = promisify(execFile);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const script = path.join(repoRoot, 'scripts/check_broker_audit.mjs');
const fixture = (name) => path.join(repoRoot, 'test/fixtures/broker-audit', name);
const clean = JSON.parse(await readFile(fixture('clean-audit.json'), 'utf8'));

test('accepts two clean audit reports without a date-limited exception', async () => {
  const result = await run();
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /zero vulnerabilities; no exceptions/);
});

for (const input of ['--audit', '--core-audit']) {
  for (const name of ['expired-exception-audit.json', 'npm-error-audit.json', 'malformed-audit.json']) {
    test(`rejects ${name} in ${input}`, async () => {
      const result = await run({ [input]: fixture(name) });
      assert.equal(result.code, 1);
      assert.match(result.stderr, /Broker audit policy failed/);
    });
  }
  test(`rejects missing file in ${input}`, async () => {
    const result = await run({ [input]: fixture('does-not-exist.json') });
    assert.equal(result.code, 1);
  });
}

for (const severity of ['info', 'low', 'moderate', 'high', 'critical', 'total']) {
  test(`rejects a nonzero ${severity} count even with an empty vulnerability map`, () => {
    const report = structuredClone(clean);
    report.metadata.vulnerabilities[severity] = 1;
    assert.throws(() => checkCleanAudit(report), /must all be zero/);
  });
}

test('rejects a vulnerability even when all severity counts say zero', () => {
  const report = structuredClone(clean);
  report.vulnerabilities.uuid = { severity: 'moderate' };
  assert.throws(() => checkCleanAudit(report), /no exceptions/);
});

for (const [name, mutate] of [
  ['top-level npm error', (r) => { r.error = { code: 'EAUDITNOLOCK' }; }],
  ['unknown report field', (r) => { r.extra = true; }],
  ['unsupported report version', (r) => { r.auditReportVersion = 1; }],
  ['missing vulnerability map', (r) => { delete r.vulnerabilities; }],
  ['array vulnerability map', (r) => { r.vulnerabilities = []; }],
  ['null metadata', (r) => { r.metadata = null; }],
  ['missing severity', (r) => { delete r.metadata.vulnerabilities.low; }],
  ['string severity count', (r) => { r.metadata.vulnerabilities.low = '0'; }],
  ['unknown severity', (r) => { r.metadata.vulnerabilities.extra = 0; }],
  ['missing dependency count', (r) => { delete r.metadata.dependencies.prod; }],
  ['unknown dependency count', (r) => { r.metadata.dependencies.extra = 0; }],
  ['negative dependency count', (r) => { r.metadata.dependencies.prod = -1; }],
  ['fractional dependency count', (r) => { r.metadata.dependencies.prod = 1.1; }],
  ['unsafe dependency count', (r) => { r.metadata.dependencies.prod = Number.MAX_SAFE_INTEGER + 1; }],
  ['string dependency count', (r) => { r.metadata.dependencies.prod = '160'; }],
  ['empty dependency inventory', (r) => { r.metadata.dependencies.total = 0; }],
]) {
  test(`rejects ${name}`, () => {
    const report = structuredClone(clean);
    mutate(report);
    assert.throws(() => checkCleanAudit(report));
  });
}

for (const [name, args] of [
  ['clock override', ['--as-of', '2026-07-01']],
  ['severity override', ['--audit-level', 'high']],
  ['duplicate argument', ['--audit', fixture('clean-audit.json')]],
]) {
  test(`rejects ${name}`, async () => {
    const result = await run({}, args);
    assert.equal(result.code, 1);
    assert.match(result.stderr, /usage:/);
  });
}

test('validates the second report even if the first report is clean', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'broker-clean-audit-'));
  try {
    const report = structuredClone(clean);
    report.metadata.vulnerabilities.high = 1;
    const file = path.join(directory, 'nonzero.json');
    await writeFile(file, JSON.stringify(report));
    const result = await run({ '--core-audit': file });
    assert.equal(result.code, 1);
    assert.match(result.stderr, /peer-omitted audit vulnerability counts/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

async function run(overrides = {}, extraArgs = []) {
  const paths = { '--audit': fixture('clean-audit.json'), '--core-audit': fixture('clean-audit.json'), ...overrides };
  try {
    const result = await execFileAsync(process.execPath, [script, ...Object.entries(paths).flat(), ...extraArgs], {
      cwd: repoRoot,
      env: { PATH: process.env.PATH, TZ: 'UTC' },
    });
    return { code: 0, ...result };
  } catch (error) {
    return { code: error.code, stdout: error.stdout, stderr: error.stderr };
  }
}
