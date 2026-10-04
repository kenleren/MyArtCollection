import { getApp, getApps, initializeApp, type App } from 'firebase-admin/app';
import { getAppCheck } from 'firebase-admin/app-check';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { defineSecret } from 'firebase-functions/params';
import { onRequest } from 'firebase-functions/v2/https';

import {
  createFirebaseAdminDurableBrokerProtection,
  BROKER_QUOTA_HMAC_SECRET_ENV,
  durableConfigFromEnv,
  type DurableBrokerProtection,
  type DurableFirestoreLike,
  type FirebaseAdminAppCheckLike,
  type FirebaseAdminAuthLike,
} from './durable_protection.js';
import {
  createConfiguredResearchBrokerDependencies,
  createResearchBrokerHttpHandler,
  type ConfiguredBrokerDependenciesResult,
} from './live_broker.js';

// Binding injects secrets into this runtime only. Provider configuration still
// reads the key after consent, identity, access and atomic credit reservation.
const openAiApiKey = defineSecret('OPENAI_API_KEY');
const quotaHmacSecret = defineSecret(BROKER_QUOTA_HMAC_SECRET_ENV);

export interface FirebaseBrokerAdminAdapters {
  app?: App;
  auth?: FirebaseAdminAuthLike;
  appCheck?: FirebaseAdminAppCheckLike;
  firestore?: DurableFirestoreLike;
}

export function createFirebaseDurableBrokerProtection(
  env: NodeJS.ProcessEnv = process.env,
  adapters: FirebaseBrokerAdminAdapters = {},
): DurableBrokerProtection | undefined {
  const durableConfig = durableConfigFromEnv(env);
  if (!durableConfig.ok) {
    return undefined;
  }

  try {
    const app = adapters.app ?? getOrInitializeFirebaseAdminApp();
    const result = createFirebaseAdminDurableBrokerProtection({
      env,
      auth: adapters.auth ?? getAuth(app),
      appCheck: adapters.appCheck ?? getAppCheck(app),
      firestore: adapters.firestore ?? getFirestore(app),
    });
    return result.ok ? result.protection : undefined;
  } catch {
    return undefined;
  }
}

export function createFirebaseResearchBrokerDependencies(
  env: NodeJS.ProcessEnv = process.env,
  adapters: FirebaseBrokerAdminAdapters = {},
): ConfiguredBrokerDependenciesResult {
  return createConfiguredResearchBrokerDependencies(
    env,
    {},
    undefined,
    createFirebaseDurableBrokerProtection(env, adapters),
  );
}

export const artResearchBroker = onRequest(
  {
    region: 'us-central1',
    cors: false,
    minInstances: 0,
    maxInstances: 1,
    concurrency: 1,
    serviceAccount: 'archivale-research-broker@my-art-collections.iam.gserviceaccount.com',
    secrets: [openAiApiKey, quotaHmacSecret],
    timeoutSeconds: 60,
    memory: '512MiB',
  },
  createResearchBrokerHttpHandler({
    dependenciesFactory: createFirebaseResearchBrokerDependencies,
  }),
);

function getOrInitializeFirebaseAdminApp(): App {
  if (getApps().length > 0) {
    return getApp();
  }
  return initializeApp();
}
