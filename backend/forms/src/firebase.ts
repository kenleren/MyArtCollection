import { onRequest } from "firebase-functions/v2/https";

import { createBetaSignupHttpHandler } from "./beta_signup.js";
import { createInMemoryBetaSignupQueue } from "./in_memory_queue.js";

const COLLECTION_ENABLED_ENV = "BETA_SIGNUP_HTTP_ENABLED";
const QUEUE_MODE_ENV = "BETA_SIGNUP_QUEUE_MODE";
const betaSignupQueue = createInMemoryBetaSignupQueue();
const betaSignupHandler = createBetaSignupHttpHandler({
  queue: betaSignupQueue,
});

export function isBetaSignupCollectionEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env[COLLECTION_ENABLED_ENV] === "true" && env[QUEUE_MODE_ENV] === "durable";
}

export const betaSignup = onRequest(
  {
    region: "us-central1",
    cors: false,
    maxInstances: 5,
    timeoutSeconds: 10,
    memory: "256MiB",
  },
  async (request, response) => {
    if (!isBetaSignupCollectionEnabled()) {
      response.setHeader("Content-Type", "application/json; charset=utf-8");
      response.setHeader("X-Content-Type-Options", "nosniff");
      response.setHeader("Cache-Control", "no-store");
      response.status(503).send(
        JSON.stringify({
          ok: false,
          error: "beta_signup_disabled",
        }),
      );
      return;
    }

    await betaSignupHandler(request, response);
  },
);
