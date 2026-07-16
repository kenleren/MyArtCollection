import { createHash } from "node:crypto";
import { fail } from "./errors.js";

export type Canonical = null | boolean | number | string | Canonical[] | { [key: string]: Canonical };

function normalize(value: unknown): Canonical {
  if (value === null || typeof value === "boolean" || typeof value === "string") return value;
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) fail("invalid_input", "canonical numbers must be safe integers");
    return value;
  }
  if (Array.isArray(value)) return value.map(normalize);
  if (typeof value === "object") {
    const input = value as Record<string, unknown>;
    const output: Record<string, Canonical> = {};
    for (const key of Object.keys(input).sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))) {
      const child = input[key];
      if (child === undefined) fail("invalid_input", "undefined is not canonical");
      output[key] = normalize(child);
    }
    return output;
  }
  return fail("invalid_input", "unsupported canonical value");
}

export function canonicalJson(value: unknown): string {
  return JSON.stringify(normalize(value));
}

export function sha256(value: Uint8Array | string): string {
  return createHash("sha256").update(value).digest("hex");
}

export function canonicalHash(value: unknown): string {
  return sha256(Buffer.from(canonicalJson(value), "utf8"));
}

export interface GenerationTuple {
  app_id: number;
  base_ref: string;
  base_sha: string;
  head_sha: string;
  installation_id: number;
  policy_sha256: string;
  pull_request_number: number;
  repository_id: number;
}

export function generationId(tuple: GenerationTuple): string {
  return canonicalHash(tuple);
}
