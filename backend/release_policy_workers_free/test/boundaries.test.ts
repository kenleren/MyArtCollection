import test from "node:test"; import assert from "node:assert/strict";
import { githubRoute } from "../src/github_routes.js"; import { repositoryObjectName } from "../src/config.js"; import { sanitizeTelemetry } from "../src/telemetry.js";
import worker from "../src/worker.js"; import { GitHubAppPort } from "../src/github_app_port.js";
test("github routes reject redirects and arbitrary hosts", () => { const request = githubRoute("pullRequest", [1288597824, 1]); assert.equal(request.url, "https://api.github.com/repositories/1288597824/pulls/1"); assert.equal(request.redirect, "error"); });
test("repository namespace is frozen", () => { assert.throws(() => repositoryObjectName(1)); });
test("telemetry rejects authentication-shaped data", () => { assert.throws(() => sanitizeTelemetry({ authorization: "x" })); assert.deepEqual(sanitizeTelemetry({ delivery_digest: "a" }), { delivery_digest: "a" }); });
test("oversize webhook and public watchdog never reach the Durable Object", async () => {
  let calls = 0; const env: any = { RELEASE_TRUST_CONFIG_V1: JSON.stringify({ repository_id: 1288597824, app_id: 1, installation_id: 2, github_api_origin: "https://api.github.com" }), GITHUB_WEBHOOK_SECRET: "synthetic", GITHUB_APP_PRIVATE_KEY_PEM: "synthetic", REPOSITORY: { idFromName: () => "id", get: () => { calls++; throw new Error("DO must not be reached"); } } };
  assert.equal((await worker.fetch(new Request("https://example.invalid/webhook", { method: "POST", headers: { "content-length": "26214401" }, body: "x" }), env)).status, 413);
  assert.equal((await worker.fetch(new Request("https://example.invalid/scheduled-watchdog", { method: "POST" }), env)).status, 404); assert.equal(calls, 0);
});
test("GitHub JSON is byte-bounded before parsing", async () => {
  const port = new GitHubAppPort(async () => new Response("x".repeat(20_000), { headers: { "content-type": "application/json", "content-length": "20000" } }), async () => "synthetic");
  await assert.rejects(() => port.getMainRef(1288597824), /exceeds bound/);
});
