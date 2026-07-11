import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { describe, test } from 'node:test';

import type { PlayAcknowledgeArguments, PlayGetArguments } from '../src/contracts.js';
import {
  AndroidPublisherSubscriptionsAdapter,
  DisabledPlaySubscriptionsAdapter,
  GoogleAndroidPublisherTransport,
  createConfiguredPlaySubscriptionsAdapter,
  type AndroidPublisherTransport,
  type DeadlineScheduler,
} from '../src/play_adapter.js';

const getArguments: PlayGetArguments = {
  packageName: 'app.archivale',
  token: 'opaque-test-value',
  timeoutMs: 10_000,
};

const acknowledgeArguments: PlayAcknowledgeArguments = {
  packageName: 'app.archivale',
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
    const transport = new GoogleAndroidPublisherTransport({
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
        return url.endsWith(':acknowledge')
          ? {
              ok: true,
              status: 200,
              async json() {
                assert.fail('acknowledgement response must not be parsed');
              },
            }
          : {
              ok: true,
              status: 200,
              async json() {
                return normalizedPurchase;
              },
            };
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
    const transport = new GoogleAndroidPublisherTransport({
      auth: {
        async getClient() {
          return { async getRequestHeaders() { return {}; } };
        },
      },
      fetch: async (_url, init) => {
        attempts += 1;
        assert.equal(init.body, '');
        return {
          ok: true,
          status: 200,
          async json() {
            assert.fail('empty acknowledgement response must not be parsed');
          },
        };
      },
    });

    await transport.acknowledgeSubscription(acknowledgeArguments);
    assert.equal(attempts, 1);
  });

  test('accepts an HTTP 204 acknowledgement with an empty response without parsing or retrying', async () => {
    let attempts = 0;
    const transport = new GoogleAndroidPublisherTransport({
      auth: {
        async getClient() {
          return { async getRequestHeaders() { return {}; } };
        },
      },
      fetch: async (_url, init) => {
        attempts += 1;
        assert.equal(init.body, '');
        return {
          ok: true,
          status: 204,
          async json() {
            assert.fail('empty acknowledgement response must not be parsed');
          },
        };
      },
    });

    await transport.acknowledgeSubscription(acknowledgeArguments);
    assert.equal(attempts, 1);
  });

  test('fails closed after one acknowledgement attempt on an HTTP failure', async () => {
    let attempts = 0;
    const transport = new GoogleAndroidPublisherTransport({
      auth: {
        async getClient() {
          return { async getRequestHeaders() { return {}; } };
        },
      },
      fetch: async () => {
        attempts += 1;
        return {
          ok: false,
          status: 500,
          async json() {
            return {};
          },
        };
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
    const adapter = createConfiguredPlaySubscriptionsAdapter({
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
    const adapter = createConfiguredPlaySubscriptionsAdapter({
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
