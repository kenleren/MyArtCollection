import type {
  Firestore,
  Transaction,
} from 'firebase-admin/firestore';
import { Timestamp } from 'firebase-admin/firestore';

import { BILLING_DATABASE_ID } from './constants.js';
import type { BillingCollection, BillingDatabase, BillingTransaction, ReconciliationDue } from './store.js';

export class FirestoreBillingDatabase implements BillingDatabase {
  readonly databaseId = BILLING_DATABASE_ID;

  constructor(private readonly firestore: Firestore) {
    if (firestore.databaseId !== BILLING_DATABASE_ID) {
      throw new Error('billing Firestore database mismatch');
    }
  }

  async dueEventWork(now: Date, limit: number): Promise<string[]> {
    if (!Number.isInteger(limit) || limit < 1 || limit > 10) throw new Error('billing event unsafe');
    const snapshot = await this.firestore.collection('playBillingEventWork')
      .where('state', 'in', ['ready','retry','working']).where('dueAt', '<=', now)
      .orderBy('dueAt').orderBy('__name__').limit(limit).get();
    return snapshot.docs.map(doc => doc.id);
  }

  async dueReconciliationWork(now: Date, limit: number): Promise<ReconciliationDue[]> {
    if (!Number.isInteger(limit) || limit < 1 || limit > 10) throw new Error('billing reconciliation unsafe');
    const snapshot = await this.firestore.collection('playBillingReconcileWork')
      .where('state', 'in', ['ready','retry','working']).where('dueAt', '<=', now)
      .orderBy('dueAt').orderBy('__name__').limit(limit).select('dueAt','lastSuccessfulVerificationAt').get();
    return snapshot.docs.map(doc => {
      const v=normalizeFirestoreValue(doc.data()) as {dueAt:Date;lastSuccessfulVerificationAt?:Date};
      return {accountSubject:doc.id,dueAt:v.dueAt,...(v.lastSuccessfulVerificationAt===undefined?{}:{lastSuccessfulVerificationAt:v.lastSuccessfulVerificationAt})};
    });
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
    findSubjectBinding: async (subject) => {
      const result = await transaction.get(firestore.collection('playBillingPurchaseBindings').where('accountSubject', '==', subject).limit(1));
      return result.empty ? undefined : normalizeFirestoreValue(result.docs[0]!.data());
    },
    findSubjectRoute: async (subject) => {
      const result = await transaction.get(firestore.collection('playBillingAccountRoutes').where('accountSubject', '==', subject).limit(1));
      return result.empty ? undefined : normalizeFirestoreValue(result.docs[0]!.data());
    },
    findAnyEventWork: async () => {
      const result = await transaction.get(firestore.collection('playBillingEventWork').limit(1));
      return result.empty ? undefined : normalizeFirestoreValue(result.docs[0]!.data());
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
