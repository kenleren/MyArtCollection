import { createHash } from 'node:crypto';

import { GoogleAuth } from 'google-auth-library';

import { PACKAGE_NAME, PRODUCT_ALLOWLIST } from './constants.js';
import type {
  PlayAcknowledgeArguments,
  PlayGetArguments,
  PlaySubscriptionPurchase,
  PlaySubscriptionsAdapter,
} from './contracts.js';

const ANDROID_PUBLISHER_SCOPE = 'https://www.googleapis.com/auth/androidpublisher';
const ANDROID_PUBLISHER_ROOT = 'https://androidpublisher.googleapis.com/androidpublisher/v3';
const PLAY_CALL_TIMEOUT_MS = 10_000;

export interface AndroidPublisherTransport {
  getSubscription(args: PlayGetArguments): Promise<unknown>;
  acknowledgeSubscription(args: PlayAcknowledgeArguments): Promise<unknown>;
}

interface GoogleAuthenticatedClient {
  getRequestHeaders(url?: string): Promise<unknown>;
}

interface GoogleAuthProvider {
  getClient(): Promise<GoogleAuthenticatedClient>;
}

export interface PublisherFetchResponse {
  ok: boolean;
  json(): Promise<unknown>;
}

export type PublisherFetch = (
  url: string,
  init: {
    method: 'GET' | 'POST';
    headers: Record<string, string>;
    body?: string;
    signal: AbortSignal;
  },
) => Promise<PublisherFetchResponse>;

export interface DeadlineScheduler {
  schedule(onDeadline: () => void, delayMs: number): () => void;
}

const systemDeadlineScheduler: DeadlineScheduler = {
  schedule(onDeadline, delayMs) {
    const timeout = setTimeout(onDeadline, delayMs);
    return () => clearTimeout(timeout);
  },
};

/**
 * Android Publisher REST transport using application-default credentials. It
 * never retries. The caller supplies the exact absolute deadline for each
 * request and receives only parsed response data or a sanitized failure.
 */
export class GoogleAndroidPublisherTransport implements AndroidPublisherTransport {
  private readonly auth: GoogleAuthProvider;
  private readonly fetch: PublisherFetch;

  constructor(options: { auth?: GoogleAuthProvider; fetch?: PublisherFetch } = {}) {
    this.auth = options.auth ?? new GoogleAuth({ scopes: [ANDROID_PUBLISHER_SCOPE] });
    this.fetch = options.fetch ?? defaultPublisherFetch;
  }

  async getSubscription(args: PlayGetArguments): Promise<unknown> {
    return this.request(
      'GET',
      `${ANDROID_PUBLISHER_ROOT}/applications/${encodeURIComponent(args.packageName)}` +
        `/purchases/subscriptionsv2/tokens/${encodeURIComponent(args.token)}`,
      undefined,
      args.timeoutMs,
    );
  }

  async acknowledgeSubscription(args: PlayAcknowledgeArguments): Promise<unknown> {
    return this.request(
      'POST',
      `${ANDROID_PUBLISHER_ROOT}/applications/${encodeURIComponent(args.packageName)}` +
        `/purchases/subscriptions/${encodeURIComponent(args.subscriptionId)}` +
        `/tokens/${encodeURIComponent(args.token)}:acknowledge`,
      '{}',
      args.timeoutMs,
    );
  }

  private async request(
    method: 'GET' | 'POST',
    url: string,
    body: string | undefined,
    timeoutMs: number,
  ): Promise<unknown> {
    const deadline = Date.now() + timeoutMs;
    try {
      const client = await withDeadline(this.auth.getClient(), deadline, systemDeadlineScheduler);
      const authenticatedHeaders = await withDeadline(
        client.getRequestHeaders(url),
        deadline,
        systemDeadlineScheduler,
      );
      const headers = normalizeHeaders(authenticatedHeaders);
      const remaining = deadline - Date.now();
      if (remaining <= 0) {
        throw new Error('deadline elapsed');
      }
      const controller = new AbortController();
      const cancel = systemDeadlineScheduler.schedule(() => controller.abort(), remaining);
      try {
        const response = await this.fetch(url, {
          method,
          headers: {
            ...headers,
            accept: 'application/json',
            ...(body === undefined ? {} : { 'content-type': 'application/json' }),
          },
          ...(body === undefined ? {} : { body }),
          signal: controller.signal,
        });
        if (!response.ok) {
          throw new Error('publisher rejected request');
        }
        return await response.json();
      } finally {
        cancel();
      }
    } catch {
      throw unavailable();
    }
  }
}

/**
 * The verifier owns response eligibility checks. This adapter owns only the
 * Android Publisher protocol, strict request shape, and sanitized transport.
 */
export class AndroidPublisherSubscriptionsAdapter implements PlaySubscriptionsAdapter {
  constructor(
    private readonly transport: AndroidPublisherTransport,
    private readonly deadlines: DeadlineScheduler = systemDeadlineScheduler,
  ) {}

  async getSubscription(args: PlayGetArguments): Promise<PlaySubscriptionPurchase> {
    assertGetArguments(args);
    try {
      const raw = await withDeadline(
        this.transport.getSubscription(args),
        Date.now() + args.timeoutMs,
        this.deadlines,
      );
      return normalizePurchase(raw);
    } catch (error) {
      if (error instanceof PlayAdapterError) {
        throw error;
      }
      throw unavailable();
    }
  }

  async acknowledgeSubscription(args: PlayAcknowledgeArguments): Promise<void> {
    assertAcknowledgeArguments(args);
    try {
      await withDeadline(
        this.transport.acknowledgeSubscription(args),
        Date.now() + args.timeoutMs,
        this.deadlines,
      );
    } catch (error) {
      if (error instanceof PlayAdapterError) {
        throw error;
      }
      throw unavailable();
    }
  }
}

export interface PlayAdapterConfiguration {
  enabled?: boolean;
  transportFactory?: () => AndroidPublisherTransport;
}

/**
 * Local and test runtime stays disabled. Deployment owners must explicitly
 * opt in before application-default credentials can be used at request time.
 */
export function createConfiguredPlaySubscriptionsAdapter(
  configuration: PlayAdapterConfiguration = {},
): PlaySubscriptionsAdapter {
  if (configuration.enabled !== true) {
    return new DisabledPlaySubscriptionsAdapter();
  }
  return new AndroidPublisherSubscriptionsAdapter(
    configuration.transportFactory?.() ?? new GoogleAndroidPublisherTransport(),
  );
}

export interface SanitizedPlayGetCall {
  packageName: PlayGetArguments['packageName'];
  timeoutMs: PlayGetArguments['timeoutMs'];
}

export interface SanitizedPlayAcknowledgeCall {
  packageName: PlayAcknowledgeArguments['packageName'];
  subscriptionId: PlayAcknowledgeArguments['subscriptionId'];
  body: Record<string, never>;
  timeoutMs: PlayAcknowledgeArguments['timeoutMs'];
}

export class DisabledPlaySubscriptionsAdapter implements PlaySubscriptionsAdapter {
  async getSubscription(_args: PlayGetArguments): Promise<PlaySubscriptionPurchase> {
    throw new Error('play adapter is disabled');
  }

  async acknowledgeSubscription(_args: PlayAcknowledgeArguments): Promise<void> {
    throw new Error('play adapter is disabled');
  }
}

export class FakePlaySubscriptionsAdapter implements PlaySubscriptionsAdapter {
  readonly getCalls: SanitizedPlayGetCall[] = [];
  readonly acknowledgeCalls: SanitizedPlayAcknowledgeCall[] = [];
  private readonly purchases = new Map<string, PlaySubscriptionPurchase>();
  getError?: Error;
  acknowledgeError?: Error;
  beforeGet?: (args: PlayGetArguments) => Promise<void>;
  beforeAcknowledge?: (args: PlayAcknowledgeArguments) => Promise<void>;

  setPurchase(token: string, purchase: PlaySubscriptionPurchase): void {
    this.purchases.set(fakeLookupKey(token), structuredClone(purchase));
  }

  async getSubscription(args: PlayGetArguments): Promise<PlaySubscriptionPurchase> {
    this.getCalls.push({ packageName: args.packageName, timeoutMs: args.timeoutMs });
    await this.beforeGet?.(args);
    if (this.getError !== undefined) {
      throw this.getError;
    }
    const purchase = this.purchases.get(fakeLookupKey(args.token));
    if (purchase === undefined) {
      throw new Error('fake purchase unavailable');
    }
    return structuredClone(purchase);
  }

  async acknowledgeSubscription(args: PlayAcknowledgeArguments): Promise<void> {
    this.acknowledgeCalls.push({
      packageName: args.packageName,
      subscriptionId: args.subscriptionId,
      body: {},
      timeoutMs: args.timeoutMs,
    });
    await this.beforeAcknowledge?.(args);
    if (this.acknowledgeError !== undefined) {
      throw this.acknowledgeError;
    }
  }
}

function fakeLookupKey(token: string): string {
  return createHash('sha256').update(token, 'utf8').digest('hex');
}

class PlayAdapterError extends Error {}

function unavailable(): PlayAdapterError {
  return new PlayAdapterError('Android Publisher is temporarily unavailable');
}

function rejectedRequest(): PlayAdapterError {
  return new PlayAdapterError('Android Publisher request was rejected');
}

function malformedResponse(): PlayAdapterError {
  return new PlayAdapterError('Android Publisher response was malformed');
}

function assertGetArguments(args: PlayGetArguments): void {
  if (
    args.packageName !== PACKAGE_NAME ||
    !isOpaqueValue(args.token) ||
    args.timeoutMs !== PLAY_CALL_TIMEOUT_MS
  ) {
    throw rejectedRequest();
  }
}

function assertAcknowledgeArguments(args: PlayAcknowledgeArguments): void {
  if (
    args.packageName !== PACKAGE_NAME ||
    !(args.subscriptionId in PRODUCT_ALLOWLIST) ||
    !isOpaqueValue(args.token) ||
    args.timeoutMs !== PLAY_CALL_TIMEOUT_MS ||
    !isEmptyRecord(args.body)
  ) {
    throw rejectedRequest();
  }
}

function isOpaqueValue(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= 4_096;
}

function isEmptyRecord(value: unknown): value is Record<string, never> {
  return isRecord(value) && Object.keys(value).length === 0;
}

function normalizePurchase(value: unknown): PlaySubscriptionPurchase {
  if (!isRecord(value) || !Array.isArray(value.lineItems)) {
    throw malformedResponse();
  }
  const linkedPurchaseToken = optionalString(value.linkedPurchaseToken);
  return {
    subscriptionState: optionalString(value.subscriptionState),
    acknowledgementState: optionalString(value.acknowledgementState),
    ...(linkedPurchaseToken === undefined ? {} : { linkedPurchaseToken }),
    externalAccountIdentifiers: normalizeExternalAccountIdentifiers(
      value.externalAccountIdentifiers,
    ),
    lineItems: value.lineItems.map(normalizeLineItem),
  };
}

function normalizeExternalAccountIdentifiers(
  value: unknown,
): PlaySubscriptionPurchase['externalAccountIdentifiers'] {
  if (!isRecord(value)) {
    return undefined;
  }
  return { obfuscatedExternalAccountId: optionalString(value.obfuscatedExternalAccountId) };
}

function normalizeLineItem(value: unknown): NonNullable<PlaySubscriptionPurchase['lineItems']>[number] {
  if (!isRecord(value)) {
    throw malformedResponse();
  }
  return {
    productId: optionalString(value.productId),
    expiryTime: optionalString(value.expiryTime),
    offerDetails: normalizeOfferDetails(value.offerDetails),
    ...(isRecord(value.autoRenewingPlan) ? { autoRenewingPlan: {} } : {}),
  };
}

function normalizeOfferDetails(
  value: unknown,
): NonNullable<PlaySubscriptionPurchase['lineItems']>[number]['offerDetails'] {
  if (!isRecord(value)) {
    return undefined;
  }
  const offerId = optionalString(value.offerId);
  return {
    basePlanId: optionalString(value.basePlanId),
    ...(offerId === undefined ? {} : { offerId }),
  };
}

function optionalString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

function normalizeHeaders(value: unknown): Record<string, string> {
  if (typeof Headers !== 'undefined' && value instanceof Headers) {
    return Object.fromEntries(value.entries());
  }
  if (!isRecord(value)) {
    throw unavailable();
  }
  const headers: Record<string, string> = {};
  for (const [key, headerValue] of Object.entries(value)) {
    if (typeof headerValue !== 'string') {
      throw unavailable();
    }
    headers[key] = headerValue;
  }
  return headers;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function withDeadline<T>(
  operation: Promise<T>,
  deadline: number,
  scheduler: DeadlineScheduler,
): Promise<T> {
  const remaining = deadline - Date.now();
  if (remaining <= 0) {
    return Promise.reject(unavailable());
  }
  return new Promise<T>((resolve, reject) => {
    const cancel = scheduler.schedule(() => reject(unavailable()), remaining);
    operation.then(
      (value) => {
        cancel();
        resolve(value);
      },
      (error: unknown) => {
        cancel();
        reject(error);
      },
    );
  });
}

const defaultPublisherFetch: PublisherFetch = async (url, init) => fetch(url, init);
