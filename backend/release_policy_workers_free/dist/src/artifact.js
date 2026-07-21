import { createHash } from "node:crypto";
export function sha256(value) { return createHash("sha256").update(value).digest("hex"); }
export function canonicalManifest(files, gitSha) { return JSON.stringify({ files: Object.fromEntries(Object.entries(files).sort(([a], [b]) => a.localeCompare(b))), git_sha: gitSha, schema_version: 1 }) + "\n"; }
