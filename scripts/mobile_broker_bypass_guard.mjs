#!/usr/bin/env node
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const mobileRoots = ['lib', 'android', 'ios'];
const allowedBrokerHosts = new Set(['archivale-broker']);
const deniedRules = [
  {
    name: 'direct OpenAI/provider host',
    pattern: /\bapi\.openai\.com\b|\bapi\.anthropic\.com\b|\bgenerativelanguage\.googleapis\.com\b/i,
  },
  {
    name: 'provider key or env name',
    pattern: /\bOPENAI_API_KEY\b|\bANTHROPIC_API_KEY\b|\bGOOGLE_API_KEY\b|\bGEMINI_API_KEY\b|\bOPENAI_ORG_ID\b|\bOPENAI_PROJECT\b/i,
  },
  {
    name: 'provider SDK import or package',
    pattern: /package:openai\b|from ['"]openai['"]|require\(['"]openai['"]\)|openai_dart|dart_openai|firebase_ai|firebase_vertexai|firebase-ai|firebase-ai-logic/i,
  },
  {
    name: 'direct provider network client',
    pattern: /https?:\/\/(?:api\.openai\.com|api\.anthropic\.com|generativelanguage\.googleapis\.com)\b/i,
  },
  {
    name: 'provider dart-define',
    pattern: /--dart-define=(?:OPENAI|ANTHROPIC|GEMINI|GOOGLE_API_KEY)|String\.fromEnvironment\(['"](?:OPENAI|ANTHROPIC|GEMINI|GOOGLE_API_KEY)/i,
  },
];
const ignoredDirectories = new Set(['.dart_tool', '.gradle', 'build', 'Pods', 'DerivedData']);
const scannedExtensions = new Set([
  '.dart',
  '.kt',
  '.kts',
  '.java',
  '.swift',
  '.m',
  '.mm',
  '.plist',
  '.xml',
  '.gradle',
  '.properties',
  '.yaml',
  '.yml',
]);

const violations = [];

for (const mobileRoot of mobileRoots) {
  await scanDirectory(path.join(repoRoot, mobileRoot));
}

if (violations.length > 0) {
  console.error('Mobile broker bypass guard failed. Mobile code may only target the Archivale broker endpoint.');
  for (const violation of violations) {
    console.error(`${violation.relativePath}:${violation.line}: ${violation.rule}`);
  }
  process.exit(1);
}

console.log('Mobile broker bypass guard passed: no direct provider SDK, host, key/env, Firebase AI Logic, or provider network client usage found in lib/, android/, or ios/.');

async function scanDirectory(directory) {
  let entries;
  try {
    entries = await readdir(directory, { withFileTypes: true });
  } catch (error) {
    if (error.code === 'ENOENT') {
      return;
    }
    throw error;
  }

  for (const entry of entries) {
    if (entry.name.startsWith('.') || ignoredDirectories.has(entry.name)) {
      continue;
    }

    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      await scanDirectory(fullPath);
      continue;
    }
    if (!entry.isFile() || !shouldScanFile(fullPath)) {
      continue;
    }

    const content = await readFile(fullPath, 'utf8');
    scanFile(fullPath, content);
  }
}

function shouldScanFile(filePath) {
  if (path.basename(filePath) === 'Podfile') {
    return true;
  }
  return scannedExtensions.has(path.extname(filePath));
}

function scanFile(filePath, content) {
  const relativePath = path.relative(repoRoot, filePath);
  const lines = content.split(/\r?\n/);
  for (const [index, line] of lines.entries()) {
    if (allowedBrokerHosts.has(line.trim())) {
      continue;
    }
    for (const rule of deniedRules) {
      if (rule.pattern.test(line)) {
        violations.push({
          relativePath,
          line: index + 1,
          rule: rule.name,
        });
      }
    }
  }
}
