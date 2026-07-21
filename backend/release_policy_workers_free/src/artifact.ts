import { createHash } from "node:crypto";
export function sha256(value: Uint8Array | string): string { return createHash("sha256").update(value).digest("hex"); }
export function canonicalManifest(files: Readonly<Record<string, string>>, gitSha: string): string { return JSON.stringify({ files: Object.fromEntries(Object.entries(files).sort(([a], [b]) => a.localeCompare(b))), git_sha: gitSha, schema_version: 1 }) + "\n"; }
