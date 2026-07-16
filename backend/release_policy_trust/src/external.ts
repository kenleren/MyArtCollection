import { fail } from "./errors.js";
import { canonicalHash, sha256 } from "./canonical.js";

const KEYS = ["consumer", "id", "integrity", "kind", "locator", "producer", "retention", "secret_policy", "trust"];
const INTEGRITY_KEYS = ["algorithm", "digest", "source"];
const ALGORITHMS = new Set(["git-commit-sha1", "sha256", "lock-sha256", "sri"]);
const KINDS = new Set(["action", "toolchain", "lock-resolution", "cache", "temporary", "build-output", "live-response", "evidence"]);

export interface ExternalInput {
  consumer: string;
  id: string;
  integrity: { algorithm: string; digest: string; source: "policy" | "lock" | "runtime-observation" };
  kind: string;
  locator: string;
  producer: string;
  retention: "ephemeral" | "review-artifact";
  secret_policy: "forbidden";
  trust: "trusted" | "evidence-only";
}

export function runtimeObservationContractDigest(row: Pick<ExternalInput, "consumer" | "id" | "kind" | "locator" | "producer">): string {
  return canonicalHash({ consumer: row.consumer, id: row.id, kind: row.kind, locator: row.locator, producer: row.producer });
}

function validIntegrityDigest(algorithm: string, digest: string): boolean {
  if (algorithm === "git-commit-sha1") return /^[0-9a-f]{40}$/.test(digest);
  if (algorithm === "sha256" || algorithm === "lock-sha256") return /^[0-9a-f]{64}$/.test(digest);
  if (algorithm === "sri") return /^sha256-[A-Za-z0-9+/]{43}=$/.test(digest);
  return false;
}

function exactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(value).sort().join("\0") === [...keys].sort().join("\0");
}

export function validateExternalInputs(rows: readonly unknown[]): ExternalInput[] {
  const ids = new Set<string>();
  return rows.map((unknownRow) => {
    if (unknownRow === null || Array.isArray(unknownRow) || typeof unknownRow !== "object" || !exactKeys(unknownRow as Record<string, unknown>, KEYS)) fail("invalid_input", "external row keys mismatch");
    const row = unknownRow as unknown as ExternalInput;
    if (typeof row.integrity !== "object" || row.integrity === null || !exactKeys(row.integrity as unknown as Record<string, unknown>, INTEGRITY_KEYS)) fail("invalid_input", "integrity keys mismatch");
    for (const field of [row.consumer, row.id, row.locator, row.producer, row.integrity.digest]) if (typeof field !== "string" || field.length === 0) fail("invalid_input", "external row contains empty string");
    if (ids.has(row.id)) fail("invalid_input", "duplicate external input id");
    ids.add(row.id);
    if (!ALGORITHMS.has(row.integrity.algorithm) || !KINDS.has(row.kind) || !["ephemeral", "review-artifact"].includes(row.retention) || row.secret_policy !== "forbidden" || !["trusted", "evidence-only"].includes(row.trust)) fail("invalid_input", "external row enum mismatch");
    if (!validIntegrityDigest(row.integrity.algorithm, row.integrity.digest)) fail("invalid_input", "external integrity digest does not match its algorithm");
    if (row.trust === "trusted" && !["policy", "lock"].includes(row.integrity.source)) fail("invalid_input", "trusted input needs policy or lock integrity");
    if (row.trust === "evidence-only" && row.integrity.source !== "runtime-observation") fail("invalid_input", "evidence-only input needs runtime observation");
    if (row.trust === "evidence-only" && row.kind === "action") fail("invalid_input", "evidence cannot promote an action to trust");
    if (row.trust === "evidence-only" && row.integrity.algorithm !== "sha256") fail("invalid_input", "runtime evidence contracts use SHA-256");
    if (row.trust === "evidence-only" && row.integrity.digest !== runtimeObservationContractDigest(row)) fail("invalid_input", "runtime evidence contract digest is not canonical");
    if (row.locator.startsWith("/") || /(?:secret|token|credential|keystore|\.env)/i.test(row.locator)) fail("invalid_input", "external locator crosses secret or absolute-path boundary");
    return row;
  });
}

export function verifyAptClosure(simulated: readonly string[], downloaded: readonly { coordinate: string; sha256: string }[], installedBeforeVerification: boolean): void {
  if (installedBeforeVerification) fail("invalid_input", "apt install occurred before evidence verification");
  const expected = [...simulated].sort();
  const actual = downloaded.map((row) => row.coordinate).sort();
  if (new Set(expected).size !== expected.length || new Set(actual).size !== actual.length || expected.join("\0") !== actual.join("\0")) fail("invalid_input", "downloaded apt closure differs from simulation");
  if (downloaded.some((row) => !/^[0-9a-f]{64}$/.test(row.sha256))) fail("invalid_input", "apt archive hash missing or malformed");
}

export function verifyAcquiredDigest(expectedSha256: string, bytes: Uint8Array): void {
  if (!/^[0-9a-f]{64}$/.test(expectedSha256) || sha256(bytes) !== expectedSha256) fail("invalid_input", "acquired input digest mismatch");
}
