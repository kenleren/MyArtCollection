#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  await main();
}

async function main() {
  try {
    const paths = parseArgs(process.argv.slice(2));
    for (const [name, label] of [['--audit', 'full audit'], ['--core-audit', 'peer-omitted audit']]) {
      const report = JSON.parse(await readFile(paths.get(name), 'utf8'));
      checkCleanAudit(report, label);
    }
    console.log('Broker audit policy passed: both reports contain zero vulnerabilities; no exceptions.');
  } catch (error) {
    console.error(`Broker audit policy failed: ${error.message}`);
    process.exitCode = 1;
  }
}

function parseArgs(args) {
  const usage = 'usage: check_broker_audit.mjs --audit <npm-audit.json> --core-audit <peer-omitted.json>';
  if (args.length !== 4) throw new Error(usage);
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index];
    const value = args[index + 1];
    if (!['--audit', '--core-audit'].includes(name) || !value || values.has(name)) {
      throw new Error(usage);
    }
    values.set(name, value);
  }
  return values;
}

export function checkCleanAudit(report, label = 'audit') {
  requireObject(report, label);
  if (Object.hasOwn(report, 'error')) throw new Error(`${label} reported a top-level npm error`);
  requireFields(report, ['auditReportVersion', 'metadata', 'vulnerabilities'], label);
  if (report.auditReportVersion !== 2) throw new Error(`${label} report version is not exactly 2`);
  requireObject(report.vulnerabilities, `${label} vulnerabilities`);
  if (Object.keys(report.vulnerabilities).length !== 0) {
    throw new Error(`${label} contains vulnerabilities; no exceptions are allowed`);
  }
  requireObject(report.metadata, `${label} metadata`);
  requireFields(report.metadata, ['dependencies', 'vulnerabilities'], `${label} metadata`);
  const counts = report.metadata.vulnerabilities;
  requireObject(counts, `${label} vulnerability counts`);
  requireFields(counts, ['info', 'low', 'moderate', 'high', 'critical', 'total'], `${label} vulnerability counts`);
  if (Object.values(counts).some((value) => value !== 0)) {
    throw new Error(`${label} vulnerability counts must all be zero`);
  }
  const dependencies = report.metadata.dependencies;
  requireObject(dependencies, `${label} dependency counts`);
  requireFields(dependencies, ['prod', 'dev', 'optional', 'peer', 'peerOptional', 'total'], `${label} dependency counts`);
  if (Object.values(dependencies).some((value) => !Number.isSafeInteger(value) || value < 0) || dependencies.total === 0) {
    throw new Error(`${label} dependency counts must be nonnegative integers with a positive total`);
  }
}

function requireObject(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} is not an object`);
  }
}

function requireFields(value, fields, label) {
  const actual = Object.keys(value).sort();
  if (JSON.stringify(actual) !== JSON.stringify([...fields].sort())) {
    throw new Error(`${label} fields changed`);
  }
}
