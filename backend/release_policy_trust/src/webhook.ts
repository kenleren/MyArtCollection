import { createHmac, timingSafeEqual } from "node:crypto";
import { sha256 } from "./canonical.js";
import { fail } from "./errors.js";
import { parseStrictJson } from "./strict_json.js";
import { assertCanonicalPolicy, type CanonicalReleasePolicy } from "./policy.js";

export interface HeaderField { name: string; value: string }
export interface WebhookLimits {
  actionBytes: number;
  bodyBytes: number;
  deliveryIdBytes: number;
  eventBytes: number;
  headerCount: number;
  headerNameBytes: number;
  headerValueBytes: number;
  jsonDepth: number;
  jsonNodes: number;
}
export interface VerifiedWebhook {
  action: string;
  deliveryId: string;
  event: "pull_request" | "push";
  payload: Record<string, unknown>;
  payloadSha256: string;
}

const REQUIRED = ["content-type", "x-hub-signature-256", "x-github-event", "x-github-delivery"] as const;
const PULL_ACTIONS = new Set(["opened", "reopened", "synchronize", "edited", "ready_for_review"]);

function ascii(value: string, max: number, label: string): void {
  if (Buffer.byteLength(value, "utf8") > max || !/^[\x20-\x7e]+$/.test(value)) fail("invalid_input", `${label} is malformed`);
}

export function verifyWebhook(
  rawBody: Uint8Array,
  headers: readonly HeaderField[],
  secret: Uint8Array,
  policy: CanonicalReleasePolicy,
): VerifiedWebhook {
  assertCanonicalPolicy(policy);
  const limits: WebhookLimits = {
    actionBytes: policy.limits.actionBytes,
    bodyBytes: policy.limits.webhookBodyBytes,
    deliveryIdBytes: policy.limits.deliveryIdBytes,
    eventBytes: policy.limits.eventBytes,
    headerCount: policy.limits.headerCount,
    headerNameBytes: policy.limits.headerNameBytes,
    headerValueBytes: policy.limits.headerValueBytes,
    jsonDepth: policy.limits.jsonDepth,
    jsonNodes: policy.limits.jsonNodes,
  };
  if (rawBody.byteLength > limits.bodyBytes) fail("overflow", "webhook body too large");
  if (headers.length > limits.headerCount) fail("overflow", "too many webhook headers");
  const values = new Map<string, string[]>();
  for (const header of headers) {
    ascii(header.name, limits.headerNameBytes, "header name");
    ascii(header.value, limits.headerValueBytes, "header value");
    const name = header.name.toLowerCase();
    const list = values.get(name) ?? [];
    list.push(header.value);
    values.set(name, list);
  }
  const singleton = (name: typeof REQUIRED[number]): string => {
    const list = values.get(name);
    if (list?.length !== 1) return fail("invalid_input", `${name} must occur exactly once`);
    return list[0]!;
  };
  const contentType = singleton("content-type").toLowerCase();
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/.test(contentType)) fail("invalid_input", "unsupported content type");
  const signature = singleton("x-hub-signature-256");
  if (!/^sha256=[0-9a-f]{64}$/.test(signature)) fail("invalid_input", "malformed webhook signature");
  const expected = createHmac("sha256", secret).update(rawBody).digest();
  const supplied = Buffer.from(signature.slice(7), "hex");
  if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) fail("invalid_input", "webhook signature mismatch");

  const event = singleton("x-github-event");
  const deliveryId = singleton("x-github-delivery");
  ascii(event, limits.eventBytes, "event");
  ascii(deliveryId, limits.deliveryIdBytes, "delivery id");
  if (event !== "pull_request" && event !== "push") fail("invalid_input", "unsupported webhook event");
  const parsed = parseStrictJson(rawBody, { maxDepth: limits.jsonDepth, maxNodes: limits.jsonNodes });
  if (parsed === null || Array.isArray(parsed) || typeof parsed !== "object") fail("invalid_input", "webhook body must be an object");
  const payload = parsed as Record<string, unknown>;
  let action = "";
  if (event === "pull_request") {
    if (typeof payload.action !== "string") fail("invalid_input", "pull request action missing");
    ascii(payload.action, limits.actionBytes, "action");
    if (!PULL_ACTIONS.has(payload.action)) fail("invalid_input", "unsupported pull request action");
    action = payload.action;
  } else {
    if (payload.ref !== "refs/heads/main") fail("invalid_input", "push is not for main");
  }
  return { action, deliveryId, event, payload, payloadSha256: sha256(rawBody) };
}
