import { randomBytes, randomUUID } from 'node:crypto';

import {
  DISCLOSURE_PURPOSE,
  DISCLOSURE_VERSION,
  PRODUCT_ALLOWLIST,
  type ProductId,
} from '../src/constants.js';
import type {
  BillingIdentity,
  Clock,
  NonceSource,
  PlayAcknowledgementState,
  PlaySubscriptionPurchase,
  PlaySubscriptionState,
  VerifyRequest,
} from '../src/contracts.js';
import { createBillingIdentifiers } from '../src/crypto.js';
import { InMemoryBillingDatabase } from '../src/in_memory_store.js';
import { FakePlaySubscriptionsAdapter } from '../src/play_adapter.js';
import { BillingRepository } from '../src/store.js';
import { PlayBillingService, type VerificationHooks } from '../src/verifier.js';

export class FakeClock implements Clock {
  constructor(private current: Date = new Date('2031-01-01T00:00:00.000Z')) {}

  now(): Date {
    return new Date(this.current);
  }

  advance(milliseconds: number): void {
    this.current = new Date(this.current.getTime() + milliseconds);
  }
}

export class DeterministicNonceSource implements NonceSource {
  private counter = 0;

  nextNonce(): Uint8Array {
    this.counter += 1;
    const nonce = new Uint8Array(16);
    nonce.fill(this.counter);
    return nonce;
  }
}

export interface Harness {
  clock: FakeClock;
  database: InMemoryBillingDatabase;
  repository: BillingRepository;
  play: FakePlaySubscriptionsAdapter;
  service: PlayBillingService;
  identity: BillingIdentity;
  identifiers: ReturnType<typeof createBillingIdentifiers>;
}

export function createHarness(hooks?: VerificationHooks): Harness {
  const clock = new FakeClock();
  const database = new InMemoryBillingDatabase();
  const repository = new BillingRepository(database, new DeterministicNonceSource());
  const play = new FakePlaySubscriptionsAdapter();
  const identifiers = createBillingIdentifiers(randomBytes(32));
  const identity = { uid: randomBytes(24).toString('base64url') };
  return {
    clock,
    database,
    repository,
    play,
    identity,
    identifiers,
    service: new PlayBillingService({ repository, play, identifiers, clock, hooks }),
  };
}

export function purchaseToken(): string {
  return randomBytes(48).toString('base64url');
}

export function verifyRequest(
  token: string,
  productId: ProductId = 'archivale_starter_monthly',
  requestId: string = randomUUID(),
): VerifyRequest {
  return {
    requestId,
    billingDisclosureVersion: DISCLOSURE_VERSION,
    productId,
    purchaseToken: token,
  };
}

export async function acceptDisclosure(harness: Harness): Promise<void> {
  const response = await harness.service.acceptDisclosure(harness.identity, {
    requestId: randomUUID(),
    disclosureVersion: DISCLOSURE_VERSION,
    purpose: DISCLOSURE_PURPOSE,
    accepted: true,
  });
  if (!('status' in response) || response.status !== 'accepted') {
    throw new Error('test disclosure setup failed');
  }
}

export interface PurchaseOptions {
  productId?: ProductId;
  state?: PlaySubscriptionState;
  acknowledgementState?: PlayAcknowledgementState;
  expiryOffsetMs?: number;
  linkedPurchaseToken?: string;
  accountIdentity?: BillingIdentity;
  basePlanId?: string;
  offerId?: string;
  autoRenewing?: boolean;
}

export function eligiblePurchase(
  harness: Harness,
  options: PurchaseOptions = {},
): PlaySubscriptionPurchase {
  const productId = options.productId ?? 'archivale_starter_monthly';
  const product = PRODUCT_ALLOWLIST[productId];
  return {
    subscriptionState: options.state ?? 'SUBSCRIPTION_STATE_ACTIVE',
    acknowledgementState:
      options.acknowledgementState ?? 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED',
    linkedPurchaseToken: options.linkedPurchaseToken,
    externalAccountIdentifiers: {
      obfuscatedExternalAccountId: harness.identifiers.obfuscatedAccountId(
        (options.accountIdentity ?? harness.identity).uid,
      ),
    },
    lineItems: [
      {
        productId,
        expiryTime: new Date(
          harness.clock.now().getTime() + (options.expiryOffsetMs ?? 60 * 60_000),
        ).toISOString(),
        offerDetails: {
          basePlanId: options.basePlanId ?? product.basePlanId,
          ...(options.offerId === undefined ? {} : { offerId: options.offerId }),
        },
        ...(options.autoRenewing === false ? {} : { autoRenewingPlan: {} }),
      },
    ],
  };
}

export function deferred(): {
  promise: Promise<void>;
  resolve: () => void;
} {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

export function recordsInCollection(
  database: InMemoryBillingDatabase,
  collection: string,
): unknown[] {
  const records: unknown[] = [];
  for (const [key, value] of database.snapshotForTest()) {
    if (key.startsWith(`${collection}/`)) {
      records.push(value);
    }
  }
  return records;
}
