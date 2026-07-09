import { Readable } from 'node:stream';

import { canonicalPayloadV1 } from '../src/canonical_payload.js';
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
import type {
  DurableFirestoreDocumentRef,
  DurableFirestoreDocumentSnapshot,
  DurableFirestoreLike,
  DurableFirestoreTransaction,
} from '../src/durable_protection.js';
import type { MinimalResponse } from '../src/live_broker.js';

export const FIXED_NOW = new Date('2026-07-09T12:00:00.000Z');

export const baseContext: BrokerContext = Object.freeze({
  app_check_verified: true,
  auth_verified: true,
  auth_identity: {
    uid: 'anonymous-test-uid',
    project_id: 'my-art-collections',
    sign_in_provider: 'anonymous' as const,
  },
  app_identity: {
    app_id: 'owner-test-app',
    project_id: 'my-art-collections',
  },
  quota_subject: 'quota_subject_v1_aaaaaaaaaaaaaaaa',
  entitled: true,
  breaker_open: false,
});

export function request(overrides: Partial<BrokerRequest> = {}): BrokerRequest {
  const base: BrokerRequest = {
    request_id: '11111111-1111-4111-8111-111111111111',
    consent_status: 'approved',
    consent_scope: 'image_only',
    consent_copy_version: CURRENT_CONSENT_COPY_VERSION,
    payload_contract_version: CURRENT_PAYLOAD_CONTRACT_VERSION,
    payload_hash: '0'.repeat(64),
    approved_payload_class: APPROVED_PAYLOAD_CLASS,
    image: {
      mime_type: 'image/jpeg',
      byte_size: 3,
      long_edge_px: 1600,
      content_base64: 'AQID',
    },
  };
  const merged: BrokerRequest = {
    ...base,
    ...overrides,
    image: overrides.image ?? base.image,
  };
  if (overrides.payload_hash === undefined) {
    merged.payload_hash = canonicalPayloadV1(merged).sha256;
  }
  return merged;
}

export function validOutput(): BrokerResearchOutput {
  return {
    sources: [{
      source_id: 'src_fixture',
      source_name: 'Fixture Museum',
      source_type: 'museum',
      source_url: 'https://museum.example/works/fixture',
      title: 'Fixture record',
      accessed_at: '2026-07-09T00:00:00.000Z',
      citation_excerpt: 'Fixture excerpt.',
      matched_fields: ['title'],
    }],
    candidate_attributions: [{
      candidate_id: 'candidate_fixture',
      confidence: 'possible',
      match_reason: 'Fixture match only.',
      field_sources: { title: 'ai_suggested' },
      source_refs: ['src_fixture'],
    }],
    comparable_value_signals: [],
    warnings: [],
  };
}

export class ResultProvider implements ProviderClient {
  readonly providerName = 'fake-provider';
  readonly modelName = 'fake-local-model';
  readonly reasoningEffort = 'none';
  callCount = 0;
  private releaseProvider?: () => void;
  private wait?: Promise<void>;

  constructor(readonly result: ProviderResearchResult = { kind: 'success', output: validOutput() }) {}

  makeSlow(): this {
    this.wait = new Promise<void>((resolve) => {
      this.releaseProvider = resolve;
    });
    return this;
  }

  release(): void {
    this.releaseProvider?.();
  }

  async research(_request: BrokerRequest): Promise<ProviderResearchResult> {
    this.callCount += 1;
    await this.wait;
    return this.result;
  }
}

export function durableEnv(overrides: Record<string, string | undefined> = {}): NodeJS.ProcessEnv {
  return {
    BROKER_HTTP_ENABLED: 'true',
    BROKER_PROVIDER_MODE: 'openai',
    BROKER_OPENAI_LIVE_TEST_ENABLED: 'true',
    BROKER_OWNER_UID_ALLOWLIST: 'owner-uid',
    BROKER_FIREBASE_PROJECT_ID: 'my-art-collections',
    BROKER_FIREBASE_PROJECT_NUMBER: '123456789',
    BROKER_APP_ID_ALLOWLIST: 'owner-test-app',
    BROKER_DURABLE_STORE_CONFIGURED: 'true',
    BROKER_QUOTA_HMAC_SECRET: 'test-only-quota-hmac-secret',
    OPENAI_API_KEY: 'test-only-provider-key',
    OPENAI_ALLOWED_DOMAINS: 'museum.example',
    ...overrides,
  };
}

export function createHttpRequest(
  body: unknown,
  headers: Record<string, string | undefined> = {},
) {
  const httpRequest = Readable.from([]) as Readable & {
    method?: string;
    headers: Record<string, string | undefined>;
    body?: unknown;
  };
  httpRequest.method = 'POST';
  httpRequest.headers = {
    'content-type': 'application/json',
    authorization: 'Bearer owner-auth-token',
    'x-firebase-appcheck': 'owner-app-check-token',
    ...headers,
  };
  httpRequest.body = body;
  return httpRequest;
}

export function createHttpResponse(): {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
  json: Record<string, unknown>;
  responder: MinimalResponse;
} {
  const output = {
    statusCode: 200,
    headers: {} as Record<string, string>,
    body: '',
    json: {} as Record<string, unknown>,
    responder: undefined as unknown as MinimalResponse,
  };
  const responder: MinimalResponse = {
    status(code) {
      output.statusCode = code;
      return responder;
    },
    setHeader(name, value) {
      output.headers[name] = value;
    },
    end(body) {
      output.body = body;
      output.json = JSON.parse(body) as Record<string, unknown>;
    },
  };
  output.responder = responder;
  return output;
}

class MemorySnapshot implements DurableFirestoreDocumentSnapshot {
  constructor(private readonly value: Record<string, unknown> | undefined) {}
  get exists(): boolean {
    return this.value !== undefined;
  }
  data(): Record<string, unknown> | undefined {
    return clone(this.value);
  }
}

class MemoryDocumentRef implements DurableFirestoreDocumentRef {
  constructor(private readonly db: MemoryFirestore, readonly path: string) {}
  async get(): Promise<DurableFirestoreDocumentSnapshot> {
    return new MemorySnapshot(this.db.read(this.path));
  }
  async set(data: Record<string, unknown>, options?: { merge?: boolean }): Promise<void> {
    this.db.write(this.path, data, options?.merge === true);
  }
  async update(data: Record<string, unknown>): Promise<void> {
    this.db.write(this.path, data, true);
  }
  async delete(): Promise<void> {
    this.db.documents.delete(this.path);
  }
}

class MemoryTransaction implements DurableFirestoreTransaction {
  private readonly staged = new Map<string, Record<string, unknown> | undefined>();
  constructor(private readonly db: MemoryFirestore) {}
  async get(ref: DurableFirestoreDocumentRef): Promise<DurableFirestoreDocumentSnapshot> {
    return new MemorySnapshot(this.staged.has(ref.path) ? this.staged.get(ref.path) : this.db.read(ref.path));
  }
  set(
    ref: DurableFirestoreDocumentRef,
    data: Record<string, unknown>,
    options?: { merge?: boolean },
  ): DurableFirestoreTransaction {
    const previous = options?.merge === true
      ? this.staged.get(ref.path) ?? this.db.read(ref.path) ?? {}
      : {};
    this.staged.set(ref.path, { ...previous, ...clone(data) });
    return this;
  }
  update(ref: DurableFirestoreDocumentRef, data: Record<string, unknown>): DurableFirestoreTransaction {
    return this.set(ref, data, { merge: true });
  }
  delete(ref: DurableFirestoreDocumentRef): DurableFirestoreTransaction {
    this.staged.set(ref.path, undefined);
    return this;
  }
  commit(): void {
    for (const [path, value] of this.staged) {
      if (value === undefined) {
        this.db.documents.delete(path);
      } else {
        this.db.write(path, value, false);
      }
    }
  }
}

export class MemoryFirestore implements DurableFirestoreLike {
  readonly documents = new Map<string, Record<string, unknown>>();
  private transactionTail: Promise<void> = Promise.resolve();

  doc(path: string): DurableFirestoreDocumentRef {
    return new MemoryDocumentRef(this, path);
  }

  async runTransaction<T>(
    updateFunction: (transaction: DurableFirestoreTransaction) => Promise<T>,
  ): Promise<T> {
    let release!: () => void;
    const turn = new Promise<void>((resolve) => {
      release = resolve;
    });
    const previous = this.transactionTail;
    this.transactionTail = previous.then(() => turn);
    await previous;
    try {
      const transaction = new MemoryTransaction(this);
      const result = await updateFunction(transaction);
      transaction.commit();
      return result;
    } finally {
      release();
    }
  }

  seed(path: string, value: Record<string, unknown>): void {
    this.write(path, value, false);
  }

  read(path: string): Record<string, unknown> | undefined {
    return clone(this.documents.get(path));
  }

  write(path: string, value: Record<string, unknown>, merge: boolean): void {
    this.documents.set(path, {
      ...(merge ? this.documents.get(path) ?? {} : {}),
      ...clone(value),
    });
  }

  find(prefix: string): Array<Record<string, unknown>> {
    return [...this.documents]
      .filter(([path]) => path.startsWith(prefix))
      .map(([, value]) => clone(value)!);
  }
}

export function seededFirestore(): MemoryFirestore {
  const db = new MemoryFirestore();
  db.seed('brokerDurableControl/live', {
    record_version: 'broker-control-v1',
    breakerOpen: false,
    perSubjectCreditCap: 3,
    brokerCreditCap: 100,
    oneInFlightPerSubject: true,
  });
  db.seed('brokerDurableEntitlements/b3duZXItdWlk', {
    record_version: 'broker-entitlement-v1',
    entitled: true,
  });
  return db;
}

function clone<T extends Record<string, unknown>>(value: T | undefined): T | undefined {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value)) as T;
}
