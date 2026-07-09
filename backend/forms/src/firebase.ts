import { onRequest } from "firebase-functions/v2/https";
import { getApps, initializeApp } from "firebase-admin/app";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

import {
  createBetaSignupHttpHandler,
  type MinimalRequest,
  type MinimalResponse,
} from "./beta_signup.js";
import type { BetaSignupQueue } from "./contracts.js";
import {
  createSitePageviewHttpHandler,
  type SitePageviewAggregate,
  type SitePageviewAggregateStore,
} from "./site_analytics.js";

const COLLECTION_ENABLED_ENV = "BETA_SIGNUP_HTTP_ENABLED";
const QUEUE_MODE_ENV = "BETA_SIGNUP_QUEUE_MODE";
const SITE_PAGEVIEW_COLLECTION_ENV = "SITE_PAGEVIEW_COLLECTION";
const DEFAULT_SITE_PAGEVIEW_COLLECTION = "site_daily_pageviews";

function createConfiguredDurableBetaSignupQueue(
  _env: NodeJS.ProcessEnv = process.env,
): BetaSignupQueue | null {
  return null;
}

export function isBetaSignupCollectionEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return (
    env[COLLECTION_ENABLED_ENV] === "true" &&
    env[QUEUE_MODE_ENV] === "durable" &&
    createConfiguredDurableBetaSignupQueue(env) !== null
  );
}

function sendDisabledResponse(response: MinimalResponse): void {
  response.setHeader("Content-Type", "application/json; charset=utf-8");
  response.setHeader("X-Content-Type-Options", "nosniff");
  response.setHeader("Cache-Control", "no-store");
  response.status(503).end(
    JSON.stringify({
      ok: false,
      error: "beta_signup_disabled",
    }),
  );
}

export function createBetaSignupFirebaseRequestHandler(
  env: NodeJS.ProcessEnv = process.env,
) {
  return async function betaSignupFirebaseRequestHandler(
    request: MinimalRequest,
    response: MinimalResponse,
  ): Promise<void> {
    const queue = createConfiguredDurableBetaSignupQueue(env);
    if (
      env[COLLECTION_ENABLED_ENV] !== "true" ||
      env[QUEUE_MODE_ENV] !== "durable" ||
      queue === null
    ) {
      sendDisabledResponse(response);
      return;
    }

    await createBetaSignupHttpHandler({ queue })(request, response);
  };
}

export const betaSignup = onRequest(
  {
    region: "us-central1",
    cors: false,
    maxInstances: 5,
    timeoutSeconds: 10,
    memory: "256MiB",
  },
  createBetaSignupFirebaseRequestHandler(),
);

export function createFirestoreSitePageviewStore(
  env: NodeJS.ProcessEnv = process.env,
): SitePageviewAggregateStore {
  ensureFirebaseAdmin();
  const collectionName =
    env[SITE_PAGEVIEW_COLLECTION_ENV] || DEFAULT_SITE_PAGEVIEW_COLLECTION;
  const firestore = getFirestore();

  return {
    async incrementPageview(record: SitePageviewAggregate): Promise<void> {
      const documentId = `${record.date}_${Buffer.from(record.path).toString("base64url")}`;
      await firestore.collection(collectionName).doc(documentId).set(
        {
          date: record.date,
          path: record.path,
          updatedAt: FieldValue.serverTimestamp(),
          viewCount: FieldValue.increment(1),
          referrerCounts: {
            [record.referrerCategory]: FieldValue.increment(1),
          },
          screenCounts: {
            [record.screenBucket]: FieldValue.increment(1),
          },
        },
        { merge: true },
      );
    },
  };
}

export function createSitePageviewFirebaseRequestHandler(
  env: NodeJS.ProcessEnv = process.env,
) {
  return createSitePageviewHttpHandler({
    store: createFirestoreSitePageviewStore(env),
  });
}

export const sitePageview = onRequest(
  {
    region: "us-central1",
    cors: false,
    maxInstances: 10,
    timeoutSeconds: 10,
    memory: "256MiB",
  },
  createSitePageviewFirebaseRequestHandler(),
);

function ensureFirebaseAdmin(): void {
  if (getApps().length === 0) {
    initializeApp();
  }
}
