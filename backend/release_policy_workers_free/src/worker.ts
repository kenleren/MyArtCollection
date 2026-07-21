import { loadCanonicalPolicy, validateDeliveryIdentity, verifyWebhook } from "@archivale/release-policy-trust";
import { MAX_WEBHOOK_BYTES, REPOSITORY_ID, parseRuntimeConfig, repositoryObjectName } from "./config.js";
import { CANONICAL_POLICY_BYTES } from "./generated/canonical_policy_bytes.js";
import type { DurableNamespace } from "./platform.js";
export { RepositoryDurableObject } from "./repository_durable_object.js";

export interface Env { RELEASE_TRUST_CONFIG_V1: string; REPOSITORY: DurableNamespace; GITHUB_WEBHOOK_SECRET: string; GITHUB_APP_PRIVATE_KEY_PEM: string }
function rawHeaders(request: Request): Array<{ name: string; value: string }> { return [...request.headers].map(([name, value]) => ({ name, value })); }
async function boundedBody(request: Request): Promise<Uint8Array | null> {
  const declared = request.headers.get("content-length");
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > MAX_WEBHOOK_BYTES)) return null;
  if (request.body === null) return new Uint8Array();
  const reader = request.body.getReader(); const chunks: Uint8Array[] = []; let size = 0;
  try { for (;;) { const next = await reader.read(); if (next.done) break; size += next.value.byteLength; if (size > MAX_WEBHOOK_BYTES) { await reader.cancel(); return null; } chunks.push(next.value); } }
  finally { reader.releaseLock(); }
  const raw = new Uint8Array(size); let offset = 0; for (const chunk of chunks) { raw.set(chunk, offset); offset += chunk.byteLength; } return raw;
}
async function watchdog(env: Env): Promise<void> { const stub = env.REPOSITORY.get(env.REPOSITORY.idFromName(repositoryObjectName(REPOSITORY_ID))); await stub.fetch(new Request("https://do.invalid/watchdog", { method: "POST" })); }
export default { async fetch(request: Request, env: Env): Promise<Response> {
  const config = parseRuntimeConfig(env.RELEASE_TRUST_CONFIG_V1);
  if (!env.GITHUB_WEBHOOK_SECRET || !env.GITHUB_APP_PRIVATE_KEY_PEM) return new Response("misconfigured", { status: 503 });
  const path = new URL(request.url).pathname;
  // Watchdog quota may be consumed only by the platform scheduled handler.
  if (path === "/scheduled-watchdog") return new Response("not found", { status: 404 });
  if (path !== "/webhook" || request.method !== "POST") return new Response("not found", { status: 404 });
  const raw = await boundedBody(request); if (raw === null) return new Response("payload too large", { status: 413 });
  let verified: ReturnType<typeof verifyWebhook>;
  let target: ReturnType<typeof validateDeliveryIdentity>;
  try { verified = verifyWebhook(raw, rawHeaders(request), new TextEncoder().encode(env.GITHUB_WEBHOOK_SECRET), loadCanonicalPolicy(CANONICAL_POLICY_BYTES)); target = validateDeliveryIdentity(verified, { appId: config.appId, installationId: config.installationId, repositoryId: config.repositoryId, repositoryName: "kenleren/MyArtCollection", baseRef: "main" }); } catch { return new Response("invalid webhook", { status: 401 }); }
  const stub = env.REPOSITORY.get(env.REPOSITORY.idFromName(repositoryObjectName(REPOSITORY_ID)));
  return stub.fetch(new Request("https://do.invalid/verified-delivery", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ delivery_id: verified.deliveryId, event: verified.event, payload_sha256: verified.payloadSha256, installation_id: config.installationId, target }) }));
}, async scheduled(_event: unknown, env: Env): Promise<void> { parseRuntimeConfig(env.RELEASE_TRUST_CONFIG_V1); if (!env.GITHUB_APP_PRIVATE_KEY_PEM) return; await watchdog(env); } };
