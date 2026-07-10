import { BILLING_DATABASE_ID } from './constants.js';
import type { BillingCollection, BillingDatabase, BillingTransaction } from './store.js';

export class InMemoryBillingDatabase implements BillingDatabase {
  readonly databaseId = BILLING_DATABASE_ID;
  private records = new Map<string, unknown>();
  private transactionTail: Promise<void> = Promise.resolve();

  async runTransaction<T>(
    operation: (transaction: BillingTransaction) => Promise<T>,
  ): Promise<T> {
    const previous = this.transactionTail;
    let release!: () => void;
    this.transactionTail = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    try {
      const working = structuredClone(this.records);
      const transaction: BillingTransaction = {
        get: async <Value>(collection: BillingCollection, id: string) => {
          const value = working.get(key(collection, id));
          return value === undefined ? undefined : structuredClone(value as Value);
        },
        set: <Value>(collection: BillingCollection, id: string, value: Value) => {
          working.set(key(collection, id), structuredClone(value));
        },
      };
      const result = await operation(transaction);
      this.records = working;
      return result;
    } finally {
      release();
    }
  }

  snapshotForTest(): Map<string, unknown> {
    return structuredClone(this.records);
  }

  setUnsafeRecordForTest(collection: BillingCollection, id: string, value: unknown): void {
    this.records.set(key(collection, id), structuredClone(value));
  }

  deleteRecordForTest(collection: BillingCollection, id: string): void {
    this.records.delete(key(collection, id));
  }
}

function key(collection: BillingCollection, id: string): string {
  return `${collection}/${id}`;
}
