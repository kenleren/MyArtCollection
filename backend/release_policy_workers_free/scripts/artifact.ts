import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { canonicalManifest, sha256 } from "../src/artifact.js";
const root = resolve(process.cwd()); const target = resolve(root, "evidence/artifact-manifest.v1.json");
const files = [
  "package.json", "package-lock.json", "tsconfig.json", "wrangler.jsonc",
  "src/artifact.ts", "src/config.ts", "src/dispatcher.ts", "src/generated/canonical_policy_bytes.ts",
  "src/github_app_port.ts", "src/github_routes.ts", "src/platform.ts", "src/repository_durable_object.ts",
  "src/sqlite_store.ts", "src/telemetry.ts", "src/worker.ts",
  "scripts/artifact.ts", "scripts/bundle_worker.mjs", "scripts/clean.mjs",
  "scripts/generate_canonical_policy.mjs", "scripts/restore_rehearsal.ts", "scripts/runtime_contract.mjs",
  "scripts/sbom.ts", "scripts/sqlite_conformance.mjs",
  "vendor/release-policy-trust-0.1.0.tgz", "../release_policy_trust/package-lock.json",
  "../release_policy_trust/policy/release-policy.v1.json",
  "../../.work/release-policy-workers-free/bundle/bundle-evidence.v1.json",
  "../../.work/release-policy-workers-free/bundle/import-manifest.v1.json",
  "../../.work/release-policy-workers-free/bundle/metafile.json",
  "../../.work/release-policy-workers-free/bundle/worker.mjs",
  "evidence/restore-fixture.v1.json", "evidence/restore-rehearsal.v1.json",
  "evidence/sbom.spdx.json", "evidence/sqlite-conformance.v1.json"
];
const currentSha = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (!/^[0-9a-f]{40}$/.test(currentSha)) throw new Error("immutable git SHA unavailable");
const fileHashes = Object.fromEntries(files.map((f) => [f, sha256(readFileSync(resolve(root, f)))]));
if (process.argv[2] === "generate") writeFileSync(target, canonicalManifest(fileHashes, currentSha));
else {
  const recorded = JSON.parse(readFileSync(target, "utf8")) as { files?: Record<string, string>; git_sha?: string };
  if (!recorded.git_sha || !/^[0-9a-f]{40}$/.test(recorded.git_sha)) throw new Error("artifact manifest git anchor drift");
  const expected = Object.fromEntries(Object.entries(fileHashes).sort(([a], [b]) => a.localeCompare(b)));
  const drift = [...new Set([...Object.keys(expected), ...Object.keys(recorded.files ?? {})])].filter((path) => recorded.files?.[path] !== expected[path]).sort();
  if (drift.length > 0) throw new Error(`artifact manifest drift: ${drift.join(",")}`);
  execFileSync("git", ["-C", root, "merge-base", "--is-ancestor", recorded.git_sha, currentSha]);
}
