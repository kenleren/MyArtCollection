import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { verifyWebhook, type HeaderField, type WebhookLimits } from "../src/webhook.js";
import { validateDeliveryIdentity } from "../src/delivery.js";
import { identity } from "./helpers.js";

const secret = Buffer.from("synthetic-test-secret");
const limits: WebhookLimits = { actionBytes: 64, bodyBytes: 26_214_400, deliveryIdBytes: 128, eventBytes: 32, headerCount: 64, headerNameBytes: 64, headerValueBytes: 1024, jsonDepth: 64, jsonNodes: 200_000 };
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
  assert.equal(verifyWebhook(pull, signed(pull), secret, limits).action, "opened");
  const push = Buffer.from('{"ref":"refs/heads/main","after":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}');
  assert.equal(verifyWebhook(push, signed(push, "push"), secret, limits).event, "push");
});

test("HMAC is checked before parsing and exact raw bytes matter", () => {
  const malformed = Buffer.from('{"action":');
  const headers = signed(malformed);
  headers[1] = { ...headers[1]!, value: `sha256=${"0".repeat(64)}` };
  assert.throws(() => verifyWebhook(malformed, headers, secret, limits), /signature mismatch/);
  assert.throws(() => verifyWebhook(Buffer.from('{ "action":"opened"}'), signed(Buffer.from('{"action":"opened"}')), secret, limits), /signature mismatch/);
  assert.throws(() => verifyWebhook(malformed, signed(malformed), secret, limits), /invalid JSON/);
});

test("headers, UTF-8, duplicate keys, identity-shaped extras, and actions fail closed", () => {
  const duplicate = Buffer.from('{"action":"opened","action":"edited"}');
  assert.throws(() => verifyWebhook(duplicate, signed(duplicate), secret, limits), /duplicate JSON key/);
  const invalidUtf8 = Buffer.from([0xff]);
  assert.throws(() => verifyWebhook(invalidUtf8, signed(invalidUtf8), secret, limits), /UTF-8/);
  const body = Buffer.from('{"action":"closed"}');
  assert.throws(() => verifyWebhook(body, signed(body), secret, limits), /unsupported pull request action/);
  const headers = signed(Buffer.from('{"action":"opened"}'));
  headers.push({ ...headers[0]! });
  assert.throws(() => verifyWebhook(Buffer.from('{"action":"opened"}'), headers, secret, limits), /exactly once/);
});

test("numeric webhook limits accept max and reject max plus one", () => {
  const body = Buffer.from('{"action":"opened"}');
  const exact = { ...limits, bodyBytes: body.length };
  assert.equal(verifyWebhook(body, signed(body), secret, exact).event, "pull_request");
  assert.throws(() => verifyWebhook(body, signed(body), secret, { ...exact, bodyBytes: body.length - 1 }), /too large/);
  const headers = signed(body);
  assert.equal(verifyWebhook(body, headers, secret, { ...limits, headerCount: headers.length }).event, "pull_request");
  assert.throws(() => verifyWebhook(body, headers, secret, { ...limits, headerCount: headers.length - 1 }), /too many/);
});

test("repository, installation, base, numeric PR, and fork identity are strict", () => {
  const payload = { action: "opened", installation: { id: 22 }, number: 7, pull_request: { base: { ref: "main", repo: { id: 33 } }, head: { repo: { id: 33 } } }, repository: { full_name: "kenleren/MyArtCollection", id: 33 } };
  const body = Buffer.from(JSON.stringify(payload));
  const verified = verifyWebhook(body, signed(body), secret, limits);
  assert.deepEqual(validateDeliveryIdentity(verified, identity), { kind: "pull_request", pullRequestNumber: 7 });
  for (const mutation of [
    { ...payload, installation: { id: 99 } },
    { ...payload, repository: { ...payload.repository, id: 99 } },
    { ...payload, pull_request: { ...payload.pull_request, base: { ...payload.pull_request.base, ref: "develop" } } },
    { ...payload, pull_request: { ...payload.pull_request, head: { repo: { id: 99 } } } },
    { ...payload, number: 1.5 },
  ]) {
    const changedBody = Buffer.from(JSON.stringify(mutation));
    assert.throws(() => validateDeliveryIdentity(verifyWebhook(changedBody, signed(changedBody), secret, limits), identity));
  }
});

test("JSON depth, JSON nodes, delivery ID, and header-value limits are exact", () => {
  const body = Buffer.from('{"action":"opened"}');
  assert.equal(verifyWebhook(body, signed(body, "pull_request", "d".repeat(128)), secret, { ...limits, jsonDepth: 1, jsonNodes: 2 }).deliveryId.length, 128);
  assert.throws(() => verifyWebhook(body, signed(body, "pull_request", "d".repeat(129)), secret, limits), /delivery id is malformed/);
  assert.throws(() => verifyWebhook(body, signed(body), secret, { ...limits, jsonDepth: 0 }), /depth/);
  assert.throws(() => verifyWebhook(body, signed(body), secret, { ...limits, jsonNodes: 1 }), /node count/);
  assert.throws(() => verifyWebhook(body, signed(body), secret, { ...limits, headerValueBytes: 16 }), /header value is malformed/);
});
