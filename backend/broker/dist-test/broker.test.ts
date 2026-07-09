import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { Readable } from 'node:stream';
import test from 'node:test';
import {
  APPROVED_PAYLOAD_CLASS,
  CURRENT_CONSENT_COPY_VERSION,
  CURRENT_PAYLOAD_CONTRACT_VERSION,
  type BrokerContext,
  type BrokerRequest,
  type BrokerResearchOutput,
  type ProviderClient,
  type ProviderResearchResult,
} from '../src/contracts.js';
import { createFakeBrokerDependencies, handleResearchRequest } from '../src/broker.js';
import {
  handleBrokerAdapterRequest,
  handleFakeBrokerAdapterRequest,
  type BrokerAdapterEnvelope,
  type BrokerAdapterIdentity,
  type FakeBrokerAdapterEnvelope,
  type FakeBrokerAdapterIdentity,
} from '../src/adapter.js';
import { PlaceholderCreditLedger } from '../src/credit_ledger.js';
import {
  buildOpenAiResponsesRequest,
  createOpenAiProvider,
  readOpenAiProviderConfigFromEnv,
} from '../src/openai_provider.js';
import { authorizeProviderRequest } from '../src/provider_authorization.js';
import {
  createFirebaseResearchBrokerDependencies,
} from '../src/firebase.js';
import {
  createConfiguredResearchBrokerDependencies,
  createResearchBrokerHttpHandler,
  isResearchBrokerLiveEnabled,
  type MinimalResponse,
} from '../src/live_broker.js';
import {
  ConfiguredDurableBrokerProtection,
  DurableCreditLedger,
  DurableIdempotencyStore,
  FakeBrokerTokenVerifier,
  FakeDurableBrokerStore,
  FirebaseAdminBrokerTokenVerifier,
  createFirebaseAdminDurableBrokerProtection,
  deriveQuotaSubject,
  type DurableBrokerProtection,
  type DurableFirestoreDocumentRef,
  type DurableFirestoreDocumentSnapshot,
  type DurableFirestoreLike,
  type DurableFirestoreTransaction,
  type FirebaseAdminAppCheckLike,
  type FirebaseAdminAuthLike,
} from '../src/durable_protection.js';

const baseContext = Object.freeze({
  app_check_verified: true,
  auth_verified: true,
  auth_identity: {
    uid: 'anonymous-test-uid',
    project_id: 'local-broker-project',
    sign_in_provider: 'anonymous',
  },
  app_identity: {
    app_id: 'local-ios-app',
    project_id: 'local-broker-project',
  },
  quota_subject: 'quota_subject_v1_aaaaaaaaaaaaaaaa',
  entitled: true,
  credit_available: true,
  breaker_open: false,
} satisfies BrokerContext);

function request(overrides: Partial<BrokerRequest> = {}): BrokerRequest {
  return {
    request_id: '11111111-1111-4111-8111-111111111111',
    consent_status: 'approved',
    consent_scope: 'image_only',
    consent_copy_version: CURRENT_CONSENT_COPY_VERSION,
    payload_contract_version: CURRENT_PAYLOAD_CONTRACT_VERSION,
    payload_hash: 'a'.repeat(64),
    approved_payload_class: APPROVED_PAYLOAD_CLASS,
    image: {
      mime_type: 'image/jpeg',
      byte_size: 120_000,
      long_edge_px: 1400,
    },
    ...overrides,
  };
}

function adapterIdentity(
  overrides: Partial<FakeBrokerAdapterIdentity> = {},
): FakeBrokerAdapterIdentity {
  return {
    auth: {
      appCheckVerified: true,
      authVerified: true,
      uid: 'anonymous-test-uid',
      authProjectId: 'local-broker-project',
      signInProvider: 'anonymous',
    },
    app: {
      appId: 'local-ios-app',
      appProjectId: 'local-broker-project',
    },
    quotaSubject: 'quota_subject_v1_aaaaaaaaaaaaaaaa',
    entitled: true,
    creditAvailable: true,
    breakerOpen: false,
    ...overrides,
  };
}

function assertSanitizedEnvelope(envelope: FakeBrokerAdapterEnvelope): void {
  const serialized = JSON.stringify(envelope);
  for (const forbidden of [
    'raw private collector notes',
    'provider_key',
    'OPENAI',
    'API_KEY',
    'process.env',
    '.env.local',
    'orderTrace',
    'stack',
    'traceback',
    'credit_finalize',
  ]) {
    assert.equal(serialized.includes(forbidden), false, forbidden);
  }
}

function invalidOutput(): BrokerResearchOutput {
  return {
    sources: [
      {
        source_id: 'src_bad_url',
        source_name: 'Invalid Fixture',
        source_type: 'museum',
        source_url: 'http://example.invalid/not-https',
        title: 'Invalid source URL fixture',
        accessed_at: new Date('2026-07-06T00:00:00.000Z').toISOString(),
        citation_excerpt: 'Fixture excerpt.',
        matched_fields: ['title'],
      },
    ],
    candidate_attributions: [],
    comparable_value_signals: [],
    warnings: [],
  };
}

type TestHttpResponse = {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
  json: Record<string, unknown>;
};

function createHttpRequest(
  body: unknown,
  headers: Record<string, string | undefined> = {},
) {
  const request = Readable.from([]) as Readable & {
    method?: string;
    headers: Record<string, string>;
    body?: unknown;
  };
  request.method = 'POST';
  request.headers = {
    'content-type': 'application/json',
    authorization: 'Bearer owner-auth-token',
    'x-firebase-appcheck': 'owner-app-check-token',
    'x-archivale-broker-app-check-verified': 'true',
    'x-archivale-broker-auth-verified': 'true',
    'x-archivale-broker-auth-uid': 'owner-uid',
    'x-archivale-broker-auth-project-id': 'broker-project',
    'x-archivale-broker-auth-provider': 'anonymous',
    'x-archivale-broker-app-id': 'owner-test-app',
    'x-archivale-broker-app-project-id': 'broker-project',
    'x-archivale-broker-quota-subject': 'quota_subject_v1_aaaaaaaaaaaaaaaa',
    'x-archivale-broker-entitled': 'true',
    'x-archivale-broker-credit-available': 'true',
    'x-archivale-broker-breaker-open': 'false',
    ...headers,
  };
  request.body = body;
  return request;
}

function createHttpResponse(): TestHttpResponse & {
  responder: MinimalResponse;
} {
  const response: TestHttpResponse = {
    statusCode: 200,
    headers: {},
    body: '',
    json: {},
  };

  const responder: MinimalResponse = {
    status(code: number) {
      response.statusCode = code;
      return responder;
    },
    setHeader(name: string, value: string) {
      response.headers[name] = value;
    },
    end(bodyText: string) {
      response.body = bodyText;
      response.json = JSON.parse(bodyText) as Record<string, unknown>;
    },
  };

  return Object.assign(response, {
    responder,
  });
}

function durableEnv(overrides: Record<string, string | undefined> = {}): NodeJS.ProcessEnv {
  return {
    BROKER_HTTP_ENABLED: 'true',
    BROKER_PROVIDER_MODE: 'openai',
    BROKER_OPENAI_LIVE_TEST_ENABLED: 'true',
    BROKER_OWNER_UID_ALLOWLIST: 'owner-uid',
    BROKER_FIREBASE_PROJECT_ID: 'broker-project',
    BROKER_FIREBASE_PROJECT_NUMBER: '123456789',
    BROKER_APP_ID_ALLOWLIST: 'owner-test-app',
    BROKER_DURABLE_STORE_CONFIGURED: 'true',
    BROKER_QUOTA_HMAC_SECRET: 'test-only-quota-hmac-secret',
    OPENAI_API_KEY: 'test-openai-key',
    OPENAI_ALLOWED_DOMAINS: 'museum.example',
    ...overrides,
  };
}

function createFakeDurableProtection(
  store = new FakeDurableBrokerStore({ entitledUids: ['owner-uid'] }),
  tokenMap?: ReadonlyMap<
    string,
    { uid: string; appId: string; projectId?: string; signInProvider?: string }
  >,
): DurableBrokerProtection {
  const config = {
    projectId: 'broker-project',
    projectNumber: '123456789',
    allowedAppIds: new Set(['owner-test-app']),
    quotaHmacSecret: 'test-only-quota-hmac-secret',
  };
  return new ConfiguredDurableBrokerProtection(
    new FakeBrokerTokenVerifier(config, tokenMap),
    store,
    new DurableIdempotencyStore(store),
    new DurableCreditLedger(store),
    config,
  );
}

function liveDependenciesFactory(options: {
  protection?: DurableBrokerProtection;
  store?: FakeDurableBrokerStore;
  provider?: ProviderClient;
  configLookup?: () => void;
  env?: NodeJS.ProcessEnv;
} = {}): ReturnType<typeof createConfiguredResearchBrokerDependencies> {
  const store = options.store ?? new FakeDurableBrokerStore({ entitledUids: ['owner-uid'] });
  const protection = options.protection ?? createFakeDurableProtection(store);
  if (options.provider !== undefined) {
    return {
      kind: 'ready',
      ownerUidAllowlist: new Set(['owner-uid']),
      durableProtection: true,
      protection,
      createDependencies: () => {
        options.configLookup?.();
        return createFakeBrokerDependencies({
          provider: options.provider,
          idempotency: protection.createIdempotencyStore(),
          creditLedger: protection.createCreditLedger(),
        });
      },
    };
  }
  return createConfiguredResearchBrokerDependencies(
    options.env ?? durableEnv(),
    {},
    () => {
      options.configLookup?.();
      return {
        ok: true,
        config: {
          apiKey: 'test-openai-key',
          allowedDomains: ['museum.example'],
          fetchImpl: (async () => {
            throw new Error('unexpected live OpenAI fetch');
          }) as typeof fetch,
        },
      };
    },
    protection,
  );
}

function fakeFirebaseAuth(): FirebaseAdminAuthLike {
  return {
    async verifyIdToken(token, checkRevoked) {
      assert.equal(checkRevoked, true);
      if (token !== 'owner-auth-token') {
        throw new Error('invalid auth token');
      }
      return {
        uid: 'owner-uid',
        aud: 'broker-project',
        iss: 'https://securetoken.google.com/broker-project',
        firebase: { sign_in_provider: 'anonymous' },
      };
    },
  };
}

function fakeFirebaseAppCheck(
  overrides: Record<string, unknown> = {},
): FirebaseAdminAppCheckLike {
  return {
    async verifyToken(token) {
      if (token !== 'owner-app-check-token') {
        throw new Error('invalid app check token');
      }
      return {
        appId: 'owner-test-app',
        aud: ['123456789', 'broker-project'],
        iss: 'https://firebaseappcheck.googleapis.com/123456789',
        ...overrides,
      };
    },
  };
}

class MemoryFirestoreSnapshot implements DurableFirestoreDocumentSnapshot {
  constructor(private readonly currentData: Record<string, unknown> | undefined) {}

  get exists(): boolean {
    return this.currentData !== undefined;
  }

  data(): Record<string, unknown> | undefined {
    return cloneRecord(this.currentData);
  }
}

class MemoryFirestoreDocumentRef implements DurableFirestoreDocumentRef {
  constructor(
    private readonly firestore: MemoryFirestore,
    readonly path: string,
  ) {}

  async get(): Promise<DurableFirestoreDocumentSnapshot> {
    return new MemoryFirestoreSnapshot(this.firestore.read(this.path));
  }

  async set(data: Record<string, unknown>, options?: { merge?: boolean }): Promise<void> {
    this.firestore.write(this.path, data, options?.merge === true);
  }

  async update(data: Record<string, unknown>): Promise<void> {
    this.firestore.write(this.path, data, true);
  }

  async delete(): Promise<void> {
    this.firestore.remove(this.path);
  }
}

class MemoryFirestoreTransaction implements DurableFirestoreTransaction {
  private readonly staged = new Map<string, Record<string, unknown> | undefined>();

  constructor(private readonly firestore: MemoryFirestore) {}

  async get(ref: DurableFirestoreDocumentRef): Promise<DurableFirestoreDocumentSnapshot> {
    if (this.staged.has(ref.path)) {
      return new MemoryFirestoreSnapshot(this.staged.get(ref.path));
    }
    return new MemoryFirestoreSnapshot(this.firestore.read(ref.path));
  }

  set(
    ref: DurableFirestoreDocumentRef,
    data: Record<string, unknown>,
    options?: { merge?: boolean },
  ): DurableFirestoreTransaction {
    const previous = options?.merge === true
      ? this.staged.get(ref.path) ?? this.firestore.read(ref.path) ?? {}
      : {};
    this.staged.set(ref.path, { ...previous, ...cloneRecord(data) });
    return this;
  }

  update(
    ref: DurableFirestoreDocumentRef,
    data: Record<string, unknown>,
  ): DurableFirestoreTransaction {
    return this.set(ref, data, { merge: true });
  }

  delete(ref: DurableFirestoreDocumentRef): DurableFirestoreTransaction {
    this.staged.set(ref.path, undefined);
    return this;
  }

  commit(): void {
    for (const [path, data] of this.staged) {
      if (data === undefined) {
        this.firestore.remove(path);
      } else {
        this.firestore.write(path, data, false);
      }
    }
  }
}

class MemoryFirestore implements DurableFirestoreLike {
  readonly documents = new Map<string, Record<string, unknown>>();

  doc(path: string): DurableFirestoreDocumentRef {
    return new MemoryFirestoreDocumentRef(this, path);
  }

  async runTransaction<T>(
    updateFunction: (transaction: DurableFirestoreTransaction) => Promise<T>,
  ): Promise<T> {
    const transaction = new MemoryFirestoreTransaction(this);
    const result = await updateFunction(transaction);
    transaction.commit();
    return result;
  }

  seed(path: string, data: Record<string, unknown>): void {
    this.write(path, data, false);
  }

  read(path: string): Record<string, unknown> | undefined {
    return cloneRecord(this.documents.get(path));
  }

  write(path: string, data: Record<string, unknown>, merge: boolean): void {
    const previous = merge ? this.documents.get(path) ?? {} : {};
    this.documents.set(path, { ...previous, ...cloneRecord(data) });
  }

  remove(path: string): void {
    this.documents.delete(path);
  }

  findByPrefix(prefix: string): Array<Record<string, unknown>> {
    return [...this.documents.entries()]
      .filter(([path]) => path.startsWith(prefix))
      .map(([, data]) => cloneRecord(data) ?? {});
  }
}

function seededFirestore(): MemoryFirestore {
  const firestore = new MemoryFirestore();
  firestore.seed('brokerDurableControl/live', {
    breakerOpen: false,
    perSubjectMonthlyCap: 3,
    brokerMonthlyCap: 100,
    oneInFlightPerSubject: true,
  });
  firestore.seed('brokerDurableEntitlements/b3duZXItdWlk', { entitled: true });
  return firestore;
}

function cloneRecord(value: Record<string, unknown> | undefined): Record<string, unknown> | undefined {
  if (value === undefined) {
    return undefined;
  }
  return JSON.parse(JSON.stringify(value)) as Record<string, unknown>;
}

class StaticProvider implements ProviderClient {
  readonly providerName = 'fake-provider';
  readonly modelName = 'fake-local-model';
  readonly reasoningEffort = 'none';
  callCount = 0;

  constructor(private readonly output: BrokerResearchOutput) {}

  async research(_request: BrokerRequest): Promise<ProviderResearchResult> {
    this.callCount += 1;
    return {
      kind: 'success',
      output: this.output,
    };
  }
}

class ThrowingProvider implements ProviderClient {
  readonly providerName = 'fake-provider';
  readonly modelName = 'fake-local-model';
  readonly reasoningEffort = 'none';
  callCount = 0;

  async research(_request: BrokerRequest): Promise<ProviderResearchResult> {
    this.callCount += 1;
    throw new Error('fake provider failure');
  }
}

class SlowProvider implements ProviderClient {
  readonly providerName = 'fake-provider';
  readonly modelName = 'fake-local-model';
  readonly reasoningEffort = 'none';
  callCount = 0;
  private releaseProvider!: () => void;
  readonly release = new Promise<void>((resolve) => {
    this.releaseProvider = resolve;
  });

  async research(_request: BrokerRequest): Promise<ProviderResearchResult> {
    this.callCount += 1;
    await this.release;
    return {
      kind: 'success',
      output: {
        sources: [
          {
            source_id: 'src_slow',
            source_name: 'Slow Fixture',
            source_type: 'museum',
            source_url: 'https://museum.example/research/slow',
            title: 'Slow collection record',
            accessed_at: new Date('2026-07-06T00:00:00.000Z').toISOString(),
            citation_excerpt: 'Slow fixture excerpt.',
            matched_fields: ['title'],
          },
        ],
        candidate_attributions: [
          {
            candidate_id: 'candidate_slow',
            confidence: 'possible',
            match_reason: 'Slow fixture result.',
            field_sources: { title: 'ai_suggested' },
            source_refs: ['src_slow'],
          },
        ],
        comparable_value_signals: [],
        warnings: [],
      },
    };
  }

  resolve(): void {
    this.releaseProvider();
  }
}

test('fake-provider happy path validates, reserves credit, and returns fixture output', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({
    now: () => new Date('2026-07-06T12:00:00.000Z'),
    orderTrace: trace,
  });

  const response = await handleResearchRequest(request(), baseContext, deps);

  assert.equal(response.status, 'completed');
  assert.equal(response.provider, 'fake-provider');
  assert.equal(response.model, 'fake-local-model');
  assert.equal(response.sources.length, 1);
  assert.equal(response.candidate_attributions[0].source_refs[0], response.sources[0].source_id);
  assert.equal(deps.provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assert.equal(deps.creditLedger.finalizeCount, 1);
  assert.equal(deps.creditLedger.spentCreditsFor(baseContext.quota_subject), 1);
  assert.deepEqual(deps.creditLedger.records.map((record) => record.state), ['finalized']);
  assert.deepEqual(trace, [
    'auth',
    'consent',
    'payload_receipt',
    'entitlement',
    'breaker',
    'payload',
    'idempotency',
    'credit_reserve',
    'provider',
    'output_validation',
    'credit_finalize',
  ]);
});

test('unauthenticated request rejects before consent, payload, ledger, or provider work', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({ orderTrace: trace });

  const response = await handleResearchRequest(
    request({ consent_status: 'missing', payload_contract_version: 'old' }),
    { ...baseContext, app_check_verified: false },
    deps,
  );

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'unauthorized');
  assert.equal(response.error?.stage, 'auth');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.records.length, 0);
  assert.deepEqual(trace, ['auth']);
});

test('missing quota subject rejects before consent, payload, ledger, or provider work', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({ orderTrace: trace });

  const response = await handleResearchRequest(
    request({ consent_status: 'missing', payload_contract_version: 'old' }),
    { ...baseContext, quota_subject: '' },
    deps,
  );

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'invalid_quota_subject');
  assert.equal(response.error?.stage, 'auth');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.records.length, 0);
  assert.deepEqual(trace, ['auth']);
});

test('missing consent rejects before provider call and credit reserve', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({ orderTrace: trace });

  const response = await handleResearchRequest(
    request({ consent_status: 'missing' }),
    baseContext,
    deps,
  );

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'consent_required');
  assert.equal(response.error?.stage, 'consent');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.reserveCount, 0);
  assert.equal(deps.creditLedger.records.length, 0);
  assert.deepEqual(trace, ['auth', 'consent']);
});

test('stale consent rejects before provider call and credit reserve', async () => {
  const deps = createFakeBrokerDependencies();

  const response = await handleResearchRequest(
    request({ consent_copy_version: 'research-consent-v0' }),
    baseContext,
    deps,
  );

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'stale_consent');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.reserveCount, 0);
  assert.equal(deps.creditLedger.records.length, 0);
});

test('entitlement and credit-denied gates reject before provider call or credit reserve', async () => {
  const cases: Array<{
    name: string;
    context: BrokerContext;
  }> = [
    {
      name: 'entitlement denied',
      context: { ...baseContext, entitled: false },
    },
    {
      name: 'credit denied',
      context: { ...baseContext, credit_available: false },
    },
  ];

  for (const current of cases) {
    await test(current.name, async () => {
      const trace: string[] = [];
      const deps = createFakeBrokerDependencies({ orderTrace: trace });

      const response = await handleResearchRequest(request(), current.context, deps);

      assert.equal(response.status, 'rejected');
      assert.equal(response.error?.code, 'entitlement_or_credit_denied');
      assert.equal(response.error?.stage, 'entitlement');
      assert.equal(deps.provider.callCount, 0);
      assert.equal(deps.creditLedger.reserveCount, 0);
      assert.equal(deps.creditLedger.finalizeCount, 0);
      assert.equal(deps.creditLedger.records.length, 0);
      assert.deepEqual(trace, ['auth', 'consent', 'payload_receipt', 'entitlement']);
    });
  }
});

test('breaker-open gate rejects before provider call or credit reserve', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({ orderTrace: trace });

  const response = await handleResearchRequest(
    request(),
    { ...baseContext, breaker_open: true },
    deps,
  );

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'broker_breaker_open');
  assert.equal(response.error?.stage, 'breaker');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.reserveCount, 0);
  assert.equal(deps.creditLedger.finalizeCount, 0);
  assert.equal(deps.creditLedger.records.length, 0);
  assert.deepEqual(trace, ['auth', 'consent', 'payload_receipt', 'entitlement', 'breaker']);
});

test('stale payload contract rejects before entitlement, credit reserve, or provider call', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({ orderTrace: trace });

  const response = await handleResearchRequest(
    request({ payload_contract_version: 'art-research-payload-v0' }),
    { ...baseContext, entitled: false, credit_available: false, breaker_open: true },
    deps,
  );

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'payload_contract_mismatch');
  assert.equal(response.error?.stage, 'payload_receipt');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.reserveCount, 0);
  assert.equal(deps.creditLedger.records.length, 0);
  assert.deepEqual(trace, ['auth', 'consent', 'payload_receipt']);
});

test('malformed payload receipt rejects before entitlement, credit reserve, or provider call', async () => {
  const cases: Array<[string, Partial<BrokerRequest>, string]> = [
    ['invalid request id', { request_id: 'not-a-uuid' }, 'invalid_request_id'],
    ['invalid payload hash', { payload_hash: 'not-a-sha-256-hex-digest' }, 'invalid_payload_hash'],
    ['invalid payload class', { approved_payload_class: 'raw_notes' }, 'payload_class_mismatch'],
  ];

  for (const [name, overrides, expectedCode] of cases) {
    await test(name, async () => {
      const trace: string[] = [];
      const deps = createFakeBrokerDependencies({ orderTrace: trace });

      const response = await handleResearchRequest(
        request(overrides),
        { ...baseContext, entitled: false, credit_available: false, breaker_open: true },
        deps,
      );

      assert.equal(response.status, 'rejected');
      assert.equal(response.error?.code, expectedCode);
      assert.equal(response.error?.stage, 'payload_receipt');
      assert.equal(deps.provider.callCount, 0);
      assert.equal(deps.creditLedger.reserveCount, 0);
      assert.equal(deps.creditLedger.records.length, 0);
      assert.deepEqual(trace, ['auth', 'consent', 'payload_receipt']);
    });
  }
});

test('malformed payload body rejects before credit reserve or provider call', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({ orderTrace: trace });

  const response = await handleResearchRequest(
    request({ image: { mime_type: 'image/jpeg', byte_size: 1_500_001, long_edge_px: 1400 } }),
    baseContext,
    deps,
  );

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'invalid_image_size');
  assert.equal(response.error?.stage, 'payload');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.records.length, 0);
  assert.deepEqual(trace, ['auth', 'consent', 'payload_receipt', 'entitlement', 'breaker', 'payload']);
});

test('unsupported image MIME type rejects before credit reserve or provider call', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({ orderTrace: trace });

  const response = await handleResearchRequest(
    request({
      image: {
        mime_type: 'image/png' as BrokerRequest['image']['mime_type'],
        byte_size: 120_000,
        long_edge_px: 1400,
      },
    }),
    baseContext,
    deps,
  );

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'unsupported_image_mime_type');
  assert.equal(response.error?.stage, 'payload');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.records.length, 0);
  assert.deepEqual(trace, ['auth', 'consent', 'payload_receipt', 'entitlement', 'breaker', 'payload']);
});

test('same request id with a changed payload hash returns conflict without another provider call', async () => {
  const deps = createFakeBrokerDependencies();
  const first = await handleResearchRequest(request(), baseContext, deps);
  const second = await handleResearchRequest(
    request({ payload_hash: 'b'.repeat(64) }),
    baseContext,
    deps,
  );

  assert.equal(first.status, 'completed');
  assert.equal(second.status, 'conflict');
  assert.equal(second.error?.code, 'idempotency_conflict');
  assert.equal(deps.provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assert.equal(deps.creditLedger.finalizeCount, 1);
});

test('same request id and same payload hash replays without another provider call or debit', async () => {
  const deps = createFakeBrokerDependencies();
  await handleResearchRequest(request(), baseContext, deps);

  const replay = await handleResearchRequest(request(), baseContext, deps);

  assert.equal(replay.status, 'completed');
  assert.equal(replay.replayed, true);
  assert.equal(deps.provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assert.equal(deps.creditLedger.finalizeCount, 1);
  assert.equal(deps.creditLedger.spentCreditsFor(baseContext.quota_subject), 1);
});

test('concurrent same request id and payload hash shares one in-flight provider call and debit', async () => {
  const provider = new SlowProvider();
  const deps = createFakeBrokerDependencies({ provider });

  const first = handleResearchRequest(request(), baseContext, deps);
  const second = handleResearchRequest(request(), baseContext, deps);
  provider.resolve();

  const [firstResponse, secondResponse] = await Promise.all([first, second]);

  assert.equal(firstResponse.status, 'completed');
  assert.equal(secondResponse.status, 'completed');
  assert.equal(secondResponse.replayed, true);
  assert.equal(provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assert.equal(deps.creditLedger.finalizeCount, 1);
  assert.equal(deps.creditLedger.spentCreditsFor(baseContext.quota_subject), 1);
});

test('concurrent distinct requests under subject cap reserve only one in-flight credit', async () => {
  const provider = new SlowProvider();
  const deps = createFakeBrokerDependencies({
    provider,
    creditLedger: new PlaceholderCreditLedger({ perSubjectMonthlyCap: 1, brokerMonthlyCap: 100 }),
  });

  const first = handleResearchRequest(request(), baseContext, deps);
  const second = await handleResearchRequest(
    request({
      request_id: '22222222-2222-4222-8222-222222222222',
      payload_hash: 'b'.repeat(64),
    }),
    baseContext,
    deps,
  );
  provider.resolve();
  const firstResponse = await first;

  assert.equal(firstResponse.status, 'completed');
  assert.equal(second.status, 'rejected');
  assert.equal(second.error?.code, 'quota_subject_monthly_cap_exceeded');
  assert.equal(second.error?.stage, 'credit_reserve');
  assert.equal(provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assert.equal(deps.creditLedger.finalizeCount, 1);
  assert.equal(deps.creditLedger.exposedCreditsFor(baseContext.quota_subject), 1);
  assert.deepEqual(deps.creditLedger.records.map((record) => record.state), [
    'finalized',
    'rejected-before-reserve',
  ]);
});

test('concurrent distinct requests under broker cap reserve only one in-flight credit', async () => {
  const provider = new SlowProvider();
  const deps = createFakeBrokerDependencies({
    provider,
    creditLedger: new PlaceholderCreditLedger({ perSubjectMonthlyCap: 100, brokerMonthlyCap: 1 }),
  });

  const first = handleResearchRequest(request(), baseContext, deps);
  const second = await handleResearchRequest(
    request({
      request_id: '22222222-2222-4222-8222-222222222222',
      payload_hash: 'b'.repeat(64),
    }),
    { ...baseContext, quota_subject: 'quota_subject_v1_bbbbbbbbbbbbbbbb' },
    deps,
  );
  provider.resolve();
  const firstResponse = await first;

  assert.equal(firstResponse.status, 'completed');
  assert.equal(second.status, 'rejected');
  assert.equal(second.error?.code, 'broker_monthly_cap_exceeded');
  assert.equal(second.error?.stage, 'credit_reserve');
  assert.equal(provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assert.equal(deps.creditLedger.finalizeCount, 1);
  assert.equal(deps.creditLedger.exposedCredits, 1);
  assert.deepEqual(deps.creditLedger.records.map((record) => record.state), [
    'finalized',
    'rejected-before-reserve',
  ]);
});

test('provider output validation failure finalizes the reservation and counts spend', async () => {
  const deps = createFakeBrokerDependencies({
    provider: new StaticProvider(invalidOutput()),
  });

  const response = await handleResearchRequest(request(), baseContext, deps);

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'invalid_source_url');
  assert.equal(response.error?.stage, 'output_validation');
  assert.equal(deps.provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assert.equal(deps.creditLedger.finalizeCount, 1);
  assert.equal(deps.creditLedger.refundCount, 0);
  assert.deepEqual(deps.creditLedger.records.map((record) => record.state), ['finalized']);
  assert.equal(deps.creditLedger.spentCreditsFor(baseContext.quota_subject), 1);
});

test('provider exception refunds the reserved credit and does not count spend', async () => {
  const deps = createFakeBrokerDependencies({
    provider: new ThrowingProvider(),
  });

  const response = await handleResearchRequest(request(), baseContext, deps);

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'provider_failure');
  assert.equal(response.error?.stage, 'provider');
  assert.equal(deps.provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assert.equal(deps.creditLedger.finalizeCount, 0);
  assert.equal(deps.creditLedger.refundCount, 1);
  assert.deepEqual(deps.creditLedger.records.map((record) => record.state), ['refunded']);
  assert.equal(deps.creditLedger.spentCreditsFor(baseContext.quota_subject), 0);
});

test('per-user monthly cap placeholder fails closed before provider call', async () => {
  const deps = createFakeBrokerDependencies({
    creditLedger: new PlaceholderCreditLedger({ perSubjectMonthlyCap: 0 }),
  });

  const response = await handleResearchRequest(request(), baseContext, deps);

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'quota_subject_monthly_cap_exceeded');
  assert.equal(response.error?.stage, 'credit_reserve');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.reserveCount, 0);
  assert.equal(deps.creditLedger.records[0].state, 'rejected-before-reserve');
});

test('broker monthly cap placeholder fails closed before provider call', async () => {
  const deps = createFakeBrokerDependencies({
    creditLedger: new PlaceholderCreditLedger({ brokerMonthlyCap: 0 }),
  });

  const response = await handleResearchRequest(request(), baseContext, deps);

  assert.equal(response.status, 'rejected');
  assert.equal(response.error?.code, 'broker_monthly_cap_exceeded');
  assert.equal(response.error?.stage, 'credit_reserve');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.reserveCount, 0);
  assert.equal(deps.creditLedger.records[0].state, 'rejected-before-reserve');
});

test('adapter valid request returns fake-provider response envelope', async () => {
  const deps = createFakeBrokerDependencies({
    now: () => new Date('2026-07-06T12:00:00.000Z'),
  });

  const envelope = await handleFakeBrokerAdapterRequest(request(), adapterIdentity(), deps);

  assert.equal(envelope.ok, true);
  assert.equal(envelope.status, 200);
  assert.equal(envelope.body.status, 'completed');
  assert.equal(envelope.body.provider, 'fake-provider');
  assert.equal(envelope.body.model, 'fake-local-model');
  assert.equal(envelope.body.sources.length, 1);
  assert.equal(deps.provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assertSanitizedEnvelope(envelope);
});

test('adapter unauthenticated request rejects before broker, ledger, or provider work', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({ orderTrace: trace });

  const envelope = await handleFakeBrokerAdapterRequest(
    request({ consent_status: 'missing', payload_hash: 'not-a-hash' }),
    adapterIdentity({
      auth: {
        appCheckVerified: false,
        authVerified: false,
      },
    }),
    deps,
  );

  assert.equal(envelope.ok, false);
  assert.equal(envelope.status, 401);
  assert.equal(envelope.body.status, 'rejected');
  assert.equal(envelope.body.error.code, 'unauthorized');
  assert.equal(envelope.body.error.stage, 'auth');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.reserveCount, 0);
  assert.equal(deps.creditLedger.records.length, 0);
  assert.deepEqual(trace, []);
  assertSanitizedEnvelope(envelope);
});

test('adapter missing quota subject rejects before broker, ledger, or provider work', async () => {
  const trace: string[] = [];
  const deps = createFakeBrokerDependencies({ orderTrace: trace });

  const envelope = await handleFakeBrokerAdapterRequest(
    request({ consent_status: 'missing', payload_hash: 'not-a-hash' }),
    adapterIdentity({ quotaSubject: '' }),
    deps,
  );

  assert.equal(envelope.ok, false);
  assert.equal(envelope.status, 401);
  assert.equal(envelope.body.status, 'rejected');
  assert.equal(envelope.body.error.code, 'invalid_quota_subject');
  assert.equal(envelope.body.error.stage, 'auth');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.reserveCount, 0);
  assert.equal(deps.creditLedger.records.length, 0);
  assert.deepEqual(trace, []);
  assertSanitizedEnvelope(envelope);
});

test('adapter validation and quota failures return stable non-2xx envelopes without provider calls', async () => {
  const cases: Array<{
    name: string;
    request: BrokerRequest;
    identity?: FakeBrokerAdapterIdentity;
    dependencies?: ReturnType<typeof createFakeBrokerDependencies>;
    expectedStatus: number;
    expectedCode: string;
    expectedEnvelopeStatus?: 'rejected' | 'conflict';
    expectedLedgerRecords?: number;
  }> = [
    {
      name: 'unsupported MIME',
      request: request({
        image: {
          mime_type: 'image/png' as BrokerRequest['image']['mime_type'],
          byte_size: 120_000,
          long_edge_px: 1400,
        },
      }),
      expectedStatus: 400,
      expectedCode: 'unsupported_image_mime_type',
    },
    {
      name: 'stale consent',
      request: request({ consent_copy_version: 'research-consent-v0' }),
      expectedStatus: 403,
      expectedCode: 'stale_consent',
    },
    {
      name: 'bad payload hash',
      request: request({ payload_hash: 'not-a-sha-256-hex-digest' }),
      expectedStatus: 400,
      expectedCode: 'invalid_payload_hash',
    },
    {
      name: 'cap exceeded',
      request: request(),
      dependencies: createFakeBrokerDependencies({
        creditLedger: new PlaceholderCreditLedger({ perSubjectMonthlyCap: 0 }),
      }),
      expectedStatus: 429,
      expectedCode: 'quota_subject_monthly_cap_exceeded',
      expectedLedgerRecords: 1,
    },
  ];

  for (const current of cases) {
    const deps = current.dependencies ?? createFakeBrokerDependencies();

    const envelope = await handleFakeBrokerAdapterRequest(
      current.request,
      current.identity ?? adapterIdentity(),
      deps,
    );

    assert.equal(envelope.ok, false, current.name);
    assert.equal(envelope.status, current.expectedStatus, current.name);
    assert.equal(envelope.body.status, current.expectedEnvelopeStatus ?? 'rejected', current.name);
    assert.equal(envelope.body.provider, 'fake-provider', current.name);
    assert.equal(envelope.body.error.code, current.expectedCode, current.name);
    assert.equal(deps.provider.callCount, 0, current.name);
    assert.equal(deps.creditLedger.reserveCount, 0, current.name);
    assert.equal(deps.creditLedger.records.length, current.expectedLedgerRecords ?? 0, current.name);
    assertSanitizedEnvelope(envelope);
  }
});

test('adapter idempotency conflict returns stable conflict without another provider call or debit', async () => {
  const deps = createFakeBrokerDependencies();
  const first = await handleFakeBrokerAdapterRequest(request(), adapterIdentity(), deps);
  const conflict = await handleFakeBrokerAdapterRequest(
    request({ payload_hash: 'b'.repeat(64) }),
    adapterIdentity(),
    deps,
  );

  assert.equal(first.ok, true);
  assert.equal(conflict.ok, false);
  assert.equal(conflict.status, 409);
  assert.equal(conflict.body.status, 'conflict');
  assert.equal(conflict.body.error.code, 'idempotency_conflict');
  assert.equal(deps.provider.callCount, 1);
  assert.equal(deps.creditLedger.reserveCount, 1);
  assert.equal(deps.creditLedger.finalizeCount, 1);
  assertSanitizedEnvelope(conflict);
});

test('adapter rejects malformed callable payload without leaking raw notes or internals', async () => {
  const deps = createFakeBrokerDependencies();
  const envelope = await handleFakeBrokerAdapterRequest(
    {
      request_id: '11111111-1111-4111-8111-111111111111',
      raw_notes: 'raw private collector notes',
      provider_key: 'OPENAI_API_KEY',
      image: { mime_type: 'image/jpeg', byte_size: 120_000, long_edge_px: 1400 },
    },
    adapterIdentity(),
    deps,
  );

  assert.equal(envelope.ok, false);
  assert.equal(envelope.status, 400);
  assert.equal(envelope.body.status, 'rejected');
  assert.equal(envelope.body.error.code, 'invalid_request_payload');
  assert.equal(envelope.body.error.stage, 'adapter');
  assert.equal(deps.provider.callCount, 0);
  assert.equal(deps.creditLedger.reserveCount, 0);
  assertSanitizedEnvelope(envelope);
});

test('openai provider sends a Responses API request with store=false, required web search, and strict schema', async () => {
  const fetchCalls: Array<{ url: string; body: Record<string, unknown> }> = [];
  const provider = createOpenAiProvider({
    apiKey: 'test-openai-key',
    allowedDomains: ['museum.example'],
    fetchImpl: (async (url, init) => {
      fetchCalls.push({
        url: String(url),
        body: JSON.parse(String(init?.body)) as Record<string, unknown>,
      });
      return {
        ok: true,
        status: 200,
        json: async () => ({
          output: [
            {
              type: 'web_search_call',
              action: {
                sources: [{ url: 'https://museum.example/works/123' }],
              },
            },
            {
              type: 'message',
              content: [
                {
                  type: 'output_text',
                  text: JSON.stringify({
                    sources: [
                      {
                        source_id: 'src_1',
                        source_name: 'Museum Example',
                        source_type: 'museum',
                        source_url: 'https://museum.example/works/123',
                        title: 'Collection record',
                        accessed_at: '2026-07-08T16:00:00.000Z',
                        citation_excerpt: 'Collection record excerpt.',
                        matched_fields: ['title'],
                      },
                    ],
                    candidate_attributions: [
                      {
                        candidate_id: 'cand_1',
                        confidence: 'likely',
                        match_reason: 'Source-backed match.',
                        title: 'Untitled',
                        artist: 'Unknown',
                        field_sources: { title: 'ai_suggested' },
                        source_refs: ['src_1'],
                      },
                    ],
                    comparable_value_signals: [
                      {
                        kind: 'no_reliable_comparable',
                        label: 'No reliable comparable found',
                        source_refs: [],
                        caveat: 'Do not infer market value.',
                      },
                    ],
                    warnings: ['needs_human_confirmation'],
                  }),
                  annotations: [
                    {
                      type: 'url_citation',
                      url_citation: {
                        url: 'https://museum.example/works/123',
                        title: 'Collection record',
                      },
                    },
                  ],
                },
              ],
            },
          ],
        }),
      } as Response;
    }) as typeof fetch,
  });

  const brokerRequest = request({
    image: {
      mime_type: 'image/jpeg',
      byte_size: 120_000,
      long_edge_px: 1400,
      content_base64: 'ZmFrZS1pbWFnZS1ieXRlcw==',
    },
  });
  authorizeProviderRequest(brokerRequest);
  const result = await provider.research(brokerRequest);

  assert.equal(result.kind, 'success');
  assert.equal(result.output.sources[0]?.source_url, 'https://museum.example/works/123');
  assert.equal(fetchCalls.length, 1);
  assert.equal(fetchCalls[0]?.url, 'https://api.openai.com/v1/responses');

  const body = fetchCalls[0]?.body ?? {};
  const serialized = JSON.stringify(body);
  assert.equal(body.store, false);
  assert.deepEqual(body.reasoning, { effort: 'high' });
  assert.equal(body.tool_choice, 'required');
  assert.deepEqual(body.include, ['web_search_call.action.sources']);
  assert.equal(Array.isArray(body.tools), true);
  assert.deepEqual(
    (body.tools as Array<Record<string, unknown>>)[0],
    {
      type: 'web_search',
      filters: { allowed_domains: ['museum.example'] },
      search_context_size: 'medium',
      external_web_access: false,
    },
  );
  assert.equal(
    ((body.text as Record<string, unknown>).format as Record<string, unknown>).type,
    'json_schema',
  );
  assert.equal(
    ((body.text as Record<string, unknown>).format as Record<string, unknown>).strict,
    true,
  );
  assert.equal(serialized.includes('"response_format"'), false);
  assert.equal(serialized.includes('artworkId'), false);
  assert.equal(serialized.includes('consentSummary'), false);
  assert.equal(serialized.includes('querySummary'), false);
  assert.equal(serialized.includes('raw_notes'), false);
  assert.equal(serialized.includes('previous_response_id'), false);
  assert.equal(serialized.includes('file_search'), false);
  assert.equal(serialized.includes('store":false'), true);
  assert.equal(serialized.includes('data:image/jpeg;base64,ZmFrZS1pbWFnZS1ieXRlcw=='), true);
});

test('openai provider rejects ungrounded or non-allowlisted sources as invalid output', async () => {
  const provider = createOpenAiProvider({
    apiKey: 'test-openai-key',
    allowedDomains: ['museum.example'],
    fetchImpl: (async () => ({
      ok: true,
      status: 200,
      json: async () => ({
        output: [
          {
            type: 'message',
            content: [
              {
                type: 'output_text',
                text: JSON.stringify({
                  sources: [
                    {
                      source_id: 'src_1',
                      source_name: 'Bad Source',
                      source_type: 'museum',
                      source_url: 'https://example.net/not-allowlisted',
                      title: 'Bad source',
                      accessed_at: '2026-07-08T16:00:00.000Z',
                      citation_excerpt: 'Bad source excerpt.',
                      matched_fields: ['title'],
                    },
                  ],
                  candidate_attributions: [],
                  comparable_value_signals: [],
                  warnings: [],
                }),
                annotations: [],
              },
            ],
          },
        ],
      }),
    }) as Response) as typeof fetch,
  });

  const brokerRequest = request();
  authorizeProviderRequest(brokerRequest);
  const result = await provider.research(brokerRequest);

  assert.equal(result.kind, 'output_error');
  assert.equal(result.code, 'provider_output_invalid');
});

test('package public API does not expose direct OpenAI provider execution', async () => {
  const packageApi = await import('../src/index.js');

  assert.equal('createOpenAiProvider' in packageApi, false);
});

test('direct OpenAI provider call without broker authorization cannot reach fetch', async () => {
  let fetchCallCount = 0;
  const provider = createOpenAiProvider({
    apiKey: 'test-openai-key',
    allowedDomains: ['museum.example'],
    fetchImpl: (async () => {
      fetchCallCount += 1;
      throw new Error('fetch should not be reached');
    }) as typeof fetch,
  });

  const result = await provider.research(request({
    consent_status: 'declined',
    consent_copy_version: 'research-consent-v0',
  }));

  assert.equal(result.kind, 'output_error');
  assert.equal(result.code, 'broker_authorization_required');
  assert.equal(fetchCallCount, 0);
  assert.equal(provider.callCount, 0);
});

test('disabled live gate returns a safe 503 before any OpenAI config lookup', async () => {
  let configLookupCount = 0;
  const configured = createConfiguredResearchBrokerDependencies(
    {
      BROKER_HTTP_ENABLED: 'false',
      BROKER_PROVIDER_MODE: 'openai',
      BROKER_OPENAI_LIVE_TEST_ENABLED: 'true',
      OPENAI_API_KEY: 'should-not-be-read',
    },
    {},
    () => {
      configLookupCount += 1;
      return {
        ok: false,
        code: 'missing_openai_api_key',
        message: 'should not be reached',
      };
    },
  );

  assert.equal(configured.kind, 'disabled');
  assert.equal(configLookupCount, 0);

  const handler = createResearchBrokerHttpHandler({
    env: {
      BROKER_HTTP_ENABLED: 'false',
      BROKER_PROVIDER_MODE: 'openai',
      BROKER_OPENAI_LIVE_TEST_ENABLED: 'true',
    },
    dependenciesFactory: () => ({ kind: 'disabled' }),
  });
  const response = createHttpResponse();
  await handler(createHttpRequest({ data: request() }), response.responder);

  assert.equal(response.statusCode, 503);
  assert.deepEqual(response.json, { ok: false, error: 'research_broker_disabled' });
});

test('enabled live config fails closed before OpenAI config lookup without durable protection', async () => {
  let configLookupCount = 0;
  const configured = createConfiguredResearchBrokerDependencies(
    durableEnv(),
    {},
    () => {
      configLookupCount += 1;
      return {
        ok: false,
        code: 'missing_openai_api_key',
        message: 'should not be reached',
      };
    },
  );

  assert.deepEqual(configured, {
    kind: 'misconfigured',
    code: 'durable_protection_unavailable',
  });
  assert.equal(configLookupCount, 0);
});

test('enabled live config fails closed before OpenAI config lookup without durable env config', async () => {
  let configLookupCount = 0;
  const configured = createConfiguredResearchBrokerDependencies(
    durableEnv({ BROKER_DURABLE_STORE_CONFIGURED: undefined }),
    {},
    () => {
      configLookupCount += 1;
      return {
        ok: false,
        code: 'missing_openai_api_key',
        message: 'should not be reached',
      };
    },
    createFakeDurableProtection(),
  );

  assert.deepEqual(configured, {
    kind: 'misconfigured',
    code: 'missing_durable_broker_config',
  });
  assert.equal(configLookupCount, 0);
});

test('enabled live config fails closed before OpenAI config lookup without quota secret', async () => {
  let configLookupCount = 0;
  const configured = createConfiguredResearchBrokerDependencies(
    durableEnv({ BROKER_QUOTA_HMAC_SECRET: undefined }),
    {},
    () => {
      configLookupCount += 1;
      return {
        ok: false,
        code: 'missing_openai_api_key',
        message: 'should not be reached',
      };
    },
    createFakeDurableProtection(),
  );

  assert.deepEqual(configured, {
    kind: 'misconfigured',
    code: 'missing_quota_hmac_secret',
  });
  assert.equal(configLookupCount, 0);
});

test('enabled live config fails closed before OpenAI config lookup without Firebase project number', async () => {
  let configLookupCount = 0;
  const configured = createConfiguredResearchBrokerDependencies(
    durableEnv({ BROKER_FIREBASE_PROJECT_NUMBER: undefined }),
    {},
    () => {
      configLookupCount += 1;
      return {
        ok: false,
        code: 'missing_openai_api_key',
        message: 'should not be reached',
      };
    },
    createFakeDurableProtection(),
  );

  assert.deepEqual(configured, {
    kind: 'misconfigured',
    code: 'missing_durable_broker_config',
  });
  assert.equal(configLookupCount, 0);
});

test('firebase admin verifier abstraction requires revoked Auth check and matching App Check project', async () => {
  let checkRevokedValue: boolean | undefined;
  const verifier = new FirebaseAdminBrokerTokenVerifier({
    auth: {
      async verifyIdToken(token, checkRevoked) {
        checkRevokedValue = checkRevoked;
        assert.equal(token, 'owner-auth-token');
        return {
          uid: 'owner-uid',
          aud: 'broker-project',
          iss: 'https://securetoken.google.com/broker-project',
          firebase: { sign_in_provider: 'anonymous' },
        };
      },
    },
    appCheck: {
      async verifyToken(token) {
        assert.equal(token, 'owner-app-check-token');
        return {
          appId: 'owner-test-app',
          aud: ['123456789', 'broker-project'],
          iss: 'https://firebaseappcheck.googleapis.com/123456789',
        };
      },
    },
    config: {
      projectId: 'broker-project',
      projectNumber: '123456789',
      allowedAppIds: new Set(['owner-test-app']),
    },
  });

  const verified = await verifier.verify({
    authorizationHeader: 'Bearer owner-auth-token',
    appCheckToken: 'owner-app-check-token',
  });

  assert.equal(verified.ok, true);
  assert.equal(checkRevokedValue, true);
  if (verified.ok) {
    assert.equal(verified.auth.uid, 'owner-uid');
    assert.equal(verified.auth.projectId, 'broker-project');
    assert.equal(verified.app.appId, 'owner-test-app');
  }

  const wrongProjectVerifier = new FirebaseAdminBrokerTokenVerifier({
    auth: {
      async verifyIdToken() {
        return {
          uid: 'owner-uid',
          aud: 'broker-project',
          iss: 'https://securetoken.google.com/broker-project',
          firebase: { sign_in_provider: 'anonymous' },
        };
      },
    },
    appCheck: {
      async verifyToken() {
        return {
          appId: 'owner-test-app',
          aud: ['999999999', 'wrong-project'],
          iss: 'https://firebaseappcheck.googleapis.com/999999999',
        };
      },
    },
    config: {
      projectId: 'broker-project',
      projectNumber: '123456789',
      allowedAppIds: new Set(['owner-test-app']),
    },
  });

  const rejected = await wrongProjectVerifier.verify({
    authorizationHeader: 'Bearer owner-auth-token',
    appCheckToken: 'owner-app-check-token',
  });

  assert.deepEqual(rejected, { ok: false, code: 'invalid_app_check_token' });

  const wrongIssuerVerifier = new FirebaseAdminBrokerTokenVerifier({
    auth: {
      async verifyIdToken() {
        return {
          uid: 'owner-uid',
          aud: 'broker-project',
          iss: 'https://securetoken.google.com/broker-project',
          firebase: { sign_in_provider: 'anonymous' },
        };
      },
    },
    appCheck: {
      async verifyToken() {
        return {
          appId: 'owner-test-app',
          aud: ['123456789', 'broker-project'],
          iss: 'https://firebaseappcheck.googleapis.com/999999999',
        };
      },
    },
    config: {
      projectId: 'broker-project',
      projectNumber: '123456789',
      allowedAppIds: new Set(['owner-test-app']),
    },
  });

  assert.deepEqual(
    await wrongIssuerVerifier.verify({
      authorizationHeader: 'Bearer owner-auth-token',
      appCheckToken: 'owner-app-check-token',
    }),
    { ok: false, code: 'invalid_app_check_token' },
  );
});

test('wrong App Check issuer rejects before provider config lookup', async () => {
  let configLookupCount = 0;
  const protectionResult = createFirebaseAdminDurableBrokerProtection({
    env: durableEnv(),
    auth: fakeFirebaseAuth(),
    appCheck: fakeFirebaseAppCheck({
      iss: 'https://firebaseappcheck.googleapis.com/999999999',
    }),
    firestore: seededFirestore(),
  });
  assert.equal(protectionResult.ok, true);
  if (!protectionResult.ok) {
    return;
  }

  const handler = createResearchBrokerHttpHandler({
    env: durableEnv(),
    dependenciesFactory: () => liveDependenciesFactory({
      protection: protectionResult.protection,
      configLookup: () => {
        configLookupCount += 1;
      },
    }),
  });
  const response = createHttpResponse();

  await handler(createHttpRequest({ data: request() }), response.responder);

  assert.equal(response.statusCode, 401);
  assert.deepEqual(response.json, { ok: false, error: 'unauthorized' });
  assert.equal(configLookupCount, 0);
});

test('firebase live dependency factory wires concrete durable Firestore protection when configured', async () => {
  const configured = createFirebaseResearchBrokerDependencies(
    durableEnv(),
    {
      auth: fakeFirebaseAuth(),
      appCheck: fakeFirebaseAppCheck(),
      firestore: seededFirestore(),
    },
  );

  assert.equal(configured.kind, 'ready');
  if (configured.kind !== 'ready') {
    return;
  }
  assert.equal(configured.durableProtection, true);
  assert.equal(
    configured.protection.createIdempotencyStore().constructor.name,
    'FirestoreDurableIdempotencyStore',
  );
  assert.equal(
    configured.protection.createCreditLedger().constructor.name,
    'FirestoreDurableCreditLedger',
  );
});

test('firebase live dependency factory fails closed when project number is missing', async () => {
  let authCalls = 0;
  const configured = createFirebaseResearchBrokerDependencies(
    durableEnv({ BROKER_FIREBASE_PROJECT_NUMBER: undefined }),
    {
      auth: {
        async verifyIdToken() {
          authCalls += 1;
          throw new Error('should not verify tokens');
        },
      },
      appCheck: fakeFirebaseAppCheck(),
      firestore: seededFirestore(),
    },
  );

  assert.deepEqual(configured, {
    kind: 'misconfigured',
    code: 'missing_durable_broker_config',
  });
  assert.equal(authCalls, 0);
});

test('live shell verifies tokens, derives quota subject, and ignores spoofed quota headers', async () => {
  assert.equal(isResearchBrokerLiveEnabled({}), false);
  assert.equal(
    isResearchBrokerLiveEnabled({
      BROKER_HTTP_ENABLED: 'true',
      BROKER_PROVIDER_MODE: 'openai',
      BROKER_OPENAI_LIVE_TEST_ENABLED: 'true',
    }),
    true,
  );

  const provider = new StaticProvider({
    sources: [
      {
        source_id: 'src_live',
        source_name: 'Museum Example',
        source_type: 'museum',
        source_url: 'https://museum.example/works/123',
        title: 'Collection record',
        accessed_at: '2026-07-08T16:00:00.000Z',
        citation_excerpt: 'Collection record excerpt.',
        matched_fields: ['title'],
      },
    ],
    candidate_attributions: [],
    comparable_value_signals: [],
    warnings: [],
  });
  const store = new FakeDurableBrokerStore({ entitledUids: ['owner-uid'] });

  const handler = createResearchBrokerHttpHandler({
    env: durableEnv(),
    dependenciesFactory: () => liveDependenciesFactory({ store, provider }),
  });

  const deniedResponse = createHttpResponse();
  await handler(
    createHttpRequest({ data: request() }, { authorization: 'Bearer invalid-auth-token' }),
    deniedResponse.responder,
  );
  assert.equal(deniedResponse.statusCode, 401);
  assert.deepEqual(deniedResponse.json, { ok: false, error: 'unauthorized' });
  assert.equal(provider.callCount, 0);
  assert.equal(store.reserveCount, 0);

  const allowedResponse = createHttpResponse();
  await handler(
    createHttpRequest(
      { data: request() },
      { 'x-archivale-broker-quota-subject': 'quota_subject_v1_client_spoofed' },
    ),
    allowedResponse.responder,
  );

  assert.equal(allowedResponse.statusCode, 200);
  assert.equal(allowedResponse.json.status, 'completed');
  assert.equal(provider.callCount, 1);
  assert.equal(store.reserveCount, 1);
  assert.equal(
    store.ledgerRecords[0]?.quotaSubject,
    deriveQuotaSubject({
      uid: 'owner-uid',
      appId: 'owner-test-app',
      projectId: 'broker-project',
      secret: 'test-only-quota-hmac-secret',
    }),
  );
  assert.notEqual(store.ledgerRecords[0]?.quotaSubject, 'quota_subject_v1_client_spoofed');
});

test('live durable duplicate across dependency instances yields one provider execution and one debit', async () => {
  const provider = new SlowProvider();
  const store = new FakeDurableBrokerStore({ entitledUids: ['owner-uid'] });
  const handlerA = createResearchBrokerHttpHandler({
    env: durableEnv(),
    dependenciesFactory: () => liveDependenciesFactory({ store, provider }),
  });
  const handlerB = createResearchBrokerHttpHandler({
    env: durableEnv(),
    dependenciesFactory: () => liveDependenciesFactory({ store, provider }),
  });

  const firstResponse = createHttpResponse();
  const secondResponse = createHttpResponse();
  const first = handlerA(createHttpRequest({ data: request() }), firstResponse.responder);
  const second = handlerB(createHttpRequest({ data: request() }), secondResponse.responder);
  provider.resolve();
  await Promise.all([first, second]);

  assert.equal(firstResponse.statusCode, 200);
  assert.equal(secondResponse.statusCode, 200);
  assert.equal(secondResponse.json.replayed, true);
  assert.equal(provider.callCount, 1);
  assert.equal(store.reserveCount, 1);
  assert.equal(store.finalizeCount, 1);
});

test('live durable duplicate across instances uses concrete Firestore adapter once', async () => {
  const provider = new StaticProvider({
    sources: [
      {
        source_id: 'src_live_firestore_duplicate',
        source_name: 'Museum Example',
        source_type: 'museum',
        source_url: 'https://museum.example/works/firestore-duplicate',
        title: 'Collection record',
        accessed_at: '2026-07-08T16:00:00.000Z',
        citation_excerpt: 'Collection record excerpt.',
        matched_fields: ['title'],
      },
    ],
    candidate_attributions: [],
    comparable_value_signals: [],
    warnings: [],
  });
  const firestore = seededFirestore();
  const protectionResult = createFirebaseAdminDurableBrokerProtection({
    env: durableEnv(),
    auth: fakeFirebaseAuth(),
    appCheck: fakeFirebaseAppCheck(),
    firestore,
  });
  assert.equal(protectionResult.ok, true);
  if (!protectionResult.ok) {
    return;
  }

  const handlerA = createResearchBrokerHttpHandler({
    env: durableEnv(),
    dependenciesFactory: () => liveDependenciesFactory({
      protection: protectionResult.protection,
      provider,
    }),
  });
  const handlerB = createResearchBrokerHttpHandler({
    env: durableEnv(),
    dependenciesFactory: () => liveDependenciesFactory({
      protection: protectionResult.protection,
      provider,
    }),
  });

  const firstResponse = createHttpResponse();
  await handlerA(createHttpRequest({ data: request() }), firstResponse.responder);

  const replayResponse = createHttpResponse();
  await handlerB(createHttpRequest({ data: request() }), replayResponse.responder);

  assert.equal(firstResponse.statusCode, 200);
  assert.equal(replayResponse.statusCode, 200);
  assert.equal(replayResponse.json.replayed, true);
  assert.equal(provider.callCount, 1);
  assert.deepEqual(
    firestore.findByPrefix('brokerDurableLedger/').map((record) => record.state),
    ['finalized'],
  );
  assert.deepEqual(firestore.read('brokerDurableControl/globalUsage'), { exposedCredits: 1 });
});

test('live durable changed payload hash conflicts across instances without provider execution', async () => {
  const provider = new StaticProvider({
    sources: [
      {
        source_id: 'src_live_conflict',
        source_name: 'Museum Example',
        source_type: 'museum',
        source_url: 'https://museum.example/works/conflict',
        title: 'Collection record',
        accessed_at: '2026-07-08T16:00:00.000Z',
        citation_excerpt: 'Collection record excerpt.',
        matched_fields: ['title'],
      },
    ],
    candidate_attributions: [],
    comparable_value_signals: [],
    warnings: [],
  });
  const store = new FakeDurableBrokerStore({ entitledUids: ['owner-uid'] });
  const handlerA = createResearchBrokerHttpHandler({
    env: durableEnv(),
    dependenciesFactory: () => liveDependenciesFactory({ store, provider }),
  });
  const handlerB = createResearchBrokerHttpHandler({
    env: durableEnv(),
    dependenciesFactory: () => liveDependenciesFactory({ store, provider }),
  });

  const firstResponse = createHttpResponse();
  await handlerA(createHttpRequest({ data: request() }), firstResponse.responder);

  const conflictResponse = createHttpResponse();
  await handlerB(
    createHttpRequest({ data: request({ payload_hash: 'b'.repeat(64) }) }),
    conflictResponse.responder,
  );

  assert.equal(firstResponse.statusCode, 200);
  assert.equal(conflictResponse.statusCode, 409);
  assert.equal(conflictResponse.json.status, 'conflict');
  assert.equal(
    ((conflictResponse.json.error as Record<string, unknown>) ?? {}).code,
    'idempotency_conflict',
  );
  assert.equal(provider.callCount, 1);
  assert.equal(store.reserveCount, 1);
  assert.equal(store.finalizeCount, 1);
});

test('live durable distinct in-flight request rejects before a second provider execution', async () => {
  const provider = new SlowProvider();
  const store = new FakeDurableBrokerStore({ entitledUids: ['owner-uid'] });
  const handler = createResearchBrokerHttpHandler({
    env: durableEnv(),
    dependenciesFactory: () => liveDependenciesFactory({ store, provider }),
  });

  const firstResponse = createHttpResponse();
  const secondResponse = createHttpResponse();
  const first = handler(createHttpRequest({ data: request() }), firstResponse.responder);
  await handler(
    createHttpRequest({
      data: request({
        request_id: '22222222-2222-4222-8222-222222222222',
        payload_hash: 'b'.repeat(64),
      }),
    }),
    secondResponse.responder,
  );
  provider.resolve();
  await first;

  assert.equal(firstResponse.statusCode, 200);
  assert.equal(secondResponse.statusCode, 429);
  assert.equal(
    ((secondResponse.json.error as Record<string, unknown>) ?? {}).code,
    'quota_subject_in_flight',
  );
  assert.equal(provider.callCount, 1);
  assert.equal(store.reserveCount, 1);
  assert.equal(store.finalizeCount, 1);
});

test('live durable entitlement, credit, breaker, and token gates reject before provider config', async () => {
  const cases: Array<{
    name: string;
    store?: FakeDurableBrokerStore;
    headers?: Record<string, string | undefined>;
    expectedStatus: number;
    expectedError: string;
  }> = [
    {
      name: 'entitlement denied',
      store: new FakeDurableBrokerStore({ entitledUids: [] }),
      expectedStatus: 403,
      expectedError: 'entitlement_or_credit_denied',
    },
    {
      name: 'credit exhausted',
      store: new FakeDurableBrokerStore({ entitledUids: ['owner-uid'], perSubjectMonthlyCap: 0 }),
      expectedStatus: 403,
      expectedError: 'entitlement_or_credit_denied',
    },
    {
      name: 'breaker open',
      store: new FakeDurableBrokerStore({ entitledUids: ['owner-uid'], breakerOpen: true }),
      expectedStatus: 503,
      expectedError: 'broker_breaker_open',
    },
    {
      name: 'missing auth',
      headers: { authorization: undefined },
      expectedStatus: 401,
      expectedError: 'unauthorized',
    },
    {
      name: 'invalid app check',
      headers: { 'x-firebase-appcheck': 'invalid-app-check-token' },
      expectedStatus: 401,
      expectedError: 'unauthorized',
    },
  ];

  for (const current of cases) {
    let configLookupCount = 0;
    const store = current.store ?? new FakeDurableBrokerStore({ entitledUids: ['owner-uid'] });
    const handler = createResearchBrokerHttpHandler({
      env: durableEnv(),
      dependenciesFactory: () => liveDependenciesFactory({
        store,
        configLookup: () => {
          configLookupCount += 1;
        },
      }),
    });
    const response = createHttpResponse();

    await handler(createHttpRequest({ data: request() }, current.headers), response.responder);

    assert.equal(response.statusCode, current.expectedStatus, current.name);
    assert.deepEqual(response.json, { ok: false, error: current.expectedError }, current.name);
    assert.equal(configLookupCount, 0, current.name);
    assert.equal(store.reserveCount, 0, current.name);
  }
});

test('warm live shell rechecks kill switch before cached provider/config work', async () => {
  const env = durableEnv();
  const provider = new StaticProvider({
    sources: [
      {
        source_id: 'src_warm',
        source_name: 'Museum Example',
        source_type: 'museum',
        source_url: 'https://museum.example/works/warm',
        title: 'Collection record',
        accessed_at: '2026-07-08T16:00:00.000Z',
        citation_excerpt: 'Collection record excerpt.',
        matched_fields: ['title'],
      },
    ],
    candidate_attributions: [],
    comparable_value_signals: [],
    warnings: [],
  });
  const store = new FakeDurableBrokerStore({ entitledUids: ['owner-uid'] });
  let factoryCalls = 0;
  const handler = createResearchBrokerHttpHandler({
    env,
    dependenciesFactory: () => {
      factoryCalls += 1;
      return liveDependenciesFactory({ store, provider });
    },
  });

  const firstResponse = createHttpResponse();
  await handler(createHttpRequest({ data: request() }), firstResponse.responder);

  assert.equal(firstResponse.statusCode, 200);
  assert.equal(firstResponse.json.status, 'completed');
  assert.equal(factoryCalls, 1);
  assert.equal(provider.callCount, 1);
  assert.equal(store.reserveCount, 1);

  env.BROKER_HTTP_ENABLED = 'false';

  const secondResponse = createHttpResponse();
  await handler(
    createHttpRequest({
      data: request({
        request_id: '22222222-2222-4222-8222-222222222222',
        payload_hash: 'b'.repeat(64),
      }),
    }),
    secondResponse.responder,
  );

  assert.equal(secondResponse.statusCode, 503);
  assert.deepEqual(secondResponse.json, { ok: false, error: 'research_broker_disabled' });
  assert.equal(factoryCalls, 1);
  assert.equal(provider.callCount, 1);
  assert.equal(store.reserveCount, 1);
});

test('broker scaffold keeps env lookup server-only and never references local secret files', async () => {
  const brokerSource = await readFile(new URL('../src/broker.js', import.meta.url), 'utf8');
  const fakeProviderSource = await readFile(new URL('../src/fake_provider.js', import.meta.url), 'utf8');
  const adapterSource = await readFile(new URL('../src/adapter.js', import.meta.url), 'utf8');
  const openAiProviderSource = await readFile(new URL('../src/openai_provider.js', import.meta.url), 'utf8');
  const liveBrokerSource = await readFile(new URL('../src/live_broker.js', import.meta.url), 'utf8');
  assert.equal(brokerSource.includes('process.env'), false);
  assert.equal(fakeProviderSource.includes('process.env'), false);
  assert.equal(adapterSource.includes('process.env'), false);
  assert.equal(openAiProviderSource.includes('OPENAI_API_KEY'), true);
  assert.equal(openAiProviderSource.includes('.env.local'), false);
  assert.equal(liveBrokerSource.includes('.env.local'), false);
  assert.equal(liveBrokerSource.includes('google-services.json'), false);
  const deps = createFakeBrokerDependencies();
  const response = await handleResearchRequest(request(), baseContext, deps);

  assert.equal(response.status, 'completed');
  assert.equal(deps.provider.callCount, 1);
});
