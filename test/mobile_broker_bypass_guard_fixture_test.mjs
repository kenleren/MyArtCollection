import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import test from 'node:test';

const execFileAsync = promisify(execFile);
const guardScript = path.join(process.cwd(), 'scripts/mobile_broker_bypass_guard.mjs');

const forbiddenCases = [
  {
    name: 'root pubspec dependency',
    file: 'pubspec.yaml',
    content: 'dependencies:\n  openai_dart: ^1.0.0\n',
    rule: 'provider SDK import or package',
  },
  {
    name: 'root pubspec lock dependency',
    file: 'pubspec.lock',
    content: 'packages:\n  firebase_ai:\n    dependency: transitive\n',
    rule: 'provider SDK import or package',
  },
  {
    name: 'Android Gradle dependency',
    file: 'android/app/build.gradle.kts',
    content: 'dependencies { implementation("com.openai:openai-java:1.0.0") }\n',
    rule: 'provider SDK import or package',
  },
  {
    name: 'Android Gradle settings host',
    file: 'android/settings.gradle',
    content: 'maven { url = uri("https://api.openai.com/v1") }\n',
    rule: 'direct OpenAI/provider host',
  },
  {
    name: 'Android Gradle properties env name',
    file: 'android/gradle.properties',
    content: 'OPENAI_API_KEY=do-not-use\n',
    rule: 'provider key or env name',
  },
  {
    name: 'Android version catalog package',
    file: 'android/gradle/libs.versions.toml',
    content: 'firebase-ai = "1.0.0"\n',
    rule: 'provider SDK import or package',
  },
  {
    name: 'iOS xcconfig env name',
    file: 'ios/Flutter/Debug.xcconfig',
    content: 'GEMINI_API_KEY=$(GEMINI_API_KEY)\n',
    rule: 'provider key or env name',
  },
  {
    name: 'iOS Xcode project provider host',
    file: 'ios/Runner.xcodeproj/project.pbxproj',
    content: 'API_BASE_URL = https://api.anthropic.com/v1;\n',
    rule: 'direct OpenAI/provider host',
  },
  {
    name: 'Swift package provider SDK',
    file: 'ios/Package.swift',
    content: '.package(url: "https://github.com/openai/openai-swift", from: "1.0.0")\n',
    rule: 'provider SDK import or package',
  },
  {
    name: 'root Swift package provider SDK',
    file: 'Package.swift',
    content: '.package(url: "https://github.com/openai/openai-swift", from: "1.0.0")\n',
    rule: 'provider SDK import or package',
  },
  {
    name: 'CocoaPods provider SDK',
    file: 'ios/Podfile',
    content: "pod 'OpenAI'\n",
    rule: 'provider SDK import or package',
  },
  {
    name: 'root CocoaPods provider SDK',
    file: 'Podfile',
    content: "pod 'OpenAI'\n",
    rule: 'provider SDK import or package',
  },
  {
    name: 'Dart provider dart-define lookup',
    file: 'lib/main.dart',
    content: "const key = String.fromEnvironment('OPENAI_API_KEY');\n",
    rule: 'provider key or env name',
  },
  {
    name: 'Dart provider dart-define lookup in key-named source',
    file: 'lib/openai_key.dart',
    content: "const key = String.fromEnvironment('OPENAI_API_KEY');\n",
    rule: 'provider key or env name',
  },
  {
    name: 'Dart provider package import in token-named source',
    file: 'lib/provider_tokens.dart',
    content: "import 'package:openai/openai.dart';\n",
    rule: 'provider SDK import or package',
  },
  {
    name: 'Dart provider host in google-named source directory',
    file: 'lib/google/provider.dart',
    content: "const endpoint = 'https://api.openai.com/v1/responses';\n",
    rule: 'direct OpenAI/provider host',
  },
];

test('fixture repo with broker-only mobile config passes', async () => {
  await withFixtureRepo(async (repoRoot) => {
    await writeFixture(repoRoot, 'pubspec.yaml', 'name: fixture\n');
    await writeFixture(repoRoot, 'pubspec.lock', 'packages: {}\n');
    await writeFixture(repoRoot, 'lib/main.dart', "const brokerHost = 'archivale-broker';\n");
    await writeFixture(repoRoot, 'android/gradle.properties', 'android.useAndroidX=true\n');
    await writeFixture(repoRoot, 'ios/Flutter/Debug.xcconfig', '#include "Generated.xcconfig"\n');
    await writeFixture(repoRoot, 'android/key.properties', 'OPENAI_API_KEY=not-scanned\n');
    await writeFixture(repoRoot, 'ios/Runner/GoogleService-Info.plist', 'OPENAI_API_KEY=not-scanned\n');

    const result = await runGuard(repoRoot);

    assert.equal(result.code, 0, result.stderr);
    assert.match(result.stdout, /Mobile broker bypass guard passed/);
  });
});

for (const fixture of forbiddenCases) {
  test(`fixture repo rejects ${fixture.name}`, async () => {
    await withFixtureRepo(async (repoRoot) => {
      await writeFixture(repoRoot, fixture.file, fixture.content);

      const result = await runGuard(repoRoot);

      assert.notEqual(result.code, 0, result.stdout);
      assert.match(result.stderr, /Mobile broker bypass guard failed/);
      assert.match(result.stderr, new RegExp(`${escapeRegExp(fixture.file)}:\\d+: ${escapeRegExp(fixture.rule)}`));
    });
  });
}

async function runGuard(repoRoot) {
  try {
    const { stdout, stderr } = await execFileAsync('node', [
      guardScript,
      '--repo-root',
      repoRoot,
    ], {
      cwd: process.cwd(),
    });
    return { code: 0, stdout, stderr };
  } catch (error) {
    return {
      code: error.code ?? 1,
      stdout: error.stdout ?? '',
      stderr: error.stderr ?? '',
    };
  }
}

async function withFixtureRepo(callback) {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'mobile-broker-guard-'));
  try {
    await callback(repoRoot);
  } finally {
    await rm(repoRoot, { recursive: true, force: true });
  }
}

async function writeFixture(repoRoot, relativePath, content) {
  const targetPath = path.join(repoRoot, relativePath);
  await mkdir(path.dirname(targetPath), { recursive: true });
  await writeFile(targetPath, content, 'utf8');
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
