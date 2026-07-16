import { sha256 } from "./canonical.js";
import { fail } from "./errors.js";
import { fullUnicodeCaseFold, validateRepositoryPath, type PathPolicy } from "./paths.js";
import { parseStrictJson } from "./strict_json.js";

const ROOT_KEYS = ["base_commit", "check_name", "limits", "repository", "schema_version", "selectors"] as const;
const REPOSITORY_KEYS = ["base_ref", "name"] as const;
const SELECTOR_KEYS = ["baseline_exact", "baseline_prefixes", "final_exact_additions", "final_prefix_additions"] as const;
const LIMIT_KEYS = [
  "action_bytes", "check_pages", "check_rows", "delivery_id_bytes", "event_bytes", "file_pages", "file_rows",
  "header_count", "header_name_bytes", "header_value_bytes", "json_depth", "json_nodes", "open_pr_pages",
  "open_pr_passes", "open_pr_rows", "page_size", "reconcile_delays_seconds", "webhook_body_bytes",
] as const;
const POLICY_BRAND = Symbol("canonical-release-policy");

type JsonRecord = Record<string, unknown>;

function record(value: unknown, label: string): JsonRecord {
  if (value === null || Array.isArray(value) || typeof value !== "object") fail("invalid_input", `${label} must be an object`);
  return value as JsonRecord;
}

function exactKeys(value: JsonRecord, expected: readonly string[], label: string): void {
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) fail("invalid_input", `${label} keys mismatch`);
}

function positiveInteger(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) fail("invalid_input", `${label} must be a positive safe integer`);
  return value;
}

function strings(value: unknown, label: string, prefix: boolean): string[] {
  if (!Array.isArray(value)) fail("invalid_input", `${label} must be an array`);
  const output = value.map((item) => {
    if (typeof item !== "string") return fail("invalid_input", `${label} must contain strings`);
    const path = prefix ? validateRepositoryPath(`${item}sentinel`).slice(0, -8) : validateRepositoryPath(item);
    if (prefix && !path.endsWith("/")) fail("invalid_input", `${label} prefixes must end with slash`);
    return path;
  });
  const exact = new Set(output);
  const folded = new Set(output.map(fullUnicodeCaseFold));
  if (exact.size !== output.length || folded.size !== output.length) fail("invalid_input", `${label} contains duplicate or case-fold-colliding entries`);
  return Object.freeze([...output]) as string[];
}

export interface PolicyLimits {
  actionBytes: number;
  checkPages: number;
  checkRows: number;
  deliveryIdBytes: number;
  eventBytes: number;
  filePages: number;
  fileRows: number;
  headerCount: number;
  headerNameBytes: number;
  headerValueBytes: number;
  jsonDepth: number;
  jsonNodes: number;
  openPrPages: number;
  openPrPasses: number;
  openPrRows: number;
  pageSize: number;
  reconcileDelaysSeconds: readonly number[];
  webhookBodyBytes: number;
}

export class CanonicalReleasePolicy {
  readonly [POLICY_BRAND] = true;
  readonly baseCommit: string;
  readonly checkName: string;
  readonly digest: string;
  readonly limits: Readonly<PolicyLimits>;
  readonly pathPolicy: Readonly<PathPolicy>;
  readonly repository: Readonly<{ baseRef: "main"; name: "kenleren/MyArtCollection" }>;

  constructor(input: {
    baseCommit: string;
    checkName: string;
    digest: string;
    limits: PolicyLimits;
    pathPolicy: PathPolicy;
  }) {
    this.baseCommit = input.baseCommit;
    this.checkName = input.checkName;
    this.digest = input.digest;
    this.limits = Object.freeze({ ...input.limits, reconcileDelaysSeconds: Object.freeze([...input.limits.reconcileDelaysSeconds]) });
    this.pathPolicy = Object.freeze({ exact: Object.freeze([...input.pathPolicy.exact]), prefixes: Object.freeze([...input.pathPolicy.prefixes]) });
    this.repository = Object.freeze({ baseRef: "main", name: "kenleren/MyArtCollection" });
    Object.freeze(this);
  }
}

export function assertCanonicalPolicy(value: unknown): asserts value is CanonicalReleasePolicy {
  if (!(value instanceof CanonicalReleasePolicy) || value[POLICY_BRAND] !== true) fail("invalid_input", "policy must come from canonical policy bytes");
}

export function loadCanonicalPolicy(bytes: Uint8Array): CanonicalReleasePolicy {
  const parsed = record(parseStrictJson(bytes, { maxDepth: 16, maxNodes: 10_000 }), "policy");
  exactKeys(parsed, ROOT_KEYS, "policy");
  if (parsed.schema_version !== 1) fail("invalid_input", "unsupported policy schema");
  if (typeof parsed.base_commit !== "string" || !/^[0-9a-f]{40}$/.test(parsed.base_commit)) fail("invalid_input", "policy base commit is malformed");
  if (typeof parsed.check_name !== "string" || parsed.check_name.length === 0 || Buffer.byteLength(parsed.check_name) > 128) fail("invalid_input", "policy check name is malformed");

  const repository = record(parsed.repository, "policy repository");
  exactKeys(repository, REPOSITORY_KEYS, "policy repository");
  if (repository.base_ref !== "main" || repository.name !== "kenleren/MyArtCollection") fail("identity", "policy repository identity mismatch");

  const limits = record(parsed.limits, "policy limits");
  exactKeys(limits, LIMIT_KEYS, "policy limits");
  if (!Array.isArray(limits.reconcile_delays_seconds) || limits.reconcile_delays_seconds.length === 0) fail("invalid_input", "policy reconcile delays are malformed");
  const delays = limits.reconcile_delays_seconds.map((value, index) => positiveInteger(value, `reconcile delay ${index}`));
  if (delays.some((value, index) => index > 0 && value <= delays[index - 1]!)) fail("invalid_input", "policy reconcile delays must strictly increase");
  const runtimeLimits: PolicyLimits = {
    actionBytes: positiveInteger(limits.action_bytes, "action bytes"),
    checkPages: positiveInteger(limits.check_pages, "check pages"),
    checkRows: positiveInteger(limits.check_rows, "check rows"),
    deliveryIdBytes: positiveInteger(limits.delivery_id_bytes, "delivery id bytes"),
    eventBytes: positiveInteger(limits.event_bytes, "event bytes"),
    filePages: positiveInteger(limits.file_pages, "file pages"),
    fileRows: positiveInteger(limits.file_rows, "file rows"),
    headerCount: positiveInteger(limits.header_count, "header count"),
    headerNameBytes: positiveInteger(limits.header_name_bytes, "header name bytes"),
    headerValueBytes: positiveInteger(limits.header_value_bytes, "header value bytes"),
    jsonDepth: positiveInteger(limits.json_depth, "JSON depth"),
    jsonNodes: positiveInteger(limits.json_nodes, "JSON nodes"),
    openPrPages: positiveInteger(limits.open_pr_pages, "open PR pages"),
    openPrPasses: positiveInteger(limits.open_pr_passes, "open PR passes"),
    openPrRows: positiveInteger(limits.open_pr_rows, "open PR rows"),
    pageSize: positiveInteger(limits.page_size, "page size"),
    reconcileDelaysSeconds: delays,
    webhookBodyBytes: positiveInteger(limits.webhook_body_bytes, "webhook body bytes"),
  };
  if (runtimeLimits.pageSize !== 100 || runtimeLimits.fileRows !== runtimeLimits.filePages * runtimeLimits.pageSize || runtimeLimits.checkRows !== runtimeLimits.checkPages * runtimeLimits.pageSize || runtimeLimits.openPrRows !== runtimeLimits.openPrPages * runtimeLimits.pageSize || runtimeLimits.openPrPasses !== 2) fail("invalid_input", "policy pagination limits are internally inconsistent");

  const selectors = record(parsed.selectors, "policy selectors");
  exactKeys(selectors, SELECTOR_KEYS, "policy selectors");
  const exact = [...strings(selectors.baseline_exact, "baseline exact", false), ...strings(selectors.final_exact_additions, "final exact", false)];
  const prefixes = [...strings(selectors.baseline_prefixes, "baseline prefixes", true), ...strings(selectors.final_prefix_additions, "final prefixes", true)];
  if (new Set(exact).size !== exact.length || new Set(prefixes).size !== prefixes.length) fail("invalid_input", "policy selector groups overlap");

  return new CanonicalReleasePolicy({
    baseCommit: parsed.base_commit,
    checkName: parsed.check_name,
    digest: sha256(bytes),
    limits: runtimeLimits,
    pathPolicy: { exact, prefixes },
  });
}
