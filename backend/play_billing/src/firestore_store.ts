import type {
  Firestore,
  Transaction,
} from 'firebase-admin/firestore';
import { Timestamp } from 'firebase-admin/firestore';

import { BILLING_DATABASE_ID } from './constants.js';
import type { BillingCollection, BillingDatabase, BillingTransaction } from './store.js';

export class FirestoreBillingDatabase implements BillingDatabase {
  readonly databaseId = BILLING_DATABASE_ID;

  constructor(private readonly firestore: Firestore) {
    if (firestore.databaseId !== BILLING_DATABASE_ID) {
      throw new Error('billing Firestore database mismatch');
    }
  }

  runTransaction<T>(operation: (transaction: BillingTransaction) => Promise<T>): Promise<T> {
    return this.firestore.runTransaction(async (firestoreTransaction) =>
      operation(createTransactionAdapter(this.firestore, firestoreTransaction)),
    );
  }
}

function createTransactionAdapter(
  firestore: Firestore,
  transaction: Transaction,
): BillingTransaction {
  return {
    get: async <Value>(collection: BillingCollection, id: string) => {
      const snapshot = await transaction.get(firestore.collection(collection).doc(id));
      return snapshot.exists ? (normalizeFirestoreValue(snapshot.data()) as Value) : undefined;
    },
    set: <Value>(collection: BillingCollection, id: string, value: Value) => {
      transaction.set(
        firestore.collection(collection).doc(id),
        removeUndefinedValues(value) as FirebaseFirestore.DocumentData,
      );
    },
  };
}

function normalizeFirestoreValue(value: unknown): unknown {
  if (value instanceof Timestamp) {
    return value.toDate();
  }
  if (Array.isArray(value)) {
    return value.map(normalizeFirestoreValue);
  }
  if (value !== null && typeof value === 'object' && !(value instanceof Uint8Array)) {
    return Object.fromEntries(
      Object.entries(value).map(([key, nested]) => [key, normalizeFirestoreValue(nested)]),
    );
  }
  return value;
}

function removeUndefinedValues(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(removeUndefinedValues);
  }
  if (
    value !== null &&
    typeof value === 'object' &&
    !(value instanceof Date) &&
    !(value instanceof Uint8Array)
  ) {
    return Object.fromEntries(
      Object.entries(value)
        .filter(([, nested]) => nested !== undefined)
        .map(([key, nested]) => [key, removeUndefinedValues(nested)]),
    );
  }
  return value;
}
