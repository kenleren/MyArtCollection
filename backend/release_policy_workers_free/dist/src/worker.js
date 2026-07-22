import { loadCanonicalPolicy, validateDeliveryIdentity, verifyWebhook } from "@archivale/release-policy-trust";
import { MAX_WEBHOOK_BYTES, REPOSITORY_ID, parseRuntimeConfig, repositoryObjectName } from "./config.js";
import { CANONICAL_POLICY_BYTES } from "./generated/canonical_policy_bytes.js";
export { RepositoryDurableObject } from "./repository_durable_object.js";
function rawHeaders(request) { return [...request.headers].map(([name, value]) => ({ name, value })); }
async function boundedBody(request) {
    const declared = request.headers.get("content-length");
    if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > MAX_WEBHOOK_BYTES))
        return null;
    if (request.body === null)
        return new Uint8Array();
    const reader = request.body.getReader();
    const chunks = [];
    let size = 0;
    try {
        for (;;) {
            const next = await reader.read();
            if (next.done)
                break;
            size += next.value.byteLength;
            if (size > MAX_WEBHOOK_BYTES) {
                await reader.cancel();
                return null;
            }
            chunks.push(next.value);
        }
    }
    finally {
        reader.releaseLock();
    }
    const raw = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
        raw.set(chunk, offset);
        offset += chunk.byteLength;
    }
    return raw;
}
async function watchdog(env) { const stub = env.REPOSITORY.get(env.REPOSITORY.idFromName(repositoryObjectName(REPOSITORY_ID))); await stub.fetch(new Request("https://do.invalid/watchdog", { method: "POST" })); }
export default { async fetch(request, env) {
        const config = parseRuntimeConfig(env.RELEASE_TRUST_CONFIG_V1);
        if (!env.GITHUB_WEBHOOK_SECRET || !env.GITHUB_APP_PRIVATE_KEY_PEM)
            return new Response("misconfigured", { status: 503 });
        const path = new URL(request.url).pathname;
        // Watchdog quota may be consumed only by the platform scheduled handler.
        if (path === "/scheduled-watchdog")
            return new Response("not found", { status: 404 });
        if (path !== "/webhook" || request.method !== "POST")
            return new Response("not found", { status: 404 });
        const raw = await boundedBody(request);
        if (raw === null)
            return new Response("payload too large", { status: 413 });
        let verified;
        let target;
        try {
            verified = verifyWebhook(raw, rawHeaders(request), new TextEncoder().encode(env.GITHUB_WEBHOOK_SECRET), loadCanonicalPolicy(CANONICAL_POLICY_BYTES));
            target = validateDeliveryIdentity(verified, { appId: config.appId, installationId: config.installationId, repositoryId: config.repositoryId, repositoryName: "kenleren/MyArtCollection", baseRef: "main" });
        }
        catch {
            return new Response("invalid webhook", { status: 401 });
        }
        const stub = env.REPOSITORY.get(env.REPOSITORY.idFromName(repositoryObjectName(REPOSITORY_ID)));
        return stub.fetch(new Request("https://do.invalid/verified-delivery", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ delivery_id: verified.deliveryId, event: verified.event, payload_sha256: verified.payloadSha256, installation_id: config.installationId, target }) }));
    }, async scheduled(_event, env) { parseRuntimeConfig(env.RELEASE_TRUST_CONFIG_V1); if (!env.GITHUB_APP_PRIVATE_KEY_PEM)
        return; await watchdog(env); } };
