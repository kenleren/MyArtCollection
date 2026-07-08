import { onRequest } from "firebase-functions/v2/https";

import { createBetaSignupHttpHandler } from "./beta_signup.js";
import { createInMemoryBetaSignupQueue } from "./in_memory_queue.js";

const betaSignupQueue = createInMemoryBetaSignupQueue();

export const betaSignup = onRequest(
  {
    region: "us-central1",
    cors: false,
    maxInstances: 5,
    timeoutSeconds: 10,
    memory: "256MiB",
  },
  createBetaSignupHttpHandler({
    queue: betaSignupQueue,
  }),
);
