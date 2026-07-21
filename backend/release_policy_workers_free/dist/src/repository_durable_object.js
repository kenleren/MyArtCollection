import { AlarmDispatcher } from "./dispatcher.js";
import { loadCanonicalPolicy, receive } from "@archivale/release-policy-trust";
import { SqliteStore } from "./sqlite_store.js";
import { parseRuntimeConfig } from "./config.js";
import { CANONICAL_POLICY_BYTES } from "./generated/canonical_policy_bytes.js";
import { githubAlarmPort } from "./github_app_port.js";
export class RepositoryDurableObject {
    state;
    store;
    dispatcher;
    constructor(state, env) {
        this.state = state;
        this.store = new SqliteStore(state.storage);
        // A constructor run proves the prior in-memory alarm invocation no longer
        // exists; clear only this scheduler marker, never a core effect lease.
        this.store.writeMeta("alarm_runtime/v1", { running: false, started_at: 0 });
        const config = parseRuntimeConfig(env.RELEASE_TRUST_CONFIG_V1);
        this.dispatcher = new AlarmDispatcher(state.storage, this.store, {
            clock: { delay: async () => { } },
            identity: { appId: config.appId, baseRef: "main", installationId: config.installationId, repositoryId: config.repositoryId, repositoryName: "kenleren/MyArtCollection" },
            policy: loadCanonicalPolicy(CANONICAL_POLICY_BYTES),
            portFactory: () => githubAlarmPort({ appId: config.appId, installationId: config.installationId, repositoryId: config.repositoryId, repositoryName: "kenleren/MyArtCollection", privateKeyPem: env.GITHUB_APP_PRIVATE_KEY_PEM, fetcher: fetch, measure: (measurement) => this.recordEgress(measurement) }),
        });
    }
    async fetch(request) {
        this.store.incrementMeta("do_request_count/v1");
        const path = new URL(request.url).pathname;
        if (request.method !== "POST")
            return new Response("not found", { status: 404 });
        if (path === "/watchdog") {
            await this.watchdog();
            return new Response(null, { status: 202 });
        }
        if (path !== "/verified-delivery")
            return new Response("not found", { status: 404 });
        // This body is constructed only by the public Worker after raw HMAC and
        // identity verification. It intentionally contains no raw webhook data.
        const input = await request.json();
        if (!input || !["pull_request", "push"].includes(input.event) || !Number.isSafeInteger(input.installation_id) || !input.target || input.target.kind !== input.event)
            return new Response("invalid delivery", { status: 400 });
        if ((input.target.kind === "pull_request" && (!Number.isSafeInteger(input.target.pullRequestNumber) || input.target.pullRequestNumber <= 0)) || (input.target.kind === "push" && !/^[0-9a-f]{40}$/.test(input.target.after)))
            return new Response("invalid delivery", { status: 400 });
        const receipt = await receive(this.store, { deliveryId: input.delivery_id, identityDigest: input.payload_sha256, installationId: input.installation_id, kind: input.event, payloadDigest: input.payload_sha256 });
        this.dispatcher.rememberTarget(receipt, input.target);
        await this.dispatcher.requestDrain();
        return new Response(null, { status: 202 });
    }
    async alarm() { await this.dispatcher.alarm(); }
    async watchdog() { await this.dispatcher.watchdog(); }
    recordEgress(measurement) {
        const key = `egress/${measurement.metric}/v1`;
        if (!Number.isSafeInteger(measurement.value) || measurement.value < 0) {
            this.store.writeMeta(key, 1_000_000);
            return;
        }
        if (measurement.metric === "request_high_water") {
            const prior = this.store.readMeta(key) ?? 0;
            this.store.writeMeta(key, Math.min(Math.max(prior, measurement.value), 1_000_000));
        }
        else
            this.store.incrementMeta(key, measurement.value);
    }
}
