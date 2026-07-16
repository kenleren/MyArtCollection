import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { validateExternalInputs } from "../src/external.js";
import { externalPath, hashFile, repoRoot } from "./shared.js";

const rows = readFileSync(externalPath, "utf8").trimEnd().split("\n").map((line) => JSON.parse(line) as unknown);
const validated = validateExternalInputs(rows);
const required = ["action-checkout", "action-cache", "action-setup-node", "action-setup-java", "action-setup-python", "tool-actionlint", "tool-flutter", "tool-gitleaks", "tool-gradle-wrapper-jar", "tool-gradle-distribution", "lock-pub", "lock-broker", "lock-forms", "lock-play-billing", "lock-release-policy-trust", "runner-image", "apt-metadata", "apt-resolver", "apt-deb-closure", "npm-audit-responses", "gradle-live-resolution", "android-sdk-runtime", "github-ci-responses", "canonical-sbom", "canonical-pack"];
for (const id of required) if (!validated.some((row) => row.id === id)) throw new Error(`undeclared required external input/output: ${id}`);
const lockPaths: Record<string, string> = {
  "lock-pub": "pubspec.lock",
  "lock-broker": "backend/broker/package-lock.json",
  "lock-forms": "backend/forms/package-lock.json",
  "lock-play-billing": "backend/play_billing/package-lock.json",
  "lock-release-policy-trust": "backend/release_policy_trust/package-lock.json",
};
for (const [id, path] of Object.entries(lockPaths)) {
  const row = validated.find((candidate) => candidate.id === id)!;
  if (row.integrity.digest !== hashFile(resolve(repoRoot, path))) throw new Error(`${id} lock integrity drifted`);
}
