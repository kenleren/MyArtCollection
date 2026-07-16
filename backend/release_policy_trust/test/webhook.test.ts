import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { verifyWebhook, type HeaderField } from "../src/webhook.js";
import { validateDeliveryIdentity } from "../src/delivery.js";
import { identity, policy } from "./helpers.js";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { loadCanonicalPolicy } from "../src/policy.js";

const secret = Buffer.from("synthetic-test-secret");
const policySource = JSON.parse(readFileSync(resolve(process.cwd(), "policy/release-policy.v1.json"), "utf8")) as { limits: Record<string, unknown> } & Record<string, unknown>;
function withLimits(overrides: Record<string, number>) { return loadCanonicalPolicy(Buffer.from(`${JSON.stringify({ ...policySource, limits: { ...policySource.limits, ...overrides } })}\n`)); }
function signed(body: Buffer, event = "pull_request", delivery = "delivery-1"): HeaderField[] {
  return [
    { name: "Content-Type", value: "application/json; charset=UTF-8" },
    { name: "X-Hub-Signature-256", value: `sha256=${createHmac("sha256", secret).update(body).digest("hex")}` },
    { name: "X-GitHub-Event", value: event },
    { name: "X-GitHub-Delivery", value: delivery },
  ];
}

test("valid raw-byte pull and push deliveries verify", () => {
  const pull = Buffer.from('{"action":"opened"}');
  assert.equal(verifyWebhook(pull, signed(pull), secret, policy()).action, "opened");
  const push = Buffer.from('{"ref":"refs/heads/main","after":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}');
  assert.equal(verifyWebhook(push, signed(push, "push"), secret, policy()).event, "push");
});

test("HMAC is checked before parsing and exact raw bytes matter", () => {
  const malformed = Buffer.from('{"action":');
  const headers = signed(malformed);
  headers[1] = { ...headers[1]!, value: `sha256=${"0".repeat(64)}` };
  assert.throws(() => verifyWebhook(malformed, headers, secret, policy()), /signature mismatch/);
  assert.throws(() => verifyWebhook(Buffer.from('{ "action":"opened"}'), signed(Buffer.from('{"action":"opened"}')), secret, policy()), /signature mismatch/);
  assert.throws(() => verifyWebhook(malformed, signed(malformed), secret, policy()), /invalid JSON/);
});

test("headers, UTF-8, duplicate keys, identity-shaped extras, and actions fail closed", () => {
  const duplicate = Buffer.from('{"action":"opened","action":"edited"}');
  assert.throws(() => verifyWebhook(duplicate, signed(duplicate), secret, policy()), /duplicate JSON key/);
  const invalidUtf8 = Buffer.from([0xff]);
  assert.throws(() => verifyWebhook(invalidUtf8, signed(invalidUtf8), secret, policy()), /UTF-8/);
  const body = Buffer.from('{"action":"closed"}');
  assert.throws(() => verifyWebhook(body, signed(body), secret, policy()), /unsupported pull request action/);
  const headers = signed(Buffer.from('{"action":"opened"}'));
  headers.push({ ...headers[0]! });
  assert.throws(() => verifyWebhook(Buffer.from('{"action":"opened"}'), headers, secret, policy()), /exactly once/);
});

test("strict JSON accepts only SP TAB CR LF whitespace", () => {
  for (const whitespace of [" ", "\t", "\r", "\n"]) {
    const body = Buffer.from(`{${whitespace}\"action\":\"opened\"}`);
    assert.equal(verifyWebhook(body, signed(body), secret, policy()).action, "opened");
  }
  for (const whitespace of ["\v", "\f", "\u00a0", "\u2028", "\u2029"]) {
    const body = Buffer.from(`{${whitespace}\"action\":\"opened\"}`);
    assert.throws(() => verifyWebhook(body, signed(body), secret, policy()), /object key|JSON/);
  }
});

test("numeric webhook limits accept max and reject max plus one", () => {
  const body = Buffer.from('{"action":"opened"}');
  assert.equal(verifyWebhook(body, signed(body), secret, withLimits({ webhook_body_bytes: body.length })).event, "pull_request");
  assert.throws(() => verifyWebhook(body, signed(body), secret, withLimits({ webhook_body_bytes: body.length - 1 })), /too large/);
  const headers = signed(body);
  assert.equal(verifyWebhook(body, headers, secret, withLimits({ header_count: headers.length })).event, "pull_request");
  assert.throws(() => verifyWebhook(body, headers, secret, withLimits({ header_count: headers.length - 1 })), /too many/);
});

test("repository, installation, base, numeric PR, and fork identity are strict", () => {
  const payload = { action: "opened", installation: { id: 22 }, number: 7, pull_request: { base: { ref: "main", repo: { id: 33 } }, head: { repo: { id: 33 } } }, repository: { full_name: "kenleren/MyArtCollection", id: 33 } };
  const body = Buffer.from(JSON.stringify(payload));
  const verified = verifyWebhook(body, signed(body), secret, policy());
  assert.deepEqual(validateDeliveryIdentity(verified, identity), { kind: "pull_request", pullRequestNumber: 7 });
  for (const mutation of [
    { ...payload, installation: { id: 99 } },
    { ...payload, repository: { ...payload.repository, id: 99 } },
    { ...payload, pull_request: { ...payload.pull_request, base: { ...payload.pull_request.base, ref: "develop" } } },
    { ...payload, pull_request: { ...payload.pull_request, head: { repo: { id: 99 } } } },
    { ...payload, number: 1.5 },
  ]) {
    const changedBody = Buffer.from(JSON.stringify(mutation));
    assert.throws(() => validateDeliveryIdentity(verifyWebhook(changedBody, signed(changedBody), secret, policy()), identity));
  }
});

test("JSON depth, JSON nodes, delivery ID, and header-value limits are exact", () => {
  const body = Buffer.from('{"action":"opened"}');
  assert.equal(verifyWebhook(body, signed(body, "pull_request", "d".repeat(128)), secret, withLimits({ json_depth: 1, json_nodes: 2 })).deliveryId.length, 128);
  assert.throws(() => verifyWebhook(body, signed(body, "pull_request", "d".repeat(129)), secret, policy()), /delivery id is malformed/);
  const nested = Buffer.from('{"action":"opened","extra":{"nested":true}}');
  assert.throws(() => verifyWebhook(nested, signed(nested), secret, withLimits({ json_depth: 1 })), /depth/);
  assert.throws(() => verifyWebhook(body, signed(body), secret, withLimits({ json_nodes: 1 })), /node count/);
  assert.throws(() => verifyWebhook(body, signed(body), secret, withLimits({ header_value_bytes: 16 })), /header value is malformed/);
});
