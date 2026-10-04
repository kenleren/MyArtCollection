import { protocolGate,protocolCapability } from './dispatch_fixtures.js';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { describe, test } from 'node:test';

import type { PlayAcknowledgeArguments, PlayGetArguments } from '../src/contracts.js';
import {
  AndroidPublisherSubscriptionsAdapter,
  DisabledPlaySubscriptionsAdapter,
  GoogleAndroidPublisherTransport,
  PlayAdapterError,
  classifyPlayAdapterError,
  createConfiguredPlaySubscriptionsAdapter,
  type AndroidPublisherTransport,
  type DeadlineScheduler,
  type PublisherFetch,
  type PlayAdapterFailure,
} from '../src/play_adapter.js';

const getArguments: PlayGetArguments = {
  packageName: 'app.archivale',
  dispatch:protocolCapability,deadline:{expiresAt:Date.now()+55_000,signal:new AbortController().signal},
  token: 'opaque-test-value',
  timeoutMs: 10_000,
};

const acknowledgeArguments: PlayAcknowledgeArguments = {
  packageName: 'app.archivale',
  dispatch:protocolCapability,deadline:{expiresAt:Date.now()+55_000,signal:new AbortController().signal},
  subscriptionId: 'archivale_starter_monthly',
  token: 'opaque-test-value',
  body: {},
  timeoutMs: 10_000,
};

const normalizedPurchase = {
  subscriptionState: 'SUBSCRIPTION_STATE_ACTIVE',
  acknowledgementState: 'ACKNOWLEDGEMENT_STATE_PENDING',
  externalAccountIdentifiers: { obfuscatedExternalAccountId: 'opaque-binding' },
  lineItems: [
    {
      productId: 'archivale_starter_monthly',
      expiryTime: '2031-01-01T01:00:00.000Z',
      offerDetails: { basePlanId: 'monthly' },
      autoRenewingPlan: {},
    },
  ],
};

class FakePublisherTransport implements AndroidPublisherTransport {
  getCalls = 0;
  acknowledgeCalls = 0;
  getResult: unknown = normalizedPurchase;
  acknowledgeResult: unknown = {};
  getError?: Error;
  acknowledgeError?: Error;

  async getSubscription(_args: PlayGetArguments): Promise<unknown> {
    this.getCalls += 1;
    if (this.getError !== undefined) {
      throw this.getError;
    }
    return this.getResult;
  }

  async acknowledgeSubscription(_args: PlayAcknowledgeArguments): Promise<unknown> {
    this.acknowledgeCalls += 1;
    if (this.acknowledgeError !== undefined) {
      throw this.acknowledgeError;
    }
    return this.acknowledgeResult;
  }
}

const immediateDeadline: DeadlineScheduler = {
  schedule(onDeadline) {
    queueMicrotask(onDeadline);
    return () => undefined;
  },
};

const fakeAuth = {
  async getClient() { return { async getRequestHeaders() { return {}; } }; },
};

class ManualDeadline implements DeadlineScheduler {
  time = 0;
  private readonly pending = new Map<() => void, number>();
  readonly now = (): number => this.time;
  schedule(callback: () => void, delay: number): () => void {
    this.pending.set(callback, this.time + delay);
    return () => { this.pending.delete(callback); };
  }
  advance(ms: number): void {
    this.time += ms;
    for (const [callback, at] of this.pending) {
      if (at <= this.time) { this.pending.delete(callback); callback(); }
    }
  }
}

function deferred<T>(): { promise: Promise<T>; resolve(value: T): void } {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}

const flush = async (): Promise<void> => new Promise((done) => setImmediate(done));

function failure(classification: PlayAdapterFailure): (error: unknown) => boolean {
  return (error) => {
    assert.ok(error instanceof PlayAdapterError);
    assert.equal(classifyPlayAdapterError(error), classification);
    assert.doesNotMatch(error.message, /opaque-test-value|raw provider|response secret/);
    assert.equal(error.cause, undefined);
    return true;
  };
}

function boundedBody(bytes: number): string {
  const value = { lineItems: [], padding: Array<string>(16).fill('x'.repeat(4_000)), tail: '' };
  value.tail = 'y'.repeat(bytes - Buffer.byteLength(JSON.stringify(value)));
  const body = JSON.stringify(value);
  assert.equal(Buffer.byteLength(body), bytes);
  return body;
}

function streamBody(chunks: Uint8Array[], close = true): {
  body: ReadableStream<Uint8Array>; canceled(): number;
} {
  let canceled = 0;
  return {
    body: new ReadableStream<Uint8Array>({
      start(controller) {
        for (const chunk of chunks) controller.enqueue(chunk);
        if (close) controller.close();
      },
      cancel() { canceled += 1; },
    }),
    canceled: () => canceled,
  };
}

function withFetch(fetch: PublisherFetch, clock?: ManualDeadline): GoogleAndroidPublisherTransport {
  return new GoogleAndroidPublisherTransport({gate:protocolGate(),
    auth: fakeAuth, fetch,
    ...(clock === undefined ? {} : { now: clock.now, deadlines: clock }),
  });
}

describe('Android Publisher PlaySubscriptionsAdapter', () => {
  test('normalizes a successful subscriptionsv2 response and acknowledges exactly once', async () => {
    const transport = new FakePublisherTransport();
    const adapter = new AndroidPublisherSubscriptionsAdapter(transport);

    const purchase = await adapter.getSubscription(getArguments);
    await adapter.acknowledgeSubscription(acknowledgeArguments);

    assert.deepEqual(purchase, normalizedPurchase);
    assert.equal(transport.getCalls, 1);
    assert.equal(transport.acknowledgeCalls, 1);
  });

  test('rejects invalid package or product before any Publisher request', async () => {
    const transport = new FakePublisherTransport();
    const adapter = new AndroidPublisherSubscriptionsAdapter(transport);

    await assert.rejects(
      adapter.getSubscription({ ...getArguments, packageName: 'other.package' as 'app.archivale' }),
      /request was rejected/,
    );
    await assert.rejects(
      adapter.acknowledgeSubscription({
        ...acknowledgeArguments,
        subscriptionId: 'other_product' as 'archivale_starter_monthly',
      }),
      /request was rejected/,
    );
    assert.equal(transport.getCalls, 0);
    assert.equal(transport.acknowledgeCalls, 0);
  });

  test('fails closed with a sanitized error for malformed Publisher data', async () => {
    const transport = new FakePublisherTransport();
    transport.getResult = { subscriptionState: 'SUBSCRIPTION_STATE_ACTIVE' };
    const adapter = new AndroidPublisherSubscriptionsAdapter(transport);

    await assert.rejects(adapter.getSubscription(getArguments), (error: Error) => {
      assert.match(error.message, /response was malformed/);
      assert.doesNotMatch(error.message, /opaque-test-value/);
      return true;
    });
  });

  test('sanitizes get and acknowledgement failures without retrying', async () => {
    const transport = new FakePublisherTransport();
    transport.getError = new Error('raw provider failure opaque-test-value');
    transport.acknowledgeError = new Error('raw provider failure opaque-test-value');
    const adapter = new AndroidPublisherSubscriptionsAdapter(transport);

    await assert.rejects(adapter.getSubscription(getArguments), (error: Error) => {
      assert.equal(error.message, 'Android Publisher is temporarily unavailable');
      return true;
    });
    await assert.rejects(adapter.acknowledgeSubscription(acknowledgeArguments), (error: Error) => {
      assert.equal(error.message, 'Android Publisher is temporarily unavailable');
      return true;
    });
    assert.equal(transport.getCalls, 1);
    assert.equal(transport.acknowledgeCalls, 1);
  });

  test('enforces its absolute request deadline without exposing the input', async () => {
    let getAttempts = 0;
    let acknowledgementAttempts = 0;
    const transport: AndroidPublisherTransport = {
      getSubscription: async () => {
        getAttempts += 1;
        return new Promise<unknown>(() => undefined);
      },
      acknowledgeSubscription: async () => {
        acknowledgementAttempts += 1;
        return new Promise<unknown>(() => undefined);
      },
    };
    const adapter = new AndroidPublisherSubscriptionsAdapter(transport, immediateDeadline);

    await assert.rejects(adapter.getSubscription(getArguments), (error: Error) => {
      assert.equal(error.message, 'Android Publisher is temporarily unavailable');
      assert.doesNotMatch(error.message, /opaque-test-value/);
      return true;
    });
    await assert.rejects(adapter.acknowledgeSubscription(acknowledgeArguments), (error: Error) => {
      assert.equal(error.message, 'Android Publisher is temporarily unavailable');
      assert.doesNotMatch(error.message, /opaque-test-value/);
      return true;
    });
    assert.equal(getAttempts, 1);
    assert.equal(acknowledgementAttempts, 1);
  });

  test('uses the Android Publisher REST methods through an injected ADC transport', async () => {
    const requests: Array<{
      method: string;
      acknowledges: boolean;
      body?: string;
      contentType?: string;
    }> = [];
    const transport = new GoogleAndroidPublisherTransport({gate:protocolGate(),
      auth: {
        async getClient() {
          return { async getRequestHeaders() { return new Headers(); } };
        },
      },
      fetch: async (url, init) => {
        requests.push({
          method: init.method,
          acknowledges: url.endsWith(':acknowledge'),
          ...(init.body === undefined ? {} : { body: init.body }),
          ...(
            init.headers['content-type'] === undefined
              ? {}
              : { contentType: init.headers['content-type'] }
          ),
        });
        assert.equal(init.redirect, 'error');
        assert.ok(url.startsWith('https://androidpublisher.googleapis.com/androidpublisher/v3/applications/app.archivale/purchases/'));
        return url.endsWith(':acknowledge')
          ? new Response(null, { status: 200 })
          : Response.json(normalizedPurchase);
      },
    });

    await transport.getSubscription(getArguments);
    await transport.acknowledgeSubscription(acknowledgeArguments);

    assert.deepEqual(requests, [
      { method: 'GET', acknowledges: false },
      {
        method: 'POST',
        acknowledges: true,
        body: '',
        contentType: 'application/json',
      },
    ]);
  });

  test('accepts an HTTP 200 acknowledgement with an empty response without parsing or retrying', async () => {
    let attempts = 0;
    const transport = new GoogleAndroidPublisherTransport({gate:protocolGate(),
      auth: {
        async getClient() {
          return { async getRequestHeaders() { return {}; } };
        },
      },
      fetch: async (_url, init) => {
        attempts += 1;
        assert.equal(init.body, '');
        return new Response(null, { status: 200 });
      },
    });

    await transport.acknowledgeSubscription(acknowledgeArguments);
    assert.equal(attempts, 1);
  });

  test('accepts an HTTP 204 acknowledgement with an empty response without parsing or retrying', async () => {
    let attempts = 0;
    const transport = new GoogleAndroidPublisherTransport({gate:protocolGate(),
      auth: {
        async getClient() {
          return { async getRequestHeaders() { return {}; } };
        },
      },
      fetch: async (_url, init) => {
        attempts += 1;
        assert.equal(init.body, '');
        return new Response(null, { status: 204 });
      },
    });

    await transport.acknowledgeSubscription(acknowledgeArguments);
    assert.equal(attempts, 1);
  });

  test('fails closed after one acknowledgement attempt on an HTTP failure', async () => {
    let attempts = 0;
    const transport = new GoogleAndroidPublisherTransport({gate:protocolGate(),
      auth: {
        async getClient() {
          return { async getRequestHeaders() { return {}; } };
        },
      },
      fetch: async () => {
        attempts += 1;
        return new Response('raw provider failure opaque-test-value', { status: 500 });
      },
    });

    await assert.rejects(transport.acknowledgeSubscription(acknowledgeArguments), (error: Error) => {
      assert.equal(error.message, 'Android Publisher is temporarily unavailable');
      return true;
    });
    assert.equal(attempts, 1);
  });

  test('does not construct or call a live transport unless explicitly enabled', async () => {
    let constructions = 0;
    const adapter = createConfiguredPlaySubscriptionsAdapter({gate:protocolGate(),
      transportFactory: () => {
        constructions += 1;
        return new FakePublisherTransport();
      },
    });

    assert.ok(adapter instanceof DisabledPlaySubscriptionsAdapter);
    assert.equal(constructions, 0);
    await assert.rejects(adapter.getSubscription(getArguments), /adapter is disabled/);
  });

  test('constructs the injected Publisher transport only when explicitly enabled', async () => {
    const transport = new FakePublisherTransport();
    let constructions = 0;
    const adapter = createConfiguredPlaySubscriptionsAdapter({gate:protocolGate(),
      enabled: true,
      transportFactory: () => {
        constructions += 1;
        return transport;
      },
    });

    await adapter.getSubscription(getArguments);
    assert.equal(constructions, 1);
    assert.equal(transport.getCalls, 1);
  });

  test('declares the Google authentication library as a direct runtime dependency', async () => {
    const manifest = JSON.parse(
      await readFile(new URL('../../package.json', import.meta.url), 'utf8'),
    ) as { dependencies?: Record<string, string> };

    assert.equal(manifest.dependencies?.['google-auth-library'], '^10.9.0');
  });
});

describe('bounded Android Publisher transport', () => {
  test('accepts exactly 64 KiB of streamed JSON and rejects the next decompressed byte', async () => {
    const exact = Buffer.from(boundedBody(65_536));
    const chunks = streamBody([exact.subarray(0, 16_000), exact.subarray(16_000)]);
    const accepted = withFetch(async () => new Response(chunks.body, {
      headers: { 'content-length': '1', 'content-encoding': 'gzip' },
    }));
    assert.deepEqual(await accepted.getSubscription(getArguments), JSON.parse(exact.toString()));

    for (const parts of [
      [exact, Buffer.from(' ')],
      [Buffer.from(boundedBody(65_537))],
      [Buffer.alloc(131_072, 32)],
    ]) {
      const rejected = streamBody(parts, false);
      const transport = withFetch(async () => new Response(rejected.body, {
        headers: { 'content-length': '1' },
      }));
      await assert.rejects(transport.getSubscription(getArguments), failure('malformed'));
      assert.equal(rejected.canceled(), 1);
    }
  });

  test('rejects oversized or invalid declared lengths before consuming the body', async () => {
    for (const declared of ['65537', '99999999999999999', '-1', 'NaN']) {
      const body = streamBody([], false);
      const transport = withFetch(async () => new Response(body.body, {
        headers: { 'content-length': declared },
      }));
      await assert.rejects(transport.getSubscription(getArguments), failure('malformed'));
      assert.equal(body.canceled(), 1);
    }
  });

  test('requires valid UTF-8 and bounded JSON even in fields the app does not use', async () => {
    const nested: Record<string, unknown> = {};
    let current = nested;
    for (let depth = 0; depth < 12; depth += 1) {
      current.next = {}; current = current.next as Record<string, unknown>;
    }
    const bodies = [
      Buffer.from([0x7b, 0x22, 0xff, 0x22, 0x3a, 0x30, 0x7d]),
      Buffer.from('{"lineItems":[],"other":"\\ud800"}'),
      Buffer.from('not json response secret'),
      Buffer.from(JSON.stringify({ lineItems: [], other: nested })),
      Buffer.from(JSON.stringify({ lineItems: [], other: Array<number>(17).fill(1) })),
      Buffer.from(JSON.stringify({ lineItems: [], ...Object.fromEntries(Array.from({ length: 256 }, (_, i) => [`p${i}`, 0])) })),
      Buffer.from(JSON.stringify({ lineItems: [], other: 'é'.repeat(2_049) })),
    ];
    for (const raw of bodies) {
      const transport = withFetch(async () => new Response(raw));
      await assert.rejects(transport.getSubscription(getArguments), failure('malformed'));
    }
    const valid = withFetch(async () => Response.json({ lineItems: [], other: 'é'.repeat(2_048) }));
    await valid.getSubscription(getArguments);
  });

  test('normalizes transient resubscription context without dropping malformed ownership evidence', async () => {
    const context = {
      expiredExternalAccountIdentifiers: { obfuscatedExternalAccountId: 'previous-opaque-binding' },
      expiredPurchaseToken: 'expired-opaque-test-value',
    };
    const transport = new FakePublisherTransport();
    const adapter = new AndroidPublisherSubscriptionsAdapter(transport);
    transport.getResult = { ...normalizedPurchase, outOfAppPurchaseContext: context };
    assert.deepEqual((await adapter.getSubscription(getArguments)).outOfAppPurchaseContext, context);
    for (const malformed of [null, [], 'context', {
      expiredExternalAccountIdentifiers: null,
    }, { expiredExternalAccountIdentifiers: { obfuscatedExternalAccountId: 2 } }, {
      expiredPurchaseToken: false,
    }, { expiredPurchaseToken: '' }]) {
      transport.getResult = { ...normalizedPurchase, outOfAppPurchaseContext: malformed };
      await assert.rejects(adapter.getSubscription(getArguments), failure('malformed'));
    }
    for (const overlay of [
      { linkedPurchaseToken: false }, { externalAccountIdentifiers: [] },
      { externalAccountIdentifiers: { obfuscatedExternalAccountId: null } },
      { subscriptionState: 2 }, { acknowledgementState: [] },
      { lineItems: [{ offerDetails: null }] }, { lineItems: [{ autoRenewingPlan: false }] },
      { lineItems: Array<unknown>(17).fill({}) },
    ]) {
      transport.getResult = { ...normalizedPurchase, ...overlay };
      await assert.rejects(adapter.getSubscription(getArguments), failure('malformed'));
    }
  });

  test('classifies HTTP failures without exposing or parsing error bodies and never retries', async () => {
    const cases: Array<[number, PlayAdapterFailure]> = [
      [401, 'configuration'], [403, 'configuration'], [404, 'not_found'], [410, 'not_found'],
      [408, 'transient'], [409, 'transient'], [429, 'transient'], [500, 'transient'], [503, 'transient'],
      [400, 'rejected'], [302, 'rejected'],
    ];
    for (const [status, classification] of cases) {
      let calls = 0;
      const body = streamBody([Buffer.from('response secret')], false);
      const transport = withFetch(async () => {
        calls += 1;
        return new Response(body.body, { status });
      });
      await assert.rejects(transport.getSubscription(getArguments), failure(classification));
      assert.equal(calls, 1);
      assert.equal(body.canceled(), 1);
    }
    assert.equal(classifyPlayAdapterError(new Error('unclassified')), 'transient');
  });

  test('rejects a followed redirect and keeps tokens encoded in the fixed-origin path', async () => {
    const body = streamBody([], false);
    const transport = withFetch(async (url, init) => {
      assert.equal(url, 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/app.archivale/purchases/subscriptionsv2/tokens/a%2Fb%3Fq%3D%23%25');
      assert.equal(init.redirect, 'error');
      return { ok: true, status: 200, redirected: true, headers: new Headers(), body: body.body };
    });
    await assert.rejects(transport.getSubscription({ ...getArguments, token: 'a/b?q=#%' }), failure('rejected'));
    assert.equal(body.canceled(), 1);
  });

  test('accepts only the exact extended acknowledgement route and rejects invalid input before auth', async () => {
    let authCalls = 0;
    let fetchCalls = 0;
    const route = Buffer.alloc(32, 7).toString('base64url');
    const extended = { externalAccountIds: { obfuscatedAccountId: route } };
    const transport = new GoogleAndroidPublisherTransport({gate:protocolGate(),
      auth: { async getClient() { authCalls += 1; return fakeAuth.getClient(); } },
      fetch: async (_url, init) => {
        fetchCalls += 1;
        assert.equal(init.body, JSON.stringify(extended));
        return new Response(null, { status: 204 });
      },
    });
    for (const body of [null, { extra: 'x' }, { externalAccountIds: {} }, {
      externalAccountIds: { obfuscatedAccountId: 'noncanonical-route' },
    }, { ...extended, extra: 'x' }, {
      externalAccountIds: { ...extended.externalAccountIds, profileId: 'extra' },
    }]) {
      await assert.rejects(transport.acknowledgeSubscription({
        ...acknowledgeArguments, body: body as PlayAcknowledgeArguments['body'],
      }), failure('rejected'));
    }
    await assert.rejects(transport.acknowledgeSubscription({
      ...acknowledgeArguments, subscriptionId: 'toString' as PlayAcknowledgeArguments['subscriptionId'],
    }), failure('rejected'));
    for (const token of ['', 'é'.repeat(2_049), '\ud800']) {
      await assert.rejects(transport.getSubscription({ ...getArguments, token }), failure('rejected'));
    }
    await assert.rejects(transport.getSubscription(null as unknown as PlayGetArguments), failure('rejected'));
    assert.equal(authCalls, 0); assert.equal(fetchCalls, 0);
    await transport.acknowledgeSubscription({ ...acknowledgeArguments, body: extended });
    assert.equal(authCalls, 1); assert.equal(fetchCalls, 1);
  });

  test('drains at most 4 KiB of acknowledgement data without JSON parsing', async () => {
    const transport = withFetch(async () => new Response('x'.repeat(4_096)));
    await transport.acknowledgeSubscription(acknowledgeArguments);
    const body = streamBody([Buffer.alloc(4_097, 32)], false);
    await assert.rejects(withFetch(async () => new Response(body.body)).acknowledgeSubscription(acknowledgeArguments), failure('malformed'));
    assert.equal(body.canceled(), 1);
  });

  test('times out stalled authentication before any later header lookup or fetch', async () => {
    const clock = new ManualDeadline();
    let headers = 0;
    let fetches = 0;
    const client = deferred<{ getRequestHeaders(): Promise<object> }>();
    const transport = new GoogleAndroidPublisherTransport({gate:protocolGate(),
      auth: { getClient: () => client.promise }, deadlines: clock, now: clock.now,
      fetch: async () => { fetches += 1; return Response.json(normalizedPurchase); },
    });
    const request = assert.rejects(transport.getSubscription(getArguments), failure('transient'));
    clock.advance(10_000);
    await request;
    client.resolve({ async getRequestHeaders() { headers += 1; return {}; } });
    await flush();
    assert.equal(headers, 0); assert.equal(fetches, 0);
  });

  test('uses one deadline across authentication and headers even before its timer fires', async () => {
    const clock = new ManualDeadline();
    let fetches = 0;
    const headers = deferred<object>();
    const transport = new GoogleAndroidPublisherTransport({gate:protocolGate(),
      auth: { async getClient() {
        clock.time = 9_000;
        return { getRequestHeaders: () => headers.promise };
      } }, deadlines: clock, now: clock.now,
      fetch: async () => { fetches += 1; return Response.json(normalizedPurchase); },
    });
    const request = assert.rejects(transport.getSubscription(getArguments), failure('transient'));
    await flush();
    clock.time = 10_000;
    headers.resolve({});
    await request;
    assert.equal(fetches, 0);
  });

  test('returns on deadline when fetch ignores abort and cancels its late response', async () => {
    const clock = new ManualDeadline();
    const response = deferred<Response>();
    let signal: AbortSignal | undefined;
    const transport = withFetch(async (_url, init) => { signal = init.signal; return response.promise; }, clock);
    const request = assert.rejects(transport.getSubscription(getArguments), failure('transient'));
    await flush();
    clock.advance(10_000);
    await request;
    assert.equal(signal?.aborted, true);
    const late = streamBody([], false);
    response.resolve(new Response(late.body));
    await flush();
    assert.equal(late.canceled(), 1);
  });

  test('cancels stalled GET and acknowledgement streams without awaiting a hanging cancellation', async () => {
    for (const acknowledge of [false, true]) {
      const clock = new ManualDeadline();
      let canceled = false;
      let signal: AbortSignal | undefined;
      const body = new ReadableStream<Uint8Array>({
        cancel() { canceled = true; return new Promise<void>(() => undefined); },
      });
      const transport = withFetch(async (_url, init) => {
        signal = init.signal; return new Response(body);
      }, clock);
      const request = assert.rejects(acknowledge
        ? transport.acknowledgeSubscription(acknowledgeArguments)
        : transport.getSubscription(getArguments), failure('transient'));
      await flush();
      clock.advance(10_000);
      await request;
      assert.equal(canceled, true); assert.equal(signal?.aborted, true);
    }
  });

  test('does no authentication when its caller is already canceled or out of time', async () => {
    let authentications = 0;
    let fetches = 0;
    const transport = new GoogleAndroidPublisherTransport({gate:protocolGate(),
      auth: { async getClient() { authentications += 1; return fakeAuth.getClient(); } },
      fetch: async () => { fetches += 1; return Response.json(normalizedPurchase); },
    });
    const canceled = new AbortController(); canceled.abort(new Error('raw provider cancellation'));
    const deadlines = [
      { expiresAt: Date.now() + 10_000, signal: canceled.signal },
      { expiresAt: Date.now() - 1, signal: new AbortController().signal },
    ];
    for (const deadline of deadlines) {
      await assert.rejects(transport.getSubscription({ ...getArguments, deadline }), failure('transient'));
      await assert.rejects(transport.acknowledgeSubscription({ ...acknowledgeArguments, deadline }), failure('transient'));
    }
    assert.equal(authentications, 0); assert.equal(fetches, 0);
  });

  test('caller cancellation prevents late GET and ACK dispatch after either authentication stage', async () => {
    for (const stage of ['client', 'headers']) {
      for (const acknowledge of [false, true]) {
        const caller = new AbortController();
        const deadline = { expiresAt: Date.now() + 10_000, signal: caller.signal };
        const auth = deferred<{ getRequestHeaders(): Promise<object> }>();
        const headers = deferred<object>();
        let lookups = 0;
        let fetches = 0;
        const client = { async getRequestHeaders() {
          lookups += 1; return stage === 'headers' ? headers.promise : {};
        } };
        const transport = new GoogleAndroidPublisherTransport({gate:protocolGate(),
          auth: { async getClient() { return stage === 'client' ? auth.promise : client; } },
          fetch: async () => { fetches += 1; return new Response(null, { status: 204 }); },
        });
        const request = assert.rejects(acknowledge
          ? transport.acknowledgeSubscription({ ...acknowledgeArguments, deadline })
          : transport.getSubscription({ ...getArguments, deadline }), failure('transient'));
        await flush();
        caller.abort();
        await request;
        auth.resolve(client); headers.resolve({});
        await flush();
        assert.equal(fetches, 0);
        assert.equal(lookups, stage === 'client' ? 0 : 1);
      }
    }
  });

  test('bounds transport time by the caller deadline even before the caller timer runs', async () => {
    const clock = new ManualDeadline();
    const headers = deferred<object>();
    let fetches = 0;
    const caller = new AbortController();
    const transport = new GoogleAndroidPublisherTransport({gate:protocolGate(),
      auth: { async getClient() { return { getRequestHeaders: () => headers.promise }; } },
      now: clock.now, deadlines: clock,
      fetch: async () => { fetches += 1; return Response.json(normalizedPurchase); },
    });
    const request = assert.rejects(transport.acknowledgeSubscription({
      ...acknowledgeArguments, deadline: { expiresAt: 500, signal: caller.signal },
    }), failure('transient'));
    await flush();
    clock.time = 500;
    headers.resolve({});
    await request;
    assert.equal(caller.signal.aborted, false);
    assert.equal(fetches, 0);
  });

  test('caller cancellation aborts a stalled stream immediately rather than waiting ten seconds', async () => {
    const caller = new AbortController();
    const body = streamBody([], false);
    let signal: AbortSignal | undefined;
    const transport = withFetch(async (_url, init) => { signal = init.signal; return new Response(body.body); });
    const request = assert.rejects(transport.getSubscription({
      ...getArguments, deadline: { expiresAt: Date.now() + 60_000, signal: caller.signal },
    }), failure('transient'));
    await flush();
    caller.abort();
    await request;
    assert.equal(body.canceled(), 1);
    assert.equal(signal?.aborted, true);
  });
});
