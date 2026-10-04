import { createReconciliationAwareBillingRuntime } from './reconciliation_runtime.js';
import { BillingDeadline } from './deadline.js';
import { getApp, getApps, initializeApp, type App } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { defineSecret, defineString } from 'firebase-functions/params';
import { onCall } from 'firebase-functions/v2/https';

import {
  BILLING_DATABASE_ID,
  BILLING_VERIFIER_SERVICE_ACCOUNT,
} from './constants.js';
import { verifyCallableIdentity } from './identity.js';
import { createBillingIdentifiers, CryptoNonceSource } from './crypto.js';
import { FirestoreBillingDatabase } from './firestore_store.js';
import { resolveApprovedAppId } from './runtime_config.js';
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

export const preparePlayPurchase = onCall(callableOptions, async (request) => {
  const deadline = new BillingDeadline();
  if (process.env.PLAY_BILLING_ROUTING_ENABLED !== 'enabled' || process.env.PLAY_BILLING_RECOVERY_ENABLED !== 'enabled') return temporarilyUnavailable(request.data);
  const app = getOrInitializeApp();
  const identity = await deadline.run(() => verifyCallableIdentity(request, getAuth(app), resolveApprovedAppId(approvedAppIdParameter))).catch(() => undefined);
  if (!identity) return identityRejected(request.data);
  const service = await createService(app,deadline,false);
  return service === undefined ? temporarilyUnavailable(request.data)
    : await deadline.run(() => service.preparePurchase(identity, request.data, deadline), 55_000).catch(() => temporarilyUnavailable(request.data));
});

export const acceptPlayBillingDisclosure = onCall(callableOptions, async (request) => {
  if (process.env.PLAY_BILLING_ROUTING_ENABLED !== 'enabled') return temporarilyUnavailable(request.data);
  const deadline = new BillingDeadline();
  const app = getOrInitializeApp();
  const identity = await deadline.run(() => verifyCallableIdentity(request, getAuth(app), resolveApprovedAppId(approvedAppIdParameter))).catch(() => undefined);
  if (identity === undefined) {
    return identityRejected(request.data);
  }
  const service = await createService(app,deadline,false);
  return service === undefined
    ? temporarilyUnavailable(request.data)
    : await deadline.run(() => service.acceptDisclosure(identity, request.data, deadline), 55_000).catch(() => temporarilyUnavailable(request.data));
});

export const revokePlayBillingDisclosure = onCall(callableOptions, async (request) => {
  if (process.env.PLAY_BILLING_ROUTING_ENABLED !== 'enabled') return temporarilyUnavailable(request.data);
  const deadline = new BillingDeadline();
  const app = getOrInitializeApp();
  const identity = await deadline.run(() => verifyCallableIdentity(request, getAuth(app), resolveApprovedAppId(approvedAppIdParameter))).catch(() => undefined);
  if (identity === undefined) {
    return identityRejected(request.data);
  }
  const service = await createService(app,deadline,false);
  return service === undefined
    ? temporarilyUnavailable(request.data)
    : await deadline.run(() => service.revokeDisclosure(identity, request.data, deadline), 55_000).catch(() => temporarilyUnavailable(request.data));
});

export const verifyPlaySubscription = onCall(callableOptions, async (request) => {
  if (process.env.PLAY_BILLING_ROUTING_ENABLED !== 'enabled') return temporarilyUnavailable(request.data);
  if (process.env.PLAY_BILLING_RECOVERY_ENABLED !== 'enabled') return temporarilyUnavailable(request.data);
  const deadline = new BillingDeadline();
  const app = getOrInitializeApp();
  const identity = await deadline.run(() => verifyCallableIdentity(request, getAuth(app), resolveApprovedAppId(approvedAppIdParameter))).catch(() => undefined);
  if (identity === undefined) {
    return identityRejected(request.data);
  }
  const service = await createService(app,deadline,true);
  return service === undefined
    ? temporarilyUnavailable(request.data)
    : await deadline.run(() => service.verifySubscription(identity, request.data, deadline), 55_000).catch(() => temporarilyUnavailable(request.data));
});

export const restorePlayEntitlement = onCall(callableOptions, async (request) => {
  if (process.env.PLAY_BILLING_ROUTING_ENABLED !== 'enabled') return temporarilyUnavailable(request.data);
  const deadline = new BillingDeadline();
  if (process.env.PLAY_BILLING_RECOVERY_ENABLED !== 'enabled') return temporarilyUnavailable(request.data);
  const app = getOrInitializeApp();
  const identity = await deadline.run(() => verifyCallableIdentity(request, getAuth(app), resolveApprovedAppId(approvedAppIdParameter))).catch(() => undefined);
  if (!identity) return identityRejected(request.data);
  const service = await createService(app,deadline,true);
  return service === undefined ? temporarilyUnavailable(request.data)
    : await deadline.run(() => service.restoreEntitlement(identity, request.data, deadline), 55_000)
      .catch(() => temporarilyUnavailable(request.data));
});

async function createService(app: App,deadline:BillingDeadline,providersNeeded:boolean): Promise<PlayBillingService | undefined> {
  try {
    const identifiers=createBillingIdentifiers(decodeFingerprintKey(fingerprintKey.value()));
    const database=new FirestoreBillingDatabase(getFirestore(app, BILLING_DATABASE_ID));
    const clock={now:()=>new Date()};
    const runtime=await createReconciliationAwareBillingRuntime({database,identifiers,nonces:new CryptoNonceSource(),clock,deadline,providersNeeded,
      configuration:process.env.PLAY_BILLING_DISPATCH_CONFIG,publisherEnabled:process.env.PLAY_BILLING_ANDROID_PUBLISHER_ENABLED==='enabled',
      ...(providersNeeded&&process.env.PLAY_BILLING_TOKEN_CUSTODY_ENABLED==='enabled'?{accountCustody:{enabled:true,encryptionVersion:tokenKeyVersion.value(),retainedVersions:retainedTokenKeyVersions.value().split(',')}}:{})},process.env.PLAY_BILLING_RECONCILIATION_CONFIG);
    return new PlayBillingService({...runtime,identifiers,clock});
  }catch{return undefined;}
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
    version: 'play-billing-v3',
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
