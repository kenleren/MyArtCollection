import assert from "node:assert/strict";
import { test } from "node:test";
import { Readable } from "node:stream";

import {
  BETA_SIGNUP_CONSENT_VERSION,
  BETA_SIGNUP_RETENTION_VERSION,
  createBetaSignupHttpHandler,
  createInMemoryBetaSignupQueue,
  type InMemoryBetaSignupQueue,
} from "../src/index.js";

const NOW_MS = Date.UTC(2026, 6, 8, 12, 0, 0);

type TestResponse = {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
  json: Record<string, unknown>;
};

function validPayload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    email: "Collector@Example.com",
    name: "Private Collector",
    platform: "both",
    country: "Norway",
    notes: "Android first is fine.",
    consent: true,
    consentVersion: BETA_SIGNUP_CONSENT_VERSION,
    retentionVersion: BETA_SIGNUP_RETENTION_VERSION,
    sourceRoute: "/beta/",
    submittedAtClientMs: NOW_MS - 5000,
    website: "",
    ...overrides,
  };
}

async function submit(
  queue: InMemoryBetaSignupQueue,
  body: unknown,
  headers: Record<string, string> = {},
): Promise<TestResponse> {
  const handler = createBetaSignupHttpHandler({
    queue,
    nowMs: () => NOW_MS,
  });
  const response: TestResponse = {
    statusCode: 200,
    headers: {},
    body: "",
    json: {},
  };
  const request = Readable.from([]) as Readable & {
    method?: string;
    headers: Record<string, string>;
    body?: unknown;
    socket: { remoteAddress: string };
  };
  request.method = "POST";
  request.headers = {
    "content-type": "application/json",
    host: "archivale.app",
    origin: "https://archivale.app",
    "user-agent": "node-test",
    "x-forwarded-for": "203.0.113.10",
    ...headers,
  };
  request.body = body;
  request.socket = { remoteAddress: "203.0.113.10" };

  await handler(request, {
    status(code: number) {
      response.statusCode = code;
      return this;
    },
    setHeader(name: string, value: string) {
      response.headers[name] = value;
    },
    end(bodyText: string) {
      response.body = bodyText;
      response.json = JSON.parse(bodyText) as Record<string, unknown>;
    },
  });

  return response;
}

test("queues a valid beta signup as a pending manual-review record", async () => {
  const queue = createInMemoryBetaSignupQueue();
  const response = await submit(queue, validPayload());

  assert.equal(response.statusCode, 201);
  assert.deepEqual(response.json, { ok: true, status: "queued" });
  assert.equal(queue.records.length, 1);
  assert.equal(queue.records[0]?.formType, "beta_signup");
  assert.equal(queue.records[0]?.status, "pending");
  assert.equal(queue.records[0]?.normalizedEmail, "collector@example.com");
});

test("accepts callable-style data envelope without allowing extra envelope fields", async () => {
  const queue = createInMemoryBetaSignupQueue();
  const response = await submit(queue, { data: validPayload({ email: "callable@example.com" }) });

  assert.equal(response.statusCode, 201);
  assert.equal(queue.records[0]?.normalizedEmail, "callable@example.com");

  const rejected = await submit(queue, {
    data: validPayload({ email: "extra-envelope@example.com" }),
    extra: true,
  });
  assert.equal(rejected.statusCode, 400);
});

test("rejects wrong method, content type, origin, and unknown fields", async () => {
  const queue = createInMemoryBetaSignupQueue();
  const methodResponse = await submit(queue, validPayload(), { ":method": "GET" });

  const handler = createBetaSignupHttpHandler({ queue, nowMs: () => NOW_MS });
  const methodRequest = Readable.from([]) as Readable & {
    method?: string;
    headers: Record<string, string>;
    body?: unknown;
  };
  methodRequest.method = "GET";
  methodRequest.headers = {
    "content-type": "application/json",
    host: "archivale.app",
  };
  methodRequest.body = validPayload();
  const response: TestResponse = { statusCode: 200, headers: {}, body: "", json: {} };
  await handler(methodRequest, {
    status(code: number) {
      response.statusCode = code;
      return this;
    },
    setHeader(name: string, value: string) {
      response.headers[name] = value;
    },
    end(bodyText: string) {
      response.body = bodyText;
      response.json = JSON.parse(bodyText) as Record<string, unknown>;
    },
  });

  assert.equal(methodResponse.statusCode, 201);
  assert.equal(response.statusCode, 405);
  assert.equal(
    (await submit(queue, validPayload({ email: "type@example.com" }), {
      "content-type": "text/plain",
    })).statusCode,
    415,
  );
  assert.equal(
    (await submit(queue, validPayload({ email: "origin@example.com" }), {
      origin: "https://example.net",
    })).statusCode,
    403,
  );
  assert.equal(
    (await submit(queue, validPayload({ email: "unknown@example.com", artworkValue: "1000" }))).statusCode,
    400,
  );
});

test("does not queue honeypot or missing-consent requests", async () => {
  const queue = createInMemoryBetaSignupQueue();
  const honeypot = await submit(queue, validPayload({ website: "filled" }));
  const missingConsent = await submit(queue, validPayload({ email: "no-consent@example.com", consent: false }));

  assert.equal(honeypot.statusCode, 202);
  assert.equal(honeypot.json.ok, true);
  assert.equal(missingConsent.statusCode, 400);
  assert.equal(queue.records.length, 0);
});

test("suppresses duplicate email submissions without adding another queue record", async () => {
  const queue = createInMemoryBetaSignupQueue();

  assert.equal((await submit(queue, validPayload({ email: "dupe@example.com" }))).statusCode, 201);
  assert.equal((await submit(queue, validPayload({ email: " DUPE@example.com " }))).statusCode, 202);
  assert.equal(queue.records.length, 1);
});

test("uses the rate-limit adapter hook before accepting another submitter request", async () => {
  const queue = createInMemoryBetaSignupQueue();

  assert.equal((await submit(queue, validPayload({ email: "one@example.com" }))).statusCode, 201);
  assert.equal((await submit(queue, validPayload({ email: "two@example.com" }))).statusCode, 429);
  assert.equal(queue.records.length, 1);
});

test("queued records contain no tester-system mutation fields", async () => {
  const queue = createInMemoryBetaSignupQueue();
  await submit(queue, validPayload({ email: "manual-only@example.com" }));

  const serialized = JSON.stringify(queue.records[0]);
  assert.match(serialized, /"status":"pending"/);
  assert.doesNotMatch(serialized, /appDistribution|googlePlay|testerList|autoEnroll|inviteTester/i);
});
