import test from "node:test";
import assert from "node:assert/strict";
import { githubRoute } from "../src/github_routes.js";
import { repositoryObjectName } from "../src/config.js";
import { sanitizeTelemetry } from "../src/telemetry.js";
test("github routes reject redirects and arbitrary hosts", () => { const request = githubRoute("pullRequest", [1288597824, 1]); assert.equal(request.url, "https://api.github.com/repositories/1288597824/pulls/1"); assert.equal(request.redirect, "error"); });
test("repository namespace is frozen", () => { assert.throws(() => repositoryObjectName(1)); });
test("telemetry rejects authentication-shaped data", () => { assert.throws(() => sanitizeTelemetry({ authorization: "x" })); assert.deepEqual(sanitizeTelemetry({ delivery_digest: "a" }), { delivery_digest: "a" }); });
