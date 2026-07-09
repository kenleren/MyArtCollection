#!/usr/bin/env node
import { readFile } from 'node:fs/promises';

const policy = {
  advisory: 'GHSA-w5hq-g745-h8pq',
  expiresOn: '2026-08-31',
  severity: 'moderate',
  uuidVersion: '9.0.1',
  vulnerablePackages: new Set([
    '@google-cloud/firestore',
    '@google-cloud/storage',
    'firebase-admin',
    'firebase-functions',
    'gaxios',
    'google-gax',
    'retry-request',
    'teeny-request',
    'uuid',
  ]),
  paths: [
    ['firebase-admin', '@google-cloud/firestore', 'google-gax', 'uuid'],
    ['firebase-admin', '@google-cloud/storage', 'gaxios', 'uuid'],
    ['firebase-admin', '@google-cloud/storage', 'teeny-request', 'uuid'],
  ],
};

const args = parseArgs(process.argv.slice(2));

try {
  const [audit, lock] = await Promise.all([
    readJson(args.audit, 'audit'),
    readJson(args.lock, 'lock'),
  ]);
  checkExpiry();
  checkAudit(audit);
  checkLock(lock);
  console.log(`Broker audit policy passed: ${policy.advisory} is the only accepted advisory until ${policy.expiresOn}.`);
} catch (error) {
  console.error(`Broker audit policy failed: ${error.message}`);
  process.exit(1);
}

function parseArgs(args) {
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    values.set(args[index], args[index + 1]);
  }
  const audit = values.get('--audit');
  const lock = values.get('--lock');
  if (!audit || !lock || values.size !== 2) {
    throw new Error('usage: check_broker_audit.mjs --audit <npm-audit.json> --lock <package-lock.json>');
  }
  return { audit, lock };
}

async function readJson(path, label) {
  try {
    return JSON.parse(await readFile(path, 'utf8'));
  } catch (error) {
    throw new Error(`${label} JSON is malformed or unreadable: ${error.message}`);
  }
}

function checkExpiry() {
  if (new Date(`${policy.expiresOn}T23:59:59Z`) < new Date()) {
    throw new Error(`exception expired on ${policy.expiresOn}`);
  }
}

function checkAudit(audit) {
  if (!audit || typeof audit !== 'object' || !audit.vulnerabilities || typeof audit.vulnerabilities !== 'object') {
    throw new Error('audit JSON has no vulnerabilities object');
  }
  const vulnerabilities = audit.vulnerabilities;
  const known = new Set(Object.keys(vulnerabilities));
  if (!known.has('uuid')) {
    throw new Error('audit JSON does not report uuid');
  }
  if (known.size !== policy.vulnerablePackages.size || [...known].some((name) => !policy.vulnerablePackages.has(name))) {
    throw new Error('audit JSON contains a dependency outside the approved uuid advisory graph');
  }

  for (const [name, vulnerability] of Object.entries(vulnerabilities)) {
    if (!vulnerability || vulnerability.severity !== policy.severity) {
      throw new Error(`${name} severity is not exactly ${policy.severity}`);
    }
    if (!Array.isArray(vulnerability.via) || vulnerability.via.length === 0) {
      throw new Error(`${name} has no auditable dependency chain`);
    }
    for (const via of vulnerability.via) {
      if (typeof via === 'string') {
        if (!known.has(via)) {
          throw new Error(`${name} references an unknown vulnerable dependency ${via}`);
        }
        continue;
      }
      if (!via || via.url !== `https://github.com/advisories/${policy.advisory}` || via.severity !== policy.severity) {
        throw new Error(`${name} introduces an unapproved advisory`);
      }
    }
  }

  const reachesUuid = (name, seen = new Set()) => {
    if (name === 'uuid') return true;
    if (seen.has(name)) return false;
    seen.add(name);
    return vulnerabilities[name].via.some((via) => typeof via === 'string' && reachesUuid(via, new Set(seen)));
  };
  for (const name of known) {
    if (!reachesUuid(name)) {
      throw new Error(`${name} does not resolve exclusively through uuid`);
    }
  }
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
  for (const dependencyPath of policy.paths) {
    for (let index = 0; index < dependencyPath.length - 1; index += 1) {
      const parent = packageAt(packages, dependencyPath[index]);
      const child = dependencyPath[index + 1];
      const declared = { ...parent.dependencies, ...parent.optionalDependencies };
      if (!(child in declared)) {
        throw new Error(`locked path is missing ${dependencyPath.slice(0, index + 2).join(' > ')}`);
      }
    }
  }
}

function packageAt(packages, name) {
  const entry = packages[`node_modules/${name}`];
  if (!entry) throw new Error(`lock is missing node_modules/${name}`);
  return entry;
}
