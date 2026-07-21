import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { relative, resolve, sep } from "node:path";
import { artifactDrift, canonicalManifest, sha256 } from "../src/artifact.js";
const root = resolve(process.cwd());
const target = resolve(root, "evidence/artifact-manifest.v1.json");
const gitRoot = execFileSync("git", ["-C", root, "rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
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
    "evidence/bundle/bundle-evidence.v1.json", "evidence/bundle/import-manifest.v1.json",
    "evidence/bundle/metafile.json", "evidence/bundle/worker.mjs",
    "evidence/restore-fixture.v1.json", "evidence/restore-rehearsal.v1.json",
    "evidence/sbom.spdx.json", "evidence/sqlite-conformance.v1.json"
];
const currentSha = execFileSync("git", ["-C", root, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
if (!/^[0-9a-f]{40}$/.test(currentSha))
    throw new Error("immutable git SHA unavailable");
const fileHashes = Object.fromEntries(files.map((f) => [f, sha256(readFileSync(resolve(root, f)))]));
const gitPaths = Object.fromEntries(files.map((path) => {
    const absolute = resolve(root, path);
    const gitPath = relative(gitRoot, absolute);
    if (!gitPath || gitPath === ".." || gitPath.startsWith(`..${sep}`))
        throw new Error(`artifact path outside repository: ${path}`);
    execFileSync("git", ["-C", gitRoot, "ls-files", "--error-unmatch", "--", gitPath], { stdio: "ignore" });
    return [path, gitPath];
}));
const gitPathFor = (path) => { const value = gitPaths[path]; if (!value)
    throw new Error(`artifact git path unavailable: ${path}`); return value; };
const hashesAt = (sha) => Object.fromEntries(files.map((path) => [path, sha256(execFileSync("git", ["-C", gitRoot, "show", `${sha}:${gitPathFor(path)}`]))]));
if (process.argv[2] === "generate") {
    const dirty = files.filter((path) => {
        try {
            execFileSync("git", ["-C", gitRoot, "diff", "--quiet", currentSha, "--", gitPathFor(path)], { stdio: "ignore" });
            return false;
        }
        catch {
            return true;
        }
    });
    if (dirty.length > 0)
        throw new Error(`artifact files must be committed before anchoring: ${dirty.join(",")}`);
    const anchorDrift = artifactDrift(fileHashes, fileHashes, hashesAt(currentSha));
    if (anchorDrift.length > 0)
        throw new Error(`artifact anchor tree drift: ${anchorDrift.join(",")}`);
    writeFileSync(target, canonicalManifest(fileHashes, currentSha));
}
else {
    const recorded = JSON.parse(readFileSync(target, "utf8"));
    if (!recorded.git_sha || !/^[0-9a-f]{40}$/.test(recorded.git_sha))
        throw new Error("artifact manifest git anchor drift");
    const expected = Object.fromEntries(Object.entries(fileHashes).sort(([a], [b]) => a.localeCompare(b)));
    const anchored = hashesAt(recorded.git_sha);
    const drift = artifactDrift(recorded.files ?? {}, expected, anchored);
    if (drift.length > 0)
        throw new Error(`artifact manifest drift: ${drift.join(",")}`);
    execFileSync("git", ["-C", root, "merge-base", "--is-ancestor", recorded.git_sha, currentSha]);
}
