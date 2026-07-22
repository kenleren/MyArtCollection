import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import { sha256 } from "../src/artifact.js";
const action = process.argv[2];
const option = (name) => { const i = process.argv.indexOf(`--${name}`); const value = i < 0 ? undefined : process.argv[i + 1]; if (!value)
    throw new Error(`artifact ${name} required`); return value; };
const root = resolve(process.cwd());
const repo = execFileSync("git", ["-C", root, "rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
const rootPath = (value) => value.startsWith("backend/release_policy_workers_free/") ? resolve(repo, value) : resolve(value);
const anchor = option("anchor");
const sbom = rootPath(option("sbom"));
const output = rootPath(option("output"));
if (!/^[0-9a-f]{40}$/.test(anchor))
    throw new Error("artifact anchor rejected");
const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((entry) => { const file = resolve(dir, entry.name); return entry.isDirectory() ? walk(file) : [file]; });
const inputs = ["package.json", "package-lock.json", "tsconfig.json", "wrangler.jsonc", "config/runtime-config.v1.schema.json", "config/runtime-config.synthetic.v1.json", "config/github-egress.v1.json", "config/sqlite-compatibility.v2.json", "scripts/artifact.ts", "scripts/sbom.ts", "scripts/sqlite_conformance.mjs", "scripts/validate_spdx.ts", "scripts/phase_guard.mjs", "scripts/verify_dist.mjs", "vendor/release-policy-trust-0.1.0.tgz", "evidence/bundle/bundle-evidence.v1.json", "evidence/bundle/import-manifest.v1.json", "evidence/bundle/metafile.json", "evidence/bundle/worker.mjs", "evidence/restore-fixture.v1.json", "evidence/restore-rehearsal.v1.json", "evidence/sqlite-conformance.v1.json", "../../docs/RELEASE_POLICY_WORKERS_ROLLBACK.md", "../../backend/release_policy_trust/policy/release-policy.v1.json", ...walk(resolve(root, "src")).filter((file) => file.endsWith(".ts")).map((file) => relative(root, file)), ...walk(resolve(root, "test")).filter((file) => file.endsWith(".ts")).map((file) => relative(root, file)), ...walk(resolve(root, "dist")).filter((file) => file.endsWith(".js")).map((file) => relative(root, file))].sort();
const gitPath = (file) => relative(repo, resolve(root, file)).replaceAll("\\", "/");
const atAnchor = (file) => execFileSync("git", ["-C", repo, "show", `${anchor}:${gitPath(file)}`]);
const sourceFiles = Object.fromEntries(inputs.map((file) => [file, sha256(atAnchor(file))]));
const manifest = { schema_version: 2, source_git_sha: anchor, source_files: Object.fromEntries(Object.entries(sourceFiles).sort(([a], [b]) => a.localeCompare(b))), derived_files: { "evidence/sbom.spdx.json": sha256(readFileSync(sbom)) } };
if (action === "generate")
    writeFileSync(output, `${JSON.stringify(manifest)}\n`);
else if (action === "verify") {
    const actual = JSON.parse(readFileSync(output, "utf8"));
    if (JSON.stringify(actual) !== JSON.stringify(manifest))
        throw new Error("artifact manifest drift");
}
else
    throw new Error("artifact action rejected");
