import test from "node:test"; import assert from "node:assert/strict"; import { generateKeyPairSync } from "node:crypto";
import { githubRoute } from "../src/github_routes.js"; import { repositoryObjectName } from "../src/config.js"; import { sanitizeTelemetry } from "../src/telemetry.js";
import worker from "../src/worker.js"; import { GitHubAppPort, githubAlarmPort } from "../src/github_app_port.js";
test("github routes reject redirects and arbitrary hosts", () => { const request = githubRoute("pullRequest", [1288597824, 1]); assert.equal(request.url, "https://api.github.com/repositories/1288597824/pulls/1"); assert.equal(request.redirect, "manual"); });
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
test("one alarm memoizes one token and rejects subrequest 51 before send", async () => {
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048, privateKeyEncoding: { type: "pkcs8", format: "pem" }, publicKeyEncoding: { type: "spki", format: "pem" } });
  let calls = 0; let tokenCalls = 0;
  const fetcher: typeof fetch = async (input) => {
    calls += 1; const request = input instanceof Request ? input : new Request(input);
    if (request.url.endsWith("/app/installations/2/access_tokens")) { tokenCalls += 1; return new Response('{"token":"synthetic"}', { headers: { "content-type": "application/json" } }); }
    assert.equal(request.url, "https://api.github.com/repositories/1288597824/git/ref/heads/main");
    assert.equal(request.headers.get("authorization"), "Bearer synthetic");
    return new Response(`{"object":{"sha":"${"a".repeat(40)}"}}`, { headers: { "content-type": "application/json" } });
  };
  const port = githubAlarmPort({ appId: 1, installationId: 2, privateKeyPem: privateKey, fetcher });
  for (let index = 0; index < 49; index += 1) await port.getMainRef(1288597824);
  assert.equal(calls, 50); assert.equal(tokenCalls, 1);
  await assert.rejects(() => port.getMainRef(1288597824), /subrequest budget exhausted/);
  assert.equal(calls, 50); assert.equal(tokenCalls, 1);
});
