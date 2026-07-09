#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const advisory = {
  source: 1119441,
  name: 'uuid',
  dependency: 'uuid',
  title: 'uuid: Missing buffer bounds check in v3/v5/v6 when buf is provided',
  url: 'https://github.com/advisories/GHSA-w5hq-g745-h8pq',
  severity: 'moderate',
  cwe: ['CWE-787', 'CWE-1285'],
  cvss: {
    score: 7.5,
    vectorString: 'CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:H/A:N',
  },
  range: '<11.1.1',
};

const firebaseAdminFix = {
  name: 'firebase-admin',
  version: '14.1.0',
  isSemVerMajor: true,
};

const policy = {
  advisoryId: 'GHSA-w5hq-g745-h8pq',
  expiresOn: '2026-08-31',
  uuidVersion: '9.0.1',
  rootDependencies: {
    'firebase-admin': '^13.10.0',
    'firebase-functions': '^7.2.5',
  },
  auditVulnerabilityCounts: {
    info: 0,
    low: 0,
    moderate: 8,
    high: 0,
    critical: 0,
    total: 8,
  },
  auditVulnerabilityCountsWithPeer: {
    info: 0,
    low: 0,
    moderate: 9,
    high: 0,
    critical: 0,
    total: 9,
  },
  auditPackages: new Map([
    ['@google-cloud/firestore', {
      isDirect: false,
      via: ['google-gax'],
      effects: ['firebase-admin'],
      range: '7.5.0-pre.0 || 7.6.0 - 7.11.6',
      nodes: ['node_modules/@google-cloud/firestore'],
      fixAvailable: firebaseAdminFix,
    }],
    ['@google-cloud/storage', {
      isDirect: false,
      via: ['retry-request', 'teeny-request'],
      effects: ['firebase-admin'],
      range: '2.2.0 - 2.5.0 || >=5.19.0',
      nodes: ['node_modules/@google-cloud/storage'],
      fixAvailable: firebaseAdminFix,
    }],
    ['firebase-admin', {
      isDirect: true,
      via: ['@google-cloud/firestore', '@google-cloud/storage'],
      effects: [],
      range: '7.0.0 - 8.2.0 || >=11.0.0',
      nodes: ['node_modules/firebase-admin'],
      fixAvailable: firebaseAdminFix,
    }],
    ['gaxios', {
      isDirect: false,
      via: ['uuid'],
      effects: [],
      range: '6.4.0 - 6.7.1',
      nodes: ['node_modules/gaxios'],
      fixAvailable: true,
    }],
    ['google-gax', {
      isDirect: false,
      via: ['retry-request', 'uuid'],
      effects: ['@google-cloud/firestore'],
      range: '4.0.5-experimental - 4.6.1',
      nodes: ['node_modules/google-gax'],
      fixAvailable: firebaseAdminFix,
    }],
    ['retry-request', {
      isDirect: false,
      via: ['teeny-request'],
      effects: ['@google-cloud/storage', 'google-gax'],
      range: '7.0.0 - 7.0.2',
      nodes: ['node_modules/retry-request'],
      fixAvailable: firebaseAdminFix,
    }],
    ['teeny-request', {
      isDirect: false,
      via: ['uuid'],
      effects: ['@google-cloud/storage', 'retry-request'],
      range: '3.9.1 - 9.0.0',
      nodes: ['node_modules/teeny-request'],
      fixAvailable: firebaseAdminFix,
    }],
    ['uuid', {
      isDirect: false,
      via: [advisory],
      effects: ['gaxios', 'google-gax', 'teeny-request'],
      range: '<11.1.1',
      nodes: ['node_modules/uuid'],
      fixAvailable: firebaseAdminFix,
    }],
  ]),
  lockPackages: new Map([
    ['firebase-functions', {
      version: '7.2.5',
      resolved: 'https://registry.npmjs.org/firebase-functions/-/firebase-functions-7.2.5.tgz',
      integrity: 'sha512-K+pP0AknluAguLRbD96hibyXbnOgwnvd4hkExWdGrxnNCLoj8LBFj08uvJYxyvhsCgYzQumrUaHBW4lsXKSiRg==',
      edges: [
        ['peerDependencies', 'firebase-admin', '^11.10.0 || ^12.0.0 || ^13.0.0'],
      ],
    }],
    ['firebase-admin', {
      version: '13.10.0',
      resolved: 'https://registry.npmjs.org/firebase-admin/-/firebase-admin-13.10.0.tgz',
      integrity: 'sha512-rbuCrJvYRwqBqvbccMS8fj/x2zsaMisdf5RQbRzQzr14Rbq9r2UlpuBHqWAwrO6c9dIRF56xF/xoepXsD5yDuQ==',
      edges: [
        ['optionalDependencies', '@google-cloud/firestore', '^7.11.0'],
        ['optionalDependencies', '@google-cloud/storage', '^7.19.0'],
      ],
    }],
    ['@google-cloud/firestore', {
      version: '7.11.6',
      resolved: 'https://registry.npmjs.org/@google-cloud/firestore/-/firestore-7.11.6.tgz',
      integrity: 'sha512-EW/O8ktzwLfyWBOsNuhRoMi8lrC3clHM5LVFhGvO1HCsLozCOOXRAlHrYBoE6HL42Sc8yYMuCb2XqcnJ4OOEpw==',
      edges: [['dependencies', 'google-gax', '^4.3.3']],
    }],
    ['@google-cloud/storage', {
      version: '7.21.0',
      resolved: 'https://registry.npmjs.org/@google-cloud/storage/-/storage-7.21.0.tgz',
      integrity: 'sha512-l+IFTkd+6Y5LoAuXyYCKNAKtw/Ci+rAMqgdTB1jv4iZiLhw0rtq+0qjIRbBizXkNzEFmXiXUW0H7sZQQvk1ffA==',
      edges: [
        ['dependencies', 'gaxios', '^6.0.2'],
        ['dependencies', 'retry-request', '^7.0.0'],
        ['dependencies', 'teeny-request', '^9.0.0'],
      ],
    }],
    ['gaxios', {
      version: '6.7.1',
      resolved: 'https://registry.npmjs.org/gaxios/-/gaxios-6.7.1.tgz',
      integrity: 'sha512-LDODD4TMYx7XXdpwxAVRAIAuB0bzv0s+ywFonY46k126qzQHT9ygyoa9tncmOiQmmDrik65UYsEkv3lbfqQ3yQ==',
      edges: [['dependencies', 'uuid', '^9.0.1']],
    }],
    ['google-gax', {
      version: '4.6.1',
      resolved: 'https://registry.npmjs.org/google-gax/-/google-gax-4.6.1.tgz',
      integrity: 'sha512-V6eky/xz2mcKfAd1Ioxyd6nmA61gao3n01C+YeuIwu3vzM9EDR6wcVzMSIbLMDXWeoi9SHYctXuKYC5uJUT3eQ==',
      edges: [
        ['dependencies', 'retry-request', '^7.0.0'],
        ['dependencies', 'uuid', '^9.0.1'],
      ],
    }],
    ['retry-request', {
      version: '7.0.2',
      resolved: 'https://registry.npmjs.org/retry-request/-/retry-request-7.0.2.tgz',
      integrity: 'sha512-dUOvLMJ0/JJYEn8NrpOaGNE7X3vpI5XlZS/u0ANjqtcZVKnIxP7IgCFwrKTxENw29emmwug53awKtaMm4i9g5w==',
      edges: [['dependencies', 'teeny-request', '^9.0.0']],
    }],
    ['teeny-request', {
      version: '9.0.0',
      resolved: 'https://registry.npmjs.org/teeny-request/-/teeny-request-9.0.0.tgz',
      integrity: 'sha512-resvxdc6Mgb7YEThw6G6bExlXKkv6+YbuzGg9xuXxSgxJF7Ozs+o8Y9+2R3sArdWdW8nOokoQb1yrpFB0pQK2g==',
      edges: [['dependencies', 'uuid', '^9.0.0']],
    }],
    ['uuid', {
      version: '9.0.1',
      resolved: 'https://registry.npmjs.org/uuid/-/uuid-9.0.1.tgz',
      integrity: 'sha512-b+1eJOlsR9K8HJpow9Ok3fiWOWSIcIzXodvv0rQjVoOVNpWMpxf1wZNpt4y9h10odCNrqnYp1OBzRktckBe3sA==',
      edges: [],
    }],
  ]),
  paths: [
    ['firebase-admin', '@google-cloud/firestore', 'google-gax', 'uuid'],
    ['firebase-admin', '@google-cloud/firestore', 'google-gax', 'retry-request', 'teeny-request', 'uuid'],
    ['firebase-admin', '@google-cloud/storage', 'gaxios', 'uuid'],
    ['firebase-admin', '@google-cloud/storage', 'retry-request', 'teeny-request', 'uuid'],
    ['firebase-admin', '@google-cloud/storage', 'teeny-request', 'uuid'],
  ],
};

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  await main();
}

async function main() {
  try {
    const args = parseArgs(process.argv.slice(2));
    const [audit, coreAudit, lock] = await Promise.all([
      readJson(args.audit, 'audit'),
      readJson(args.coreAudit, 'peer-normalized audit'),
      readJson(args.lock, 'lock'),
    ]);
    checkExpiry();
    checkAudit(audit, { allowPeerMetadata: true, label: 'full audit' });
    checkAudit(coreAudit, { label: 'peer-normalized audit' });
    checkLock(lock);
    console.log(
      `Broker audit policy passed: ${policy.advisoryId} is the only accepted advisory through ${policy.paths.length} exact uuid@${policy.uuidVersion} paths until ${policy.expiresOn}.`,
    );
  } catch (error) {
    console.error(`Broker audit policy failed: ${error.message}`);
    process.exitCode = 1;
  }
}

function parseArgs(args) {
  if (args.length % 2 !== 0) throw new Error(usage());
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index];
    const value = args[index + 1];
    const allowed = name === '--audit' || name === '--core-audit' || name === '--lock';
    if (!allowed || !value || values.has(name)) throw new Error(usage());
    values.set(name, value);
  }
  const audit = values.get('--audit');
  const coreAudit = values.get('--core-audit');
  const lock = values.get('--lock');
  if (!audit || !coreAudit || !lock) throw new Error(usage());
  return { audit, coreAudit, lock };
}

function usage() {
  return 'usage: check_broker_audit.mjs --audit <npm-audit.json> --core-audit <peer-normalized.json> --lock <package-lock.json>';
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
    currentTime = new Date(`${asOf}T00:00:00.000Z`);
    if (Number.isNaN(currentTime.valueOf()) || currentTime.toISOString().slice(0, 10) !== asOf) {
      throw new Error('--as-of is not a valid calendar date');
    }
  }
  const expiresAt = new Date(`${policy.expiresOn}T23:59:59.999Z`);
  if (currentTime > expiresAt) {
    throw new Error(`exception expired on ${policy.expiresOn}`);
  }
}

export function checkExpiryForTest(asOf) {
  checkExpiry(asOf);
}

function checkAudit(audit, { allowPeerMetadata = false, label }) {
  if (!isPlainObject(audit)) throw new Error('audit JSON is not an object');
  if (Object.hasOwn(audit, 'error')) throw new Error(`${label} reported a top-level npm error`);
  compareExact(
    Object.keys(audit),
    ['auditReportVersion', 'metadata', 'vulnerabilities'],
    `${label} top-level fields`,
  );
  if (audit.auditReportVersion !== 2) throw new Error(`${label} report version is not exactly 2`);
  if (!isPlainObject(audit.vulnerabilities)) throw new Error(`${label} has no vulnerabilities object`);

  const vulnerabilities = { ...audit.vulnerabilities };
  const hasPeerMetadata = allowPeerMetadata && Object.hasOwn(vulnerabilities, 'firebase-functions');
  checkAuditMetadata(
    audit.metadata,
    hasPeerMetadata
      ? policy.auditVulnerabilityCountsWithPeer
      : policy.auditVulnerabilityCounts,
    `${label} metadata`,
  );
  if (hasPeerMetadata) {
    checkPeerMetadataVulnerability(vulnerabilities['firebase-functions']);
    delete vulnerabilities['firebase-functions'];
  }
  compareExact(Object.keys(vulnerabilities), [...policy.auditPackages.keys()], `${label} package set`);

  for (const [name, expected] of policy.auditPackages) {
    checkVulnerability(name, vulnerabilities[name], expected, label, hasPeerMetadata);
  }
}

function checkAuditMetadata(metadata, expectedVulnerabilities, label) {
  if (!isPlainObject(metadata)) throw new Error(`${label} is malformed`);
  compareExact(Object.keys(metadata), ['dependencies', 'vulnerabilities'], `${label} fields`);
  compareJsonExact(metadata.vulnerabilities, expectedVulnerabilities, `${label} vulnerability counts`);
  if (!isPlainObject(metadata.dependencies)) throw new Error(`${label} dependency counts are malformed`);
  const expectedFields = ['dev', 'optional', 'peer', 'peerOptional', 'prod', 'total'];
  compareExact(Object.keys(metadata.dependencies), expectedFields, `${label} dependency fields`);
  for (const field of expectedFields) {
    const count = metadata.dependencies[field];
    if (!Number.isSafeInteger(count) || count < 0) {
      throw new Error(`${label} dependency count ${field} is not a nonnegative integer`);
    }
  }
  if (metadata.dependencies.total < policy.lockPackages.size) {
    throw new Error(`${label} dependency total is smaller than the approved policy package set`);
  }
}

function checkVulnerability(name, vulnerability, expected, label, allowDerivedFixMetadata) {
  if (!isPlainObject(vulnerability)) throw new Error(`${name} vulnerability is malformed`);
  compareExact(
    Object.keys(vulnerability),
    ['effects', 'fixAvailable', 'isDirect', 'name', 'nodes', 'range', 'severity', 'via'],
    `${name} ${label} vulnerability fields`,
  );
  if (vulnerability.name !== name) throw new Error(`${name} vulnerability name changed`);
  if (vulnerability.severity !== 'moderate') throw new Error(`${name} severity is not exactly moderate`);
  if (vulnerability.isDirect !== expected.isDirect) throw new Error(`${name} direct-dependency state changed`);
  if (vulnerability.range !== expected.range) throw new Error(`${name} vulnerable range changed`);
  const expectedEffects = allowDerivedFixMetadata && name === 'firebase-admin'
    ? ['firebase-functions']
    : expected.effects;
  compareExactArray(vulnerability.effects, expectedEffects, `${name} ${label} effects`);
  compareExactArray(vulnerability.nodes, expected.nodes, `${name} ${label} nodes`);

  if (name === 'uuid') validateAdvisoryOrigin(vulnerability.via);
  compareJsonExact(vulnerability.via, expected.via, `${name} ${label} edges`);
  if (allowDerivedFixMetadata) {
    checkDerivedFixMetadata(name, vulnerability.fixAvailable);
  } else {
    compareJsonExact(vulnerability.fixAvailable, expected.fixAvailable, `${name} ${label} fix metadata`);
  }
}

function checkDerivedFixMetadata(vulnerabilityName, fixAvailable) {
  if (typeof fixAvailable === 'boolean') return;
  if (!isPlainObject(fixAvailable)) {
    throw new Error(`${vulnerabilityName} full audit fix metadata is malformed`);
  }
  compareExact(
    Object.keys(fixAvailable),
    ['isSemVerMajor', 'name', 'version'],
    `${vulnerabilityName} full audit fix metadata fields`,
  );
  if (
    !['firebase-admin', 'firebase-functions'].includes(fixAvailable.name) ||
    typeof fixAvailable.version !== 'string' ||
    !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(fixAvailable.version) ||
    typeof fixAvailable.isSemVerMajor !== 'boolean'
  ) {
    throw new Error(`${vulnerabilityName} full audit fix metadata changed shape`);
  }
}

function checkPeerMetadataVulnerability(vulnerability) {
  const name = 'firebase-functions';
  if (!isPlainObject(vulnerability)) throw new Error(`${name} peer metadata is malformed`);
  compareExact(
    Object.keys(vulnerability),
    ['effects', 'fixAvailable', 'isDirect', 'name', 'nodes', 'range', 'severity', 'via'],
    `${name} peer metadata fields`,
  );
  if (vulnerability.name !== name) throw new Error(`${name} peer metadata name changed`);
  if (vulnerability.severity !== 'moderate') throw new Error(`${name} peer metadata severity changed`);
  if (vulnerability.isDirect !== true) throw new Error(`${name} peer metadata direct state changed`);
  compareExactArray(vulnerability.via, ['firebase-admin'], `${name} peer metadata edges`);
  compareExactArray(vulnerability.effects, [], `${name} peer metadata effects`);
  compareExactArray(vulnerability.nodes, ['node_modules/firebase-functions'], `${name} peer metadata nodes`);
  if (typeof vulnerability.range !== 'string' || vulnerability.range.length === 0) {
    throw new Error(`${name} peer metadata range is malformed`);
  }
  checkPeerFixMetadata(vulnerability.fixAvailable);
}

function checkPeerFixMetadata(fixAvailable) {
  if (typeof fixAvailable === 'boolean') return;
  if (!isPlainObject(fixAvailable)) throw new Error('firebase-functions peer fix metadata is malformed');
  compareExact(
    Object.keys(fixAvailable),
    ['isSemVerMajor', 'name', 'version'],
    'firebase-functions peer fix metadata fields',
  );
  if (
    fixAvailable.name !== 'firebase-functions' ||
    typeof fixAvailable.version !== 'string' ||
    !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(fixAvailable.version) ||
    typeof fixAvailable.isSemVerMajor !== 'boolean'
  ) {
    throw new Error('firebase-functions peer fix metadata changed shape');
  }
}

function validateAdvisoryOrigin(via) {
  if (!Array.isArray(via) || via.length !== 1 || !isPlainObject(via[0])) {
    throw new Error('uuid advisory edge is malformed');
  }
  let url;
  try {
    url = new URL(via[0].url);
  } catch {
    throw new Error('uuid advisory URL is malformed');
  }
  if (
    url.origin !== 'https://github.com' ||
    url.pathname !== `/advisories/${policy.advisoryId}` ||
    url.search !== '' ||
    url.hash !== ''
  ) {
    throw new Error('uuid advisory URL is not the exact trusted GitHub advisory origin and path');
  }
}

function checkLock(lock) {
  if (!isPlainObject(lock) || lock.lockfileVersion !== 3 || !isPlainObject(lock.packages)) {
    throw new Error('lock JSON is not a package-lock v3 packages object');
  }
  const packages = lock.packages;
  if (!isPlainObject(packages[''])) throw new Error('lock is missing its root package entry');
  compareJsonExact(
    packages[''].dependencies,
    policy.rootDependencies,
    'broker root dependency declarations',
  );
  const firebaseFunctionsInstallations = Object.keys(packages)
    .filter((path) => /(^|\/)node_modules\/firebase-functions$/.test(path));
  compareExact(
    firebaseFunctionsInstallations,
    ['node_modules/firebase-functions'],
    'firebase-functions installation paths',
  );
  const uuidInstallations = Object.keys(packages).filter((path) => /(^|\/)node_modules\/uuid$/.test(path));
  compareExact(uuidInstallations, ['node_modules/uuid'], 'uuid installation paths');

  const graphNames = new Set(policy.lockPackages.keys());
  const resolvedEdges = new Map();
  for (const [name, expected] of policy.lockPackages) {
    const packagePath = `node_modules/${name}`;
    const entry = packages[packagePath];
    if (!isPlainObject(entry)) throw new Error(`lock is missing ${packagePath}`);
    for (const field of ['version', 'resolved', 'integrity']) {
      if (entry[field] !== expected[field]) {
        throw new Error(`${packagePath} ${field} changed from the approved lock state`);
      }
    }

    const actualEdges = [];
    for (const field of ['dependencies', 'optionalDependencies', 'peerDependencies']) {
      const dependencies = entry[field];
      if (dependencies !== undefined && !isPlainObject(dependencies)) {
        throw new Error(`${packagePath} ${field} is malformed`);
      }
      for (const [dependency, range] of Object.entries(dependencies ?? {})) {
        if (graphNames.has(dependency)) actualEdges.push([field, dependency, range]);
      }
    }
    compareJsonExact(sortEdges(actualEdges), sortEdges(expected.edges), `${name} locked vulnerable edges`);

    const children = [];
    for (const [, dependency] of expected.edges) {
      const resolvedPath = resolveDependencyPath(packages, packagePath, dependency);
      const expectedPath = `node_modules/${dependency}`;
      if (resolvedPath !== expectedPath) {
        throw new Error(`${name} > ${dependency} resolved to ${resolvedPath ?? 'no installation'}, not ${expectedPath}`);
      }
      children.push(dependency);
    }
    resolvedEdges.set(name, children);
  }

  const actualPaths = enumeratePolicyPaths(resolvedEdges, 'firebase-admin', 'uuid');
  compareExact(
    actualPaths.map((path) => path.join(' > ')),
    policy.paths.map((path) => path.join(' > ')),
    'approved uuid lock paths',
  );
}

function resolveDependencyPath(packages, packagePath, dependency) {
  const nestedPath = `${packagePath}/node_modules/${dependency}`;
  if (Object.hasOwn(packages, nestedPath)) return nestedPath;
  const rootPath = `node_modules/${dependency}`;
  if (Object.hasOwn(packages, rootPath)) return rootPath;
  return undefined;
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

function sortEdges(edges) {
  return [...edges].sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)));
}

function compareExactArray(actual, expected, label) {
  if (!Array.isArray(actual)) throw new Error(`${label} is not an array`);
  compareExact(actual, expected, label);
}

function compareExact(actual, expected, label) {
  const sortedActual = [...actual].sort();
  const sortedExpected = [...expected].sort();
  if (JSON.stringify(sortedActual) !== JSON.stringify(sortedExpected)) {
    throw new Error(`${label} changed: expected [${sortedExpected.join(', ')}], received [${sortedActual.join(', ')}]`);
  }
}

function compareJsonExact(actual, expected, label) {
  if (JSON.stringify(canonicalize(actual)) !== JSON.stringify(canonicalize(expected))) {
    throw new Error(`${label} changed from the exact approved schema`);
  }
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (!isPlainObject(value)) return value;
  return Object.fromEntries(
    Object.keys(value).sort().map((key) => [key, canonicalize(value[key])]),
  );
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
