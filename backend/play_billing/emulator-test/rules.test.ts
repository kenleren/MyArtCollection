import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { after, describe, test } from 'node:test';

import { deleteApp, initializeApp, type FirebaseApp } from 'firebase/app';
import {
  connectFirestoreEmulator,
  doc,
  getDoc,
  getFirestore,
  setDoc,
  terminate,
  type EmulatorMockTokenOptions,
  type Firestore,
} from 'firebase/firestore';

import { BILLING_DATABASE_ID, COLLECTIONS } from '../src/constants.js';

const emulatorHost = process.env.FIRESTORE_EMULATOR_HOST;
if (emulatorHost === undefined) {
  throw new Error('FIRESTORE_EMULATOR_HOST is required');
}
const [host, portText] = emulatorHost.split(':');
const port = Number(portText);
if (host === undefined || !Number.isInteger(port)) {
  throw new Error('invalid Firestore emulator address');
}

const clients: Array<{ app: FirebaseApp; firestore: Firestore }> = [];

after(async () => {
  await Promise.all(
    clients.map(async ({ app, firestore }) => {
      await terminate(firestore);
      await deleteApp(app);
    }),
  );
});

describe('named billing database client rules', () => {
  test('deny anonymous reads and writes', async () => {
    const firestore = client();
    await assertPermissionDenied(getDoc(probe(firestore)));
    await assertPermissionDenied(setDoc(probe(firestore), { probe: true }));
  });

  test('deny authenticated anonymous-user reads and writes', async () => {
    const subject = randomUUID();
    const firestore = client({
      sub: subject,
      user_id: subject,
      firebase: { sign_in_provider: 'anonymous' },
    });
    await assertPermissionDenied(getDoc(probe(firestore)));
    await assertPermissionDenied(setDoc(probe(firestore), { probe: true }));
  });
});

function client(mockUserToken?: EmulatorMockTokenOptions): Firestore {
  const app = initializeApp({ projectId: 'demo-archivale-billing' }, randomUUID());
  const firestore = getFirestore(app, BILLING_DATABASE_ID);
  connectFirestoreEmulator(firestore, host, port, { mockUserToken });
  clients.push({ app, firestore });
  return firestore;
}

function probe(firestore: Firestore) {
  return doc(firestore, COLLECTIONS.bindings, randomUUID());
}

async function assertPermissionDenied(operation: Promise<unknown>): Promise<void> {
  await assert.rejects(operation, (error: unknown) => {
    return (
      error !== null &&
      typeof error === 'object' &&
      'code' in error &&
      error.code === 'permission-denied'
    );
  });
}
