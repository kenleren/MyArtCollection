import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { validateExternalInputs, type ExternalInput } from "../src/external.js";
import { externalPath, hashFile, packageRoot, repoRoot } from "./shared.js";

const manifestBytes = readFileSync(externalPath);
if (manifestBytes.at(-1) !== 0x0a || manifestBytes.includes(0x0d) || manifestBytes.subarray(0, 3).equals(Buffer.from([0xef, 0xbb, 0xbf]))) throw new Error("external manifest must be BOM-free LF-terminated JSONL");
const rows = manifestBytes.toString("utf8").trimEnd().split("\n").map((line) => JSON.parse(line) as unknown);
const validated = validateExternalInputs(rows);
const byId = new Map(validated.map((row) => [row.id, row]));

function requireRow(id: string): ExternalInput {
  const row = byId.get(id);
  if (row === undefined) throw new Error(`undeclared required external input/output: ${id}`);
  return row;
}

const required = [
  "action-checkout", "action-cache", "action-setup-node", "action-setup-java", "action-setup-python", "tool-actionlint", "tool-flutter", "tool-gitleaks",
  "tool-gradle-wrapper-jar", "tool-gradle-distribution", "lock-pub", "lock-broker", "lock-forms", "lock-play-billing", "lock-release-policy-trust",
  "runner-image", "apt-metadata", "apt-resolver", "apt-deb-closure", "npm-audit-responses", "gradle-live-resolution", "android-sdk-runtime",
  "git-history-responses", "github-ci-responses", "cache-pub", "cache-npm", "temporary-build-outputs", "canonical-sbom", "canonical-pack",
];
for (const id of required) requireRow(id);

const lockPaths: Record<string, string> = {
  "lock-pub": "pubspec.lock",
  "lock-broker": "backend/broker/package-lock.json",
  "lock-forms": "backend/forms/package-lock.json",
  "lock-play-billing": "backend/play_billing/package-lock.json",
  "lock-release-policy-trust": "backend/release_policy_trust/package-lock.json",
};
for (const [id, path] of Object.entries(lockPaths)) if (requireRow(id).integrity.digest !== hashFile(resolve(repoRoot, path))) throw new Error(`${id} lock integrity drifted`);
if (requireRow("tool-gradle-wrapper-jar").integrity.digest !== hashFile(resolve(repoRoot, "android/gradle/wrapper/gradle-wrapper.jar"))) throw new Error("Gradle wrapper JAR digest drifted");

const workflow = readFileSync(resolve(repoRoot, ".github/workflows/release-readiness.yml"), "utf8");
const actionIds: Record<string, string> = {
  "actions/checkout": "action-checkout",
  "actions/cache": "action-cache",
  "actions/setup-node": "action-setup-node",
  "actions/setup-java": "action-setup-java",
  "actions/setup-python": "action-setup-python",
};
const observedActions = new Set<string>();
for (const match of workflow.matchAll(/^\s*uses:\s+([^@\s]+)@([^\s]+)\s*$/gm)) {
  const locator = match[1]!; const digest = match[2]!; const id = actionIds[locator];
  if (id === undefined) throw new Error(`workflow uses undeclared Action: ${locator}`);
  const row = requireRow(id);
  if (row.integrity.algorithm !== "git-commit-sha1" || row.integrity.digest !== digest || row.locator !== `github:${locator}`) throw new Error(`${id} does not match workflow Action pin`);
  observedActions.add(id);
}
for (const row of validated.filter((candidate) => candidate.kind === "action")) if (!observedActions.has(row.id)) throw new Error(`manifest Action is not consumed by workflow: ${row.id}`);

const literalPins: Record<string, string[]> = {
  "tool-actionlint": ["rhysd/actionlint@sha256:", "b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667"],
  "tool-flutter": ["FLUTTER_VERSION: 3.44.4", "c853cda0312a162854c481fe6a1bc286d84fbb74bfab7037c39750061dc9b466"],
  "tool-gitleaks": ["GITLEAKS_VERSION: 8.30.1", "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"],
};
for (const [id, literals] of Object.entries(literalPins)) {
  const row = requireRow(id);
  if (row.integrity.algorithm !== "sha256" || !literals.every((literal) => workflow.includes(literal)) || !workflow.includes(row.integrity.digest)) throw new Error(`${id} pin is not mechanically tied to workflow consumption`);
}

const gradleProperties = readFileSync(resolve(repoRoot, "android/gradle/wrapper/gradle-wrapper.properties"), "utf8");
if (!gradleProperties.includes(`distributionSha256Sum=${requireRow("tool-gradle-distribution").integrity.digest}`)) throw new Error("Gradle distribution digest is not tied to wrapper properties");
if (!workflow.includes("runtime-evidence.sha256") || !workflow.includes("broker-audit-runtime-evidence.sha256")) throw new Error("runtime apt/audit evidence is not hashed before consumption");

const reproduceSource = readFileSync(resolve(packageRoot, "scripts/reproduce.ts"), "utf8");
const consumptionCorpus = `${workflow}\n${reproduceSource}`;
const consumptionContracts: Array<[string, RegExp]> = [
  ["runner-image", /runs-on:\s+ubuntu-24\.04/],
  ["apt-metadata", /apt-get update/],
  ["apt-resolver", /apt-get --simulate install/],
  ["apt-deb-closure", /--download-only[\s\S]*--no-download/],
  ["npm-audit-responses", /npm .*audit/],
  ["lock-pub", /flutter pub get --enforce-lockfile/],
  ["lock-broker", /npm --prefix backend\/broker ci/],
  ["lock-forms", /npm --prefix backend\/forms ci/],
  ["lock-play-billing", /npm --prefix backend\/play_billing ci/],
  ["lock-release-policy-trust", /backend\/release_policy_trust ci --ignore-scripts/],
  ["gradle-live-resolution", /GradleWrapperMain/],
  ["android-sdk-runtime", /flutter build apk/],
  ["git-history-responses", /run evidence:verify/],
  ["github-ci-responses", /github\.event\.pull_request\.head\.sha/],
  ["cache-pub", /key: pub-/],
  ["cache-npm", /key: npm-/],
  ["temporary-build-outputs", /flutter build apk|externalNativeBuildRelease/],
  ["canonical-sbom", /canonical-sbom\.cdx\.json/],
  ["canonical-pack", /npm", \["pack"/],
];
for (const [id, pattern] of consumptionContracts) {
  if (!pattern.test(consumptionCorpus)) throw new Error(`declared external consumption disappeared: ${id}`);
  requireRow(id);
}

for (const row of validated) {
  if (row.trust === "trusted" && row.integrity.source === "policy" && row.kind !== "action" && row.id.startsWith("tool-") && !workflow.includes(row.integrity.digest) && row.id !== "tool-gradle-wrapper-jar" && row.id !== "tool-gradle-distribution") throw new Error(`trusted tool digest is not consumed by workflow: ${row.id}`);
}
