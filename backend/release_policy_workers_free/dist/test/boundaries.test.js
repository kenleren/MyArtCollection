import test from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { githubRoute } from "../src/github_routes.js";
import { repositoryObjectName } from "../src/config.js";
import { sanitizeTelemetry } from "../src/telemetry.js";
import worker from "../src/worker.js";
import { classifyGitHubEgress, enforceGitHubEgress, GitHubAppPort, githubAlarmPort } from "../src/github_app_port.js";
import { boundedBucket } from "../src/telemetry.js";
const frozen = { installationId: 2, repositoryId: 1288597824 };
const runtimeConfig = { contract_version: 1, repository_id: 1288597824, repository_name: "kenleren/MyArtCollection", app_id: 1, installation_id: 2, github_api_origin: "https://api.github.com", github_api_version: "2022-11-28", policy_sha256: "a443af2eb86fa310ea8705826e70d1b178a4d8d231060440ed522d3069b9a80d", egress_manifest_sha256: "4076541b10ad17bd6e300d838032c49538cb4aa9a172685fe9f0cef02fd4c368", permissions: { checks: "write", contents: "read", metadata: "read", pull_requests: "read" }, quota: { window_seconds: 86400, warning_units: 1000, hard_units: 10000 } };
test("github routes reject redirects and arbitrary hosts", () => { const request = githubRoute(frozen, "pullRequest", [1288597824, 1]); assert.equal(request.url, "https://api.github.com/repositories/1288597824/pulls/1"); assert.equal(request.redirect, "manual"); });
test("repository namespace is frozen", () => { assert.throws(() => repositoryObjectName(1)); });
test("telemetry rejects authentication-shaped data", () => { assert.throws(() => sanitizeTelemetry({ authorization: "x" })); assert.deepEqual(sanitizeTelemetry({ delivery_digest: "a" }), { delivery_digest: "a" }); });
test("telemetry thresholds fail closed and expose zero/nonzero transitions", () => { assert.equal(boundedBucket(0, 1, 3), 0); assert.equal(boundedBucket(1, 1, 3), 1); assert.equal(boundedBucket(3, 1, 3), 2); assert.equal(boundedBucket(Number.NaN, 1, 3), 2); });
test("egress classifier measures forbidden and commit-status attempts", () => { const metrics = []; const measure = (row) => metrics.push(row.metric); assert.equal(classifyGitHubEgress(frozen, new Request("https://api.github.com/repositories/1/check-runs", { method: "POST" })), "forbidden"); assert.throws(() => enforceGitHubEgress(frozen, new Request(`https://api.github.com/repositories/1/statuses/${"a".repeat(40)}`, { method: "POST" }), measure), /route rejected/); assert.throws(() => enforceGitHubEgress(frozen, new Request("https://example.invalid/"), measure), /route rejected/); assert.deepEqual(metrics, ["status_egress", "forbidden_egress"]); });
test("oversize webhook and public watchdog never reach the Durable Object", async () => {
    let calls = 0;
    const env = { RELEASE_TRUST_CONFIG_V1: JSON.stringify(runtimeConfig), GITHUB_WEBHOOK_SECRET: "synthetic", GITHUB_APP_PRIVATE_KEY_PEM: "synthetic", REPOSITORY: { idFromName: () => "id", get: () => { calls++; throw new Error("DO must not be reached"); } } };
    assert.equal((await worker.fetch(new Request("https://example.invalid/webhook", { method: "POST", headers: { "content-length": "26214401" }, body: "x" }), env)).status, 413);
    assert.equal((await worker.fetch(new Request("https://example.invalid/scheduled-watchdog", { method: "POST" }), env)).status, 404);
    assert.equal(calls, 0);
});
test("GitHub JSON is byte-bounded before parsing", async () => {
    const port = new GitHubAppPort(async () => new Response("x".repeat(20_000), { headers: { "content-type": "application/json", "content-length": "20000" } }), async () => "synthetic", { appId: 1, baseRef: "main", installationId: 2, repositoryId: 1288597824, repositoryName: "kenleren/MyArtCollection" });
    await assert.rejects(() => port.getMainRef(1288597824), /exceeds bound/);
});
test("one alarm memoizes one token and rejects subrequest 51 before send", async () => {
    const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048, privateKeyEncoding: { type: "pkcs8", format: "pem" }, publicKeyEncoding: { type: "spki", format: "pem" } });
    let calls = 0;
    let tokenCalls = 0;
    const fetcher = async (input) => {
        calls += 1;
        const request = input instanceof Request ? input : new Request(input);
        if (request.url.endsWith("/app/installations/2/access_tokens")) {
            tokenCalls += 1;
            assert.equal(request.headers.get("content-type"), "application/json");
            assert.equal(await request.text(), '{"repository_ids":[1288597824],"permissions":{"checks":"write","contents":"read","metadata":"read","pull_requests":"read"}}');
            const expiry = new Date((Math.floor(Date.now() / 1000) + 120) * 1000).toISOString().replace(".000", "");
            return new Response(JSON.stringify({ token: "synthetic", expires_at: expiry, permissions: { pull_requests: "read", metadata: "read", checks: "write", contents: "read" }, repository_selection: "selected", repositories: [{ id: 1288597824, node_id: "R_test", name: "MyArtCollection", full_name: "kenleren/MyArtCollection", private: true, owner: { login: "kenleren" } }], expires_at_extra: "documented fields permitted" }), { status: 201, headers: { "content-type": "application/json" } });
        }
        assert.equal(request.url, "https://api.github.com/repositories/1288597824/git/ref/heads/main");
        assert.equal(request.headers.get("authorization"), "Bearer synthetic");
        return new Response(`{"object":{"sha":"${"a".repeat(40)}"}}`, { headers: { "content-type": "application/json" } });
    };
    const measurements = [];
    const port = githubAlarmPort({ appId: 1, installationId: 2, repositoryId: 1288597824, repositoryName: "kenleren/MyArtCollection", privateKeyPem: privateKey, fetcher, measure: (row) => measurements.push(row) });
    for (let index = 0; index < 49; index += 1)
        await port.getMainRef(1288597824);
    assert.equal(calls, 50);
    assert.equal(tokenCalls, 1);
    await assert.rejects(() => port.getMainRef(1288597824), /subrequest budget exhausted/);
    assert.equal(calls, 50);
    assert.equal(tokenCalls, 1);
    assert.equal(measurements.filter((row) => row.metric === "request_high_water").at(-1)?.value, 51);
    assert.equal(measurements.filter((row) => row.metric === "exceeded_resource").length, 1);
});
