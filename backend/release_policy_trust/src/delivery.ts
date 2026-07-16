import { fail } from "./errors.js";
import type { ExpectedIdentity } from "./ports.js";
import type { VerifiedWebhook } from "./webhook.js";

function record(value: unknown, label: string): Record<string, unknown> {
  if (value === null || Array.isArray(value) || typeof value !== "object") fail("identity", `${label} identity missing`);
  return value as Record<string, unknown>;
}
function positive(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value <= 0) fail("identity", `${label} must be a positive safe integer`);
  return value;
}
function oid(value: unknown, label: string): string {
  if (typeof value !== "string" || !/^[0-9a-f]{40}$/.test(value)) fail("identity", `${label} is inaccessible or malformed`);
  return value;
}

export type DeliveryTarget =
  | { after: string; kind: "push" }
  | { kind: "pull_request"; pullRequestNumber: number };

export function validateDeliveryIdentity(webhook: VerifiedWebhook, expected: ExpectedIdentity): DeliveryTarget {
  for (const [label, value] of [["App", expected.appId], ["installation", expected.installationId], ["repository", expected.repositoryId]] as const) positive(value, label);
  if (expected.repositoryName !== "kenleren/MyArtCollection" || expected.baseRef !== "main") fail("identity", "expected repository identity is outside policy");
  const repository = record(webhook.payload.repository, "repository");
  const installation = record(webhook.payload.installation, "installation");
  if (positive(repository.id, "repository id") !== expected.repositoryId || repository.full_name !== expected.repositoryName || positive(installation.id, "installation id") !== expected.installationId) fail("identity", "webhook repository or installation mismatch");
  if (webhook.event === "push") return { after: oid(webhook.payload.after, "push after"), kind: "push" };
  const pull = record(webhook.payload.pull_request, "pull request");
  const base = record(pull.base, "pull request base");
  const baseRepository = record(base.repo, "pull request base repository");
  const head = record(pull.head, "pull request head");
  const headRepository = record(head.repo, "pull request head repository");
  if (base.ref !== "main" || positive(baseRepository.id, "base repository id") !== expected.repositoryId || positive(headRepository.id, "head repository id") !== expected.repositoryId) fail("identity", "wrong base or fork pull request");
  return { kind: "pull_request", pullRequestNumber: positive(webhook.payload.number, "pull request number") };
}
