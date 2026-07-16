import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const packageRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
export const repoRoot = resolve(packageRoot, "../..");
export const policyPath = resolve(packageRoot, "policy/release-policy.v1.json");
export const externalPath = resolve(packageRoot, "policy/external-inputs.v1.jsonl");

export function git(args: readonly string[], options: { encoding?: "utf8"; input?: string } = {}): string | Buffer {
  return execFileSync("git", args, { cwd: repoRoot, encoding: options.encoding, input: options.input, maxBuffer: 1024 * 1024 * 512 });
}

export function hashBytes(bytes: Uint8Array): string { return createHash("sha256").update(bytes).digest("hex"); }
export function hashFile(path: string): string { return hashBytes(readFileSync(path)); }
export function byteCompare(left: string, right: string): number { return Buffer.compare(Buffer.from(left, "utf8"), Buffer.from(right, "utf8")); }

export interface ReleasePolicy {
  base_commit: string;
  check_name: string;
  limits: Record<string, unknown>;
  repository: { base_ref: string; name: string };
  schema_version: number;
  selectors: {
    baseline_exact: string[];
    baseline_prefixes: string[];
    final_exact_additions: string[];
    final_prefix_additions: string[];
  };
}

export function loadPolicy(): ReleasePolicy {
  return JSON.parse(readFileSync(policyPath, "utf8")) as ReleasePolicy;
}

export function argument(name: string): string {
  const index = process.argv.indexOf(name);
  const value = index < 0 ? undefined : process.argv[index + 1];
  if (value === undefined || value.startsWith("--")) throw new Error(`missing ${name}`);
  return value;
}

export function validateOid(value: string): string {
  if (!/^[0-9a-f]{40}$/.test(value)) throw new Error("expected full lowercase 40-hex commit OID");
  return value;
}
