#!/usr/bin/env node
import { readFile } from 'node:fs/promises';

const policy = {
  advisory: 'GHSA-w5hq-g745-h8pq',
  expiresOn: '2026-08-31',
  severity: 'moderate',
  uuidVersion: '9.0.1',
  auditVia: new Map([
    ['@google-cloud/firestore', ['google-gax']],
    ['@google-cloud/storage', ['retry-request', 'teeny-request']],
    ['firebase-admin', ['@google-cloud/firestore', '@google-cloud/storage']],
    ['firebase-functions', ['firebase-admin']],
    ['gaxios', ['uuid']],
    ['google-gax', ['retry-request', 'uuid']],
    ['retry-request', ['teeny-request']],
    ['teeny-request', ['uuid']],
    ['uuid', ['advisory:GHSA-w5hq-g745-h8pq:moderate']],
  ]),
  lockEdges: new Map([
    ['firebase-functions', ['firebase-admin']],
    ['firebase-admin', ['@google-cloud/firestore', '@google-cloud/storage']],
    ['@google-cloud/firestore', ['google-gax']],
    ['@google-cloud/storage', ['gaxios', 'retry-request', 'teeny-request']],
    ['google-gax', ['retry-request', 'uuid']],
    ['gaxios', ['uuid']],
    ['retry-request', ['teeny-request']],
    ['teeny-request', ['uuid']],
    ['uuid', []],
  ]),
  paths: [
    ['firebase-admin', '@google-cloud/firestore', 'google-gax', 'uuid'],
    ['firebase-admin', '@google-cloud/firestore', 'google-gax', 'retry-request', 'teeny-request', 'uuid'],
    ['firebase-admin', '@google-cloud/storage', 'gaxios', 'uuid'],
    ['firebase-admin', '@google-cloud/storage', 'retry-request', 'teeny-request', 'uuid'],
    ['firebase-admin', '@google-cloud/storage', 'teeny-request', 'uuid'],
  ],
};

const args = parseArgs(process.argv.slice(2));

try {
  const [audit, lock] = await Promise.all([
    readJson(args.audit, 'audit'),
    readJson(args.lock, 'lock'),
  ]);
  checkExpiry(args.asOf);
  checkAudit(audit);
  checkLock(lock);
  console.log(
    `Broker audit policy passed: ${policy.advisory} is the only accepted advisory through ${policy.paths.length} exact uuid@${policy.uuidVersion} paths until ${policy.expiresOn}.`,
  );
} catch (error) {
  console.error(`Broker audit policy failed: ${error.message}`);
  process.exit(1);
}

function parseArgs(args) {
  if (args.length % 2 !== 0) {
    throw new Error(usage());
  }
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index];
    const value = args[index + 1];
    if (!['--audit', '--lock', '--as-of'].includes(name) || !value || values.has(name)) {
      throw new Error(usage());
    }
    values.set(name, value);
  }
  const audit = values.get('--audit');
  const lock = values.get('--lock');
  if (!audit || !lock) {
    throw new Error(usage());
  }
  return { audit, lock, asOf: values.get('--as-of') };
}

function usage() {
  return 'usage: check_broker_audit.mjs --audit <npm-audit.json> --lock <package-lock.json> [--as-of <YYYY-MM-DD>]';
}

async function readJson(path, label) {
  try {
    return JSON.parse(await readFile(path, 'utf8'));
  } catch (error) {
    throw new Error(`${label} JSON is malformed or unreadable: ${error.message}`);
  }
}

function checkExpiry(asOf) {
  let currentTime = new Date();
  if (asOf) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(asOf)) {
      throw new Error('--as-of must use YYYY-MM-DD');
    }
    currentTime = new Date(`${asOf}T00:00:00Z`);
    if (Number.isNaN(currentTime.valueOf()) || currentTime.toISOString().slice(0, 10) !== asOf) {
      throw new Error('--as-of is not a valid calendar date');
    }
  }
  const expiresAt = new Date(`${policy.expiresOn}T23:59:59.999Z`);
  if (currentTime > expiresAt) {
    throw new Error(`exception expired on ${policy.expiresOn}`);
  }
}

function checkAudit(audit) {
  if (!audit || typeof audit !== 'object' || !audit.vulnerabilities || typeof audit.vulnerabilities !== 'object') {
    throw new Error('audit JSON has no vulnerabilities object');
  }
  const vulnerabilities = audit.vulnerabilities;
  compareExact(
    Object.keys(vulnerabilities),
    [...policy.auditVia.keys()],
    'audit package set',
  );

  for (const [name, expectedVia] of policy.auditVia) {
    const vulnerability = vulnerabilities[name];
    if (!vulnerability || vulnerability.severity !== policy.severity) {
      throw new Error(`${name} severity is not exactly ${policy.severity}`);
    }
    if (!Array.isArray(vulnerability.via)) {
      throw new Error(`${name} has no auditable dependency chain`);
    }
    const actualVia = vulnerability.via.map((via) => normalizeAuditVia(name, via));
    compareExact(actualVia, expectedVia, `${name} audit edges`);
  }
}

function normalizeAuditVia(name, via) {
  if (typeof via === 'string') {
    return via;
  }
  if (!via || typeof via !== 'object') {
    throw new Error(`${name} has a malformed audit edge`);
  }
  const advisory = via.url?.split('/').at(-1);
  return `advisory:${advisory}:${via.severity}`;
}

function checkLock(lock) {
  if (!lock || typeof lock !== 'object' || !lock.packages || typeof lock.packages !== 'object') {
    throw new Error('lock JSON has no packages object');
  }
  const packages = lock.packages;
  const uuid = packages['node_modules/uuid'];
  if (!uuid || uuid.version !== policy.uuidVersion) {
    throw new Error(`uuid lock state is not uuid@${policy.uuidVersion}`);
  }

  const graphNames = new Set(policy.lockEdges.keys());
  for (const [name, expectedEdges] of policy.lockEdges) {
    const entry = packageAt(packages, name);
    const declared = {
      ...entry.dependencies,
      ...entry.optionalDependencies,
      ...entry.peerDependencies,
    };
    const actualEdges = Object.keys(declared).filter((dependency) => graphNames.has(dependency));
    compareExact(actualEdges, expectedEdges, `${name} locked vulnerable edges`);
  }

  const actualPaths = enumeratePolicyPaths(policy.lockEdges, 'firebase-admin', 'uuid');
  compareExact(
    actualPaths.map((path) => path.join(' > ')),
    policy.paths.map((path) => path.join(' > ')),
    'approved uuid lock paths',
  );
}

function packageAt(packages, name) {
  const entry = packages[`node_modules/${name}`];
  if (!entry) throw new Error(`lock is missing node_modules/${name}`);
  return entry;
}

function enumeratePolicyPaths(edges, start, target, path = [start]) {
  if (start === target) return [path];
  const paths = [];
  for (const child of edges.get(start) ?? []) {
    if (!path.includes(child)) {
      paths.push(...enumeratePolicyPaths(edges, child, target, [...path, child]));
    }
  }
  return paths;
}

function compareExact(actual, expected, label) {
  const sortedActual = [...actual].sort();
  const sortedExpected = [...expected].sort();
  if (JSON.stringify(sortedActual) !== JSON.stringify(sortedExpected)) {
    throw new Error(`${label} changed: expected [${sortedExpected.join(', ')}], received [${sortedActual.join(', ')}]`);
  }
}
