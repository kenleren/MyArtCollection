import { getApp, getApps, initializeApp, type App } from 'firebase-admin/app';
import { getAuth, type Auth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { defineSecret } from 'firebase-functions/params';
import {
  onCall,
  type CallableRequest,
} from 'firebase-functions/v2/https';

import { BILLING_DATABASE_ID } from './constants.js';
import type { BillingIdentity } from './contracts.js';
import { createBillingIdentifiers, CryptoNonceSource } from './crypto.js';
import { FirestoreBillingDatabase } from './firestore_store.js';
import { DisabledPlaySubscriptionsAdapter } from './play_adapter.js';
import { BillingRepository } from './store.js';
import { PlayBillingService } from './verifier.js';

const fingerprintKey = defineSecret('PLAY_BILLING_FINGERPRINT_KEY');
const callableOptions = {
  region: 'us-central1' as const,
  timeoutSeconds: 60,
  memory: '512MiB' as const,
  enforceAppCheck: true,
  consumeAppCheckToken: true,
  secrets: [fingerprintKey],
};

export const acceptPlayBillingDisclosure = onCall(callableOptions, async (request) => {
  const app = getOrInitializeApp();
  const identity = await verifyCallableIdentity(request, getAuth(app));
  if (identity === undefined) {
    return identityRejected(request.data);
  }
  const service = createService(app);
  return service === undefined
    ? temporarilyUnavailable(request.data)
    : service.acceptDisclosure(identity, request.data);
});

export const revokePlayBillingDisclosure = onCall(callableOptions, async (request) => {
  const app = getOrInitializeApp();
  const identity = await verifyCallableIdentity(request, getAuth(app));
  if (identity === undefined) {
    return identityRejected(request.data);
  }
  const service = createService(app);
  return service === undefined
    ? temporarilyUnavailable(request.data)
    : service.revokeDisclosure(identity, request.data);
});

export const verifyPlaySubscription = onCall(callableOptions, async (request) => {
  const app = getOrInitializeApp();
  const identity = await verifyCallableIdentity(request, getAuth(app));
  if (identity === undefined) {
    return identityRejected(request.data);
  }
  const service = createService(app);
  return service === undefined
    ? temporarilyUnavailable(request.data)
    : service.verifySubscription(identity, request.data);
});

function createService(app: App): PlayBillingService | undefined {
  try {
    const identifiers = createBillingIdentifiers(decodeFingerprintKey(fingerprintKey.value()));
    const database = new FirestoreBillingDatabase(getFirestore(app, BILLING_DATABASE_ID));
    return new PlayBillingService({
      repository: new BillingRepository(database, new CryptoNonceSource()),
      identifiers,
      play: new DisabledPlaySubscriptionsAdapter(),
      clock: { now: () => new Date() },
    });
  } catch {
    return undefined;
  }
}

async function verifyCallableIdentity(
  request: CallableRequest<unknown>,
  auth: Auth,
): Promise<BillingIdentity | undefined> {
  const approvedAppId = process.env.PLAY_BILLING_APPROVED_APP_ID;
  if (
    request.auth === undefined ||
    request.app === undefined ||
    typeof approvedAppId !== 'string' ||
    approvedAppId.length === 0 ||
    request.app.appId !== approvedAppId
  ) {
    return undefined;
  }
  const authorization = request.rawRequest.headers.authorization;
  if (typeof authorization !== 'string' || !authorization.startsWith('Bearer ')) {
    return undefined;
  }
  try {
    const decoded = await auth.verifyIdToken(authorization.slice('Bearer '.length), true);
    if (
      decoded.uid !== request.auth.uid ||
      decoded.firebase?.sign_in_provider !== 'anonymous'
    ) {
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
    version: 'play-billing-v1',
    ...(requestId === undefined ? {} : { requestId }),
    state: 'free',
    reason: 'identity_rejected',
  };
}

function temporarilyUnavailable(data: unknown): Record<string, unknown> {
  return {
    ...identityRejected(data),
    reason: 'temporarily_unavailable',
  };
}

function getOrInitializeApp(): App {
  return getApps().length > 0 ? getApp() : initializeApp();
}
