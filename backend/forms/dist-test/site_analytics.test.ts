import assert from "node:assert/strict";
import { Readable } from "node:stream";
import { test } from "node:test";

import {
  createSitePageviewHttpHandler,
  type SitePageviewAggregate,
  type SitePageviewAggregateStore,
} from "../src/index.js";

const NOW_MS = Date.UTC(2026, 6, 9, 12, 0, 0);

type TestResponse = {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
  json: Record<string, unknown>;
};

class InMemoryPageviewStore implements SitePageviewAggregateStore {
  records: SitePageviewAggregate[] = [];

  async incrementPageview(record: SitePageviewAggregate): Promise<void> {
    this.records.push(record);
  }
}

async function submit(
  store: InMemoryPageviewStore,
  body: unknown,
  headers: Record<string, string | undefined> = {},
): Promise<TestResponse> {
  const handler = createSitePageviewHttpHandler({
    store,
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

test("records only aggregate website pageview fields", async () => {
  const store = new InMemoryPageviewStore();
  const response = await submit(store, {
    path: "/pricing",
    referrerCategory: "internal",
    screenBucket: "medium",
  });

  assert.equal(response.statusCode, 202);
  assert.deepEqual(response.json, { ok: true });
  assert.deepEqual(store.records, [
    {
      date: "2026-07-09",
      path: "/pricing/",
      referrerCategory: "internal",
      screenBucket: "medium",
    },
  ]);
  assert.equal("ip" in store.records[0]!, false);
  assert.equal("userAgent" in store.records[0]!, false);
  assert.equal("referrer" in store.records[0]!, false);
});

test("rejects raw referrer and unexpected fields", async () => {
  const store = new InMemoryPageviewStore();
  const response = await submit(store, {
    path: "/",
    referrerCategory: "direct",
    screenBucket: "large",
    referrer: "https://example.test/private",
  });

  assert.equal(response.statusCode, 400);
  assert.deepEqual(store.records, []);
});

test("rejects foreign origin and malformed paths", async () => {
  const store = new InMemoryPageviewStore();

  assert.equal(
    (
      await submit(
        store,
        { path: "/", referrerCategory: "direct", screenBucket: "large" },
        { origin: "https://example.test" },
      )
    ).statusCode,
    403,
  );
  assert.equal(
    (
      await submit(store, {
        path: "/privacy/?raw=1",
        referrerCategory: "direct",
        screenBucket: "large",
      })
    ).statusCode,
    400,
  );
  assert.deepEqual(store.records, []);
});

test("accepts callable-style data envelope", async () => {
  const store = new InMemoryPageviewStore();
  const response = await submit(store, {
    data: {
      path: "/blog/",
      referrerCategory: "external",
      screenBucket: "small",
    },
  });

  assert.equal(response.statusCode, 202);
  assert.equal(store.records[0]?.path, "/blog/");
  assert.equal(store.records[0]?.referrerCategory, "external");
});
