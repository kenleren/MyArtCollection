import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { canonicalManifest, sha256 } from "../src/artifact.js";
const root = resolve(process.cwd());
const target = resolve(root, "evidence/artifact-manifest.v1.json");
const files = ["package.json", "package-lock.json", "wrangler.jsonc", "src/worker.ts", "src/repository_durable_object.ts", "src/dispatcher.ts", "src/sqlite_store.ts", "src/github_app_port.ts", "src/github_routes.ts", "src/telemetry.ts", "src/generated/canonical_policy_bytes.ts", "vendor/release-policy-trust-0.1.0.tgz", "../release_policy_trust/package-lock.json", "../release_policy_trust/policy/release-policy.v1.json", "../../.work/release-policy-workers-free/bundle/worker.mjs", "evidence/sbom.spdx.json"];
const gitSha = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (!/^[0-9a-f]{40}$/.test(gitSha))
    throw new Error("immutable git SHA unavailable");
const manifest = canonicalManifest(Object.fromEntries(files.map((f) => [f, sha256(readFileSync(resolve(root, f)))])), gitSha);
if (process.argv[2] === "generate")
    writeFileSync(target, manifest);
else if (readFileSync(target, "utf8") !== manifest)
    throw new Error("artifact manifest drift");
