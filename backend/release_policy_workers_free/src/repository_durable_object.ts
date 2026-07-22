import { AlarmDispatcher, type DeliveryTarget } from "./dispatcher.js";
import { loadCanonicalPolicy, receive } from "@archivale/release-policy-trust";
import type { DurableState } from "./platform.js";
import { SqliteStore } from "./sqlite_store.js";
import { parseRuntimeConfig, SQLITE_COMPATIBILITY_SHA256 } from "./config.js";
import { CANONICAL_POLICY_BYTES } from "./generated/canonical_policy_bytes.js";
import { githubAlarmPort } from "./github_app_port.js";
import type { EgressMeasurement } from "./telemetry.js";

interface RuntimeEnv { RELEASE_TRUST_CONFIG_V1: string; GITHUB_APP_PRIVATE_KEY_PEM: string }

export class RepositoryDurableObject {
  readonly store: SqliteStore;
  private readonly dispatcher: AlarmDispatcher;
  private readonly ready: Promise<void>;
  constructor(private readonly state: DurableState, env: RuntimeEnv) {
    this.store = new SqliteStore(state.storage);
    const config = parseRuntimeConfig(env.RELEASE_TRUST_CONFIG_V1);
    this.ready = state.blockConcurrencyWhile(async () => { this.store.initialize(config.activationDigest, `sha256:${SQLITE_COMPATIBILITY_SHA256}`); });
    this.dispatcher = new AlarmDispatcher(state.storage, this.store, {
      clock: { delay: async () => {} },
      identity: { appId: config.appId, baseRef: "main", installationId: config.installationId, repositoryId: config.repositoryId, repositoryName: "kenleren/MyArtCollection" },
      policy: loadCanonicalPolicy(CANONICAL_POLICY_BYTES),
      portFactory: () => githubAlarmPort({ appId: config.appId, installationId: config.installationId, repositoryId: config.repositoryId, repositoryName: "kenleren/MyArtCollection", privateKeyPem: env.GITHUB_APP_PRIVATE_KEY_PEM, fetcher: fetch, measure: (measurement) => this.recordEgress(measurement), reserveOutbound: () => this.store.reserveQuota(Date.now(), { outbound_attempts: 1 }).admitted }),
    });
  }
  async fetch(request: Request): Promise<Response> {
    try { await this.ready; } catch { return new Response("repository state unavailable", { status: 503 }); }
    this.store.incrementMeta("do_request_count/v1");
    const path = new URL(request.url).pathname;
    if (request.method !== "POST") return new Response("not found", { status: 404 });
    const quota = this.store.reserveQuota(Date.now(), { worker_events: 1, do_fetches: 1 });
    if (!quota.admitted) {
      await this.state.storage.setAlarm(quota.rolloverAt);
      const retryAfter = String(Math.max(1, Math.ceil((quota.rolloverAt - Date.now()) / 1000)));
      return new Response("repository quota unavailable", { status: 503, headers: { "retry-after": retryAfter } });
    }
    if (path === "/watchdog") { await this.watchdog(); return new Response(null, { status: 202 }); }
    if (path !== "/verified-delivery") return new Response("not found", { status: 404 });
    // This body is constructed only by the public Worker after raw HMAC and
    // identity verification. It intentionally contains no raw webhook data.
    const input = await request.json() as { delivery_id: string; event: "pull_request" | "push"; payload_sha256: string; installation_id: number; target: DeliveryTarget };
    if (!input || !["pull_request", "push"].includes(input.event) || !Number.isSafeInteger(input.installation_id) || !input.target || input.target.kind !== input.event) return new Response("invalid delivery", { status: 400 });
    if ((input.target.kind === "pull_request" && (!Number.isSafeInteger(input.target.pullRequestNumber) || input.target.pullRequestNumber <= 0)) || (input.target.kind === "push" && !/^[0-9a-f]{40}$/.test(input.target.after))) return new Response("invalid delivery", { status: 400 });
    const receipt = await receive(this.store, { deliveryId: input.delivery_id, identityDigest: input.payload_sha256, installationId: input.installation_id, kind: input.event, payloadDigest: input.payload_sha256 });
    this.dispatcher.rememberTarget(receipt, input.target);
    await this.dispatcher.requestDrain();
    return new Response(null, { status: 202 });
  }
  async alarm(): Promise<void> { await this.ready; await this.dispatcher.alarm(); }
  async watchdog(): Promise<void> { await this.ready; await this.dispatcher.watchdog(); }
  private recordEgress(measurement: EgressMeasurement): void {
    const key = `egress/${measurement.metric}/v1`;
    if (!Number.isSafeInteger(measurement.value) || measurement.value < 0) { this.store.writeMeta(key, 1_000_000); return; }
    if (measurement.metric === "request_high_water") { const prior = this.store.readMeta<number>(key) ?? 0; this.store.writeMeta(key, Math.min(Math.max(prior, measurement.value), 1_000_000)); }
    else this.store.incrementMeta(key, measurement.value);
  }
}
