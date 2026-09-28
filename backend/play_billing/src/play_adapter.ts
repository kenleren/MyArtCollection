import { createHash } from 'node:crypto';

import { GoogleAuth } from 'google-auth-library';

import { PACKAGE_NAME, PRODUCT_ALLOWLIST } from './constants.js';
import { validOpaqueRoute } from './lifecycle.js';
import type {
  PlayAcknowledgeArguments,
  PlayGetArguments,
  PlaySubscriptionPurchase,
  PlaySubscriptionsAdapter,
} from './contracts.js';

const ANDROID_PUBLISHER_SCOPE = 'https://www.googleapis.com/auth/androidpublisher';
const ANDROID_PUBLISHER_ROOT = 'https://androidpublisher.googleapis.com/androidpublisher/v3';
const PLAY_CALL_TIMEOUT_MS = 10_000;
const GET_BODY_LIMIT = 65_536;
const ACK_BODY_LIMIT = 4_096;

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
  status: number;
  redirected: boolean;
  headers: Pick<Headers, 'get'>;
  body: ReadableStream<Uint8Array> | null;
}

export type PublisherFetch = (
  url: string,
  init: {
    method: 'GET' | 'POST';
    headers: Record<string, string>;
    body?: string;
    signal: AbortSignal;
    redirect: 'error';
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
 * never retries or follows redirects. Authentication, fetch and the bounded
 * decompressed response stream share one absolute deadline.
 */
export class GoogleAndroidPublisherTransport implements AndroidPublisherTransport {
  private readonly auth: GoogleAuthProvider;
  private readonly fetch: PublisherFetch;
  private readonly deadlines: DeadlineScheduler;
  private readonly now: () => number;

  constructor(options: {
    auth?: GoogleAuthProvider;
    fetch?: PublisherFetch;
    deadlines?: DeadlineScheduler;
    now?: () => number;
  } = {}) {
    this.auth = options.auth ?? new GoogleAuth({ scopes: [ANDROID_PUBLISHER_SCOPE] });
    this.fetch = options.fetch ?? defaultPublisherFetch;
    this.deadlines = options.deadlines ?? systemDeadlineScheduler;
    this.now = options.now ?? Date.now;
  }

  async getSubscription(args: PlayGetArguments): Promise<unknown> {
    assertGetArguments(args);
    return this.request(
      'GET',
      `${ANDROID_PUBLISHER_ROOT}/applications/${encodeURIComponent(args.packageName)}` +
        `/purchases/subscriptionsv2/tokens/${encodeURIComponent(args.token)}`,
      undefined,
      args.timeoutMs,
      true,
      args.deadline,
    );
  }

  async acknowledgeSubscription(args: PlayAcknowledgeArguments): Promise<unknown> {
    assertAcknowledgeArguments(args);
    return this.request(
      'POST',
      `${ANDROID_PUBLISHER_ROOT}/applications/${encodeURIComponent(args.packageName)}` +
        `/purchases/subscriptions/${encodeURIComponent(args.subscriptionId)}` +
        `/tokens/${encodeURIComponent(args.token)}:acknowledge`,
      isEmptyRecord(args.body) ? '' : JSON.stringify(args.body),
      args.timeoutMs,
      false,
      args.deadline,
    );
  }

  private async request(
    method: 'GET' | 'POST',
    url: string,
    body: string | undefined,
    timeoutMs: number,
    parseResponse: boolean,
    parent?: PlayGetArguments['deadline'],
  ): Promise<unknown> {
    const deadline = Math.min(this.now() + timeoutMs, parent?.expiresAt ?? Infinity);
    const controller = new AbortController();
    let cancelBody: (() => void) | undefined;
    const stop = (): void => {
      controller.abort();
      cancelBody?.();
    };
    const checkDeadline = (): void => {
      if (controller.signal.aborted || parent?.signal.aborted || this.now() >= deadline) {
        stop();
        throw unavailable();
      }
    };
    try {
      return await withDeadline((async () => {
        checkDeadline();
        const client = await this.auth.getClient();
        checkDeadline();
        const headers = normalizeHeaders(await client.getRequestHeaders(url));
        checkDeadline();
        const response = await this.fetch(url, {
          method,
          headers: {
            ...headers,
            accept: 'application/json',
            ...(body === undefined ? {} : { 'content-type': 'application/json' }),
          },
          ...(body === undefined ? {} : { body }),
          signal: controller.signal,
          redirect: 'error',
        });
        // Even a fetch implementation that ignores abort must not leave a late
        // response live or continue into response parsing after the deadline.
        cancelBody = () => discardBody(response.body);
        checkDeadline();
        if (response.redirected || !Number.isInteger(response.status)) {
          throw rejectedRequest();
        }
        if (!response.ok || response.status < 200 || response.status >= 300) {
          throw httpFailure(response.status);
        }
        const limit = parseResponse ? GET_BODY_LIMIT : ACK_BODY_LIMIT;
        const declaredLength = response.headers.get('content-length');
        if (declaredLength !== null &&
            (!/^(0|[1-9][0-9]{0,15})$/.test(declaredLength) || Number(declaredLength) > limit)) {
          throw malformedResponse();
        }
        const chunks: Uint8Array[] = [];
        let size = 0;
        if (response.body !== null) {
          const reader = response.body.getReader();
          cancelBody = () => { void reader.cancel().catch(() => undefined); };
          try {
            for (;;) {
              checkDeadline();
              const chunk = await reader.read();
              checkDeadline();
              if (chunk.done) break;
              if (!(chunk.value instanceof Uint8Array) || chunk.value.byteLength > limit - size) {
                throw malformedResponse();
              }
              size += chunk.value.byteLength;
              if (parseResponse) chunks.push(Uint8Array.from(chunk.value));
            }
          } finally {
            // Cancellation is deliberately not awaited: an injected or broken
            // stream must not extend the request's absolute deadline.
            cancelBody();
            reader.releaseLock();
            cancelBody = undefined;
          }
        }
        checkDeadline();
        if (!parseResponse) return undefined;
        let parsed: unknown;
        try {
          parsed = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks, size)));
        } catch {
          throw malformedResponse();
        }
        assertBoundedJson(parsed);
        checkDeadline();
        return parsed;
      })(), deadline, this.deadlines, this.now, stop, parent?.signal);
    } catch (error) {
      stop();
      if (error instanceof PlayAdapterError) throw error;
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
    assertParentActive(args.deadline);
    try {
      const raw = await withDeadline(
        this.transport.getSubscription(args),
        Math.min(Date.now() + args.timeoutMs, args.deadline?.expiresAt ?? Infinity),
        this.deadlines,
        Date.now,
        undefined,
        args.deadline?.signal,
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
    assertParentActive(args.deadline);
    try {
      await withDeadline(
        this.transport.acknowledgeSubscription(args),
        Math.min(Date.now() + args.timeoutMs, args.deadline?.expiresAt ?? Infinity),
        this.deadlines,
        Date.now,
        undefined,
        args.deadline?.signal,
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

export type PlayAdapterFailure = 'configuration' | 'transient' | 'not_found' | 'malformed' | 'rejected';

const FAILURE_MESSAGES: Record<PlayAdapterFailure, string> = {
  configuration: 'Android Publisher configuration is unavailable',
  transient: 'Android Publisher is temporarily unavailable',
  not_found: 'Android Publisher purchase was not found',
  malformed: 'Android Publisher response was malformed',
  rejected: 'Android Publisher request was rejected',
};

/** Only fixed classifications cross the transport boundary; never provider data. */
export class PlayAdapterError extends Error {
  constructor(readonly classification: PlayAdapterFailure) {
    super(FAILURE_MESSAGES[classification]);
  }
}

export function classifyPlayAdapterError(error: unknown): PlayAdapterFailure {
  return error instanceof PlayAdapterError ? error.classification : 'transient';
}

function unavailable(): PlayAdapterError {
  return new PlayAdapterError('transient');
}

function rejectedRequest(): PlayAdapterError {
  return new PlayAdapterError('rejected');
}

function malformedResponse(): PlayAdapterError {
  return new PlayAdapterError('malformed');
}

function httpFailure(status: number): PlayAdapterError {
  if (status === 401 || status === 403) return new PlayAdapterError('configuration');
  if (status === 404 || status === 410) return new PlayAdapterError('not_found');
  if (status === 408 || status === 409 || status === 429 || (status >= 500 && status <= 599)) return unavailable();
  return rejectedRequest();
}

function assertGetArguments(args: PlayGetArguments): void {
  if (
    !isRecord(args) || Object.keys(args).length !== 3 + Number(Object.hasOwn(args, 'deadline')) ||
    !validParentDeadline(args.deadline) ||
    args.packageName !== PACKAGE_NAME ||
    !isOpaqueValue(args.token) ||
    args.timeoutMs !== PLAY_CALL_TIMEOUT_MS
  ) {
    throw rejectedRequest();
  }
}

function assertAcknowledgeArguments(args: PlayAcknowledgeArguments): void {
  if (
    !isRecord(args) || Object.keys(args).length !== 5 + Number(Object.hasOwn(args, 'deadline')) ||
    !validParentDeadline(args.deadline) ||
    args.packageName !== PACKAGE_NAME ||
    typeof args.subscriptionId !== 'string' || !Object.hasOwn(PRODUCT_ALLOWLIST, args.subscriptionId) ||
    !isOpaqueValue(args.token) ||
    args.timeoutMs !== PLAY_CALL_TIMEOUT_MS ||
    !isAcknowledgeBody(args.body)
  ) {
    throw rejectedRequest();
  }
}

function isOpaqueValue(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 && boundedString(value);
}

function validParentDeadline(value: PlayGetArguments['deadline']): boolean {
  return value === undefined || (value !== null && typeof value === 'object' &&
    Number.isSafeInteger(value.expiresAt) && value.signal instanceof AbortSignal);
}

function assertParentActive(value: PlayGetArguments['deadline']): void {
  if (value !== undefined && (value.signal.aborted || Date.now() >= value.expiresAt)) {
    throw unavailable();
  }
}

function isEmptyRecord(value: unknown): value is Record<string, never> {
  return isRecord(value) && Object.keys(value).length === 0;
}

function isAcknowledgeBody(value: unknown): boolean {
  if (isEmptyRecord(value)) return true;
  return isRecord(value) && Object.keys(value).length === 1 &&
    Object.hasOwn(value, 'externalAccountIds') && isRecord(value.externalAccountIds) &&
    Object.keys(value.externalAccountIds).length === 1 &&
    Object.hasOwn(value.externalAccountIds, 'obfuscatedAccountId') &&
    validOpaqueRoute(value.externalAccountIds.obfuscatedAccountId);
}

function normalizePurchase(value: unknown): PlaySubscriptionPurchase {
  assertBoundedJson(value);
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
    ...(value.outOfAppPurchaseContext === undefined ? {} : {
      outOfAppPurchaseContext: normalizeOutOfAppContext(value.outOfAppPurchaseContext),
    }),
    lineItems: value.lineItems.map(normalizeLineItem),
  };
}

function normalizeExternalAccountIdentifiers(
  value: unknown,
): PlaySubscriptionPurchase['externalAccountIdentifiers'] {
  if (value === undefined) return undefined;
  if (!isRecord(value)) throw malformedResponse();
  return { obfuscatedExternalAccountId: optionalString(value.obfuscatedExternalAccountId) };
}

function normalizeOutOfAppContext(
  value: unknown,
): PlaySubscriptionPurchase['outOfAppPurchaseContext'] {
  if (!isRecord(value)) throw malformedResponse();
  const identifiers = normalizeExternalAccountIdentifiers(value.expiredExternalAccountIdentifiers);
  const token = optionalString(value.expiredPurchaseToken);
  return {
    ...(identifiers === undefined ? {} : { expiredExternalAccountIdentifiers: identifiers }),
    ...(token === undefined ? {} : { expiredPurchaseToken: token }),
  };
}

function normalizeLineItem(value: unknown): NonNullable<PlaySubscriptionPurchase['lineItems']>[number] {
  if (!isRecord(value)) {
    throw malformedResponse();
  }
  if (value.autoRenewingPlan !== undefined && !isRecord(value.autoRenewingPlan)) {
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
  if (value === undefined) return undefined;
  if (!isRecord(value)) throw malformedResponse();
  const offerId = optionalString(value.offerId);
  return {
    basePlanId: optionalString(value.basePlanId),
    ...(offerId === undefined ? {} : { offerId }),
  };
}

function optionalString(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  if (!isOpaqueValue(value)) throw malformedResponse();
  return value;
}

function boundedString(value: string): boolean {
  return value.length <= 4_096 && Buffer.byteLength(value, 'utf8') <= 4_096 &&
    Buffer.from(value, 'utf8').toString('utf8') === value;
}

function assertBoundedJson(value: unknown): void {
  let properties = 0;
  const visit = (node: unknown, depth: number): void => {
    if (depth > 12) throw malformedResponse();
    if (typeof node === 'string') {
      if (!boundedString(node)) throw malformedResponse();
    } else if (Array.isArray(node)) {
      if (node.length > 16) throw malformedResponse();
      for (const child of node) visit(child, depth + 1);
    } else if (isRecord(node)) {
      const keys = Object.keys(node);
      properties += keys.length;
      if (properties > 256) throw malformedResponse();
      for (const key of keys) {
        if (!boundedString(key)) throw malformedResponse();
        visit(node[key], depth + 1);
      }
    } else if (node !== null && typeof node !== 'boolean' &&
               !(typeof node === 'number' && Number.isFinite(node))) {
      throw malformedResponse();
    }
  };
  visit(value, 1);
}

function discardBody(body: PublisherFetchResponse['body']): void {
  if (body !== null) {
    try { void body.cancel().catch(() => undefined); } catch { /* No provider error escapes. */ }
  }
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
  return value !== null && typeof value === 'object' &&
    (Object.getPrototypeOf(value) === Object.prototype || Object.getPrototypeOf(value) === null);
}

function withDeadline<T>(
  operation: Promise<T>,
  deadline: number,
  scheduler: DeadlineScheduler,
  now: () => number = Date.now,
  onDeadline: () => void = () => undefined,
  signal?: AbortSignal,
): Promise<T> {
  const remaining = deadline - now();
  if (remaining <= 0 || signal?.aborted) {
    // Attach a rejection handler even when the operation already began.
    void operation.catch(() => undefined);
    onDeadline();
    return Promise.reject(unavailable());
  }
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    let cancelTimer = (): void => undefined;
    const cleanup = (): void => {
      cancelTimer();
      signal?.removeEventListener('abort', expired);
    };
    const expired = (): void => {
      if (settled) return;
      settled = true;
      cleanup();
      onDeadline();
      reject(unavailable());
    };
    signal?.addEventListener('abort', expired, { once: true });
    cancelTimer = scheduler.schedule(expired, remaining);
    operation.then(
      (value) => {
        if (settled) return;
        if (now() >= deadline) expired();
        else { settled = true; cleanup(); resolve(value); }
      },
      (error: unknown) => {
        if (settled) return;
        if (now() >= deadline) expired();
        else { settled = true; cleanup(); reject(error); }
      },
    );
  });
}

const defaultPublisherFetch: PublisherFetch = async (url, init) => fetch(url, init);
