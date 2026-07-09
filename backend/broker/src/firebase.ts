import { onRequest } from 'firebase-functions/v2/https';

import { createResearchBrokerHttpHandler } from './live_broker.js';

export const artResearchBroker = onRequest(
  {
    region: 'us-central1',
    cors: false,
    maxInstances: 2,
    timeoutSeconds: 60,
    memory: '512MiB',
  },
  createResearchBrokerHttpHandler(),
);
