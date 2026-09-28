import { BillingDeadline } from './deadline.js';
import { createConfiguredTokenCustody } from './kms_token_custody.js';
import { getApp, getApps, initializeApp, type App } from 'firebase-admin/app';
import { getAuth, type Auth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { defineSecret, defineString } from 'firebase-functions/params';
import {
  onCall,
  type CallableRequest,
} from 'firebase-functions/v2/https';

import {
  BILLING_DATABASE_ID,
  BILLING_VERIFIER_SERVICE_ACCOUNT,
} from './constants.js';
import type { BillingIdentity } from './contracts.js';
import { isPaidGoogleIdentity } from './identity.js';
import { createBillingIdentifiers, CryptoNonceSource } from './crypto.js';
import { FirestoreBillingDatabase } from './firestore_store.js';
import { createConfiguredPlaySubscriptionsAdapter } from './play_adapter.js';
import { matchesApprovedAppId, resolveApprovedAppId } from './runtime_config.js';
import { BillingRepository } from './store.js';
import { PlayBillingService } from './verifier.js';

const fingerprintKey = defineSecret('PLAY_BILLING_FINGERPRINT_KEY');
const tokenKeyVersion = defineString('PLAY_BILLING_TOKEN_KEY_VERSION');
const retainedTokenKeyVersions = defineString('PLAY_BILLING_TOKEN_RETAINED_VERSIONS');
const approvedAppIdParameter = defineString('PLAY_BILLING_APPROVED_APP_ID');
const callableOptions = {
  region: 'us-central1' as const,
  timeoutSeconds: 60,
  memory: '512MiB' as const,
  minInstances: 0,
  maxInstances: 1,
  concurrency: 10,
  serviceAccount: BILLING_VERIFIER_SERVICE_ACCOUNT,
  enforceAppCheck: true,
  consumeAppCheckToken: true,
  secrets: [fingerprintKey],
};

export const acceptPlayBillingDisclosure = onCall(callableOptions, async (request) => {
  const deadline = new BillingDeadline();
  const app = getOrInitializeApp();
  const identity = await deadline.run(() => verifyCallableIdentity(request, getAuth(app))).catch(() => undefined);
  if (identity === undefined) {
    return identityRejected(request.data);
  }
  const service = createService(app);
  return service === undefined
    ? temporarilyUnavailable(request.data)
    : await deadline.run(() => service.acceptDisclosure(identity, request.data, deadline), 55_000).catch(() => temporarilyUnavailable(request.data));
});

export const revokePlayBillingDisclosure = onCall(callableOptions, async (request) => {
  const deadline = new BillingDeadline();
  const app = getOrInitializeApp();
  const identity = await deadline.run(() => verifyCallableIdentity(request, getAuth(app))).catch(() => undefined);
  if (identity === undefined) {
    return identityRejected(request.data);
  }
  const service = createService(app);
  return service === undefined
    ? temporarilyUnavailable(request.data)
    : await deadline.run(() => service.revokeDisclosure(identity, request.data, deadline), 55_000).catch(() => temporarilyUnavailable(request.data));
});

export const verifyPlaySubscription = onCall(callableOptions, async (request) => {
  if (process.env.PLAY_BILLING_RECOVERY_ENABLED !== 'enabled') return temporarilyUnavailable(request.data);
  const deadline = new BillingDeadline();
  const app = getOrInitializeApp();
  const identity = await deadline.run(() => verifyCallableIdentity(request, getAuth(app))).catch(() => undefined);
  if (identity === undefined) {
    return identityRejected(request.data);
  }
  const service = createService(app);
  return service === undefined
    ? temporarilyUnavailable(request.data)
    : await deadline.run(() => service.verifySubscription(identity, request.data, deadline), 55_000).catch(() => temporarilyUnavailable(request.data));
});

export const restorePlayEntitlement = onCall(callableOptions, async (request) => {
  const deadline = new BillingDeadline();
  if (process.env.PLAY_BILLING_RECOVERY_ENABLED !== 'enabled') return temporarilyUnavailable(request.data);
  const app = getOrInitializeApp();
  const identity = await deadline.run(() => verifyCallableIdentity(request, getAuth(app))).catch(() => undefined);
  if (!identity) return identityRejected(request.data);
  const service = createService(app);
  return service === undefined ? temporarilyUnavailable(request.data)
    : await deadline.run(() => service.restoreEntitlement(identity, request.data, deadline), 55_000)
      .catch(() => temporarilyUnavailable(request.data));
});

function createService(app: App): PlayBillingService | undefined {
  try {
    const identifiers = createBillingIdentifiers(decodeFingerprintKey(fingerprintKey.value()));
    const database = new FirestoreBillingDatabase(getFirestore(app, BILLING_DATABASE_ID));
    return new PlayBillingService({
      repository: new BillingRepository(database, new CryptoNonceSource()),
      identifiers,
      play: createConfiguredPlaySubscriptionsAdapter({
        enabled: process.env.PLAY_BILLING_ANDROID_PUBLISHER_ENABLED === 'enabled',
      }),
      clock: { now: () => new Date() },
      custody: createConfiguredTokenCustody(process.env.PLAY_BILLING_TOKEN_CUSTODY_ENABLED === 'enabled' ? {
        enabled: true, encryptionVersion: tokenKeyVersion.value(),
        retainedVersions: retainedTokenKeyVersions.value().split(','),
      } : {}),
    });
  } catch {
    return undefined;
  }
}

async function verifyCallableIdentity(
  request: CallableRequest<unknown>,
  auth: Auth,
): Promise<BillingIdentity | undefined> {
  const approvedAppId = resolveApprovedAppId(approvedAppIdParameter);
  if (
    request.auth === undefined ||
    request.app === undefined ||
    !matchesApprovedAppId(approvedAppId, request.app.appId)
  ) {
    return undefined;
  }
  const authorization = request.rawRequest.headers.authorization;
  if (typeof authorization !== 'string' || !authorization.startsWith('Bearer ')) {
    return undefined;
  }
  try {
    const decoded = await auth.verifyIdToken(authorization.slice('Bearer '.length), true);
    if (!isPaidGoogleIdentity(decoded, request.auth.uid)) {
      return undefined;
    }
    return { uid: decoded.uid };
  } catch {
    return undefined;
  }
}

function decodeFingerprintKey(value: string): Uint8Array {
  try {
    const key = Buffer.from(value, 'base64url');
    if (key.byteLength < 32) {
      throw new Error('short key');
    }
    return key;
  } catch {
    throw new Error('billing fingerprint key is unavailable');
  }
}

function identityRejected(data: unknown): Record<string, unknown> {
  const requestId =
    data !== null &&
    typeof data === 'object' &&
    'requestId' in data &&
    typeof data.requestId === 'string' &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(
      data.requestId,
    )
      ? data.requestId
      : undefined;
  return {
    version: 'play-billing-v2',
    ...(requestId === undefined ? {} : { requestId }),
    state: 'free',
    status: 'rejected',
    reason: 'identity_rejected',
  };
}

function temporarilyUnavailable(data: unknown): Record<string, unknown> {
  return {
    ...identityRejected(data),
    status: 'unavailable',
    reason: 'temporarily_unavailable',
  };
}

function getOrInitializeApp(): App {
  return getApps().length > 0 ? getApp() : initializeApp();
}
