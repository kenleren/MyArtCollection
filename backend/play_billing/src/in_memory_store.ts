import { BILLING_DATABASE_ID } from './constants.js';
import type { BillingCollection, BillingDatabase, BillingTransaction, ReconciliationDue } from './store.js';

export class InMemoryBillingDatabase implements BillingDatabase {
  readonly databaseId = BILLING_DATABASE_ID;
  private records = new Map<string, unknown>();
  private transactionTail: Promise<void> = Promise.resolve();

  async dueEventWork(now: Date, limit: number): Promise<string[]> {
    if (!Number.isInteger(limit) || limit < 1 || limit > 10) throw new Error('billing event unsafe');
    return [...this.records.entries()].filter(([path, value]) => {
      const row = value as { state?: string; dueAt?: Date };
      return path.startsWith('playBillingEventWork/') && ['ready','retry','working'].includes(row.state ?? '') && row.dueAt instanceof Date && row.dueAt <= now;
    }).sort(([a,av], [b,bv]) => (av as {dueAt:Date}).dueAt.getTime() - (bv as {dueAt:Date}).dueAt.getTime() || a.localeCompare(b))
      .slice(0,limit).map(([path]) => path.slice(path.indexOf('/')+1));
  }

  async dueReconciliationWork(now: Date, limit: number): Promise<ReconciliationDue[]> {
    if (!Number.isInteger(limit) || limit < 1 || limit > 10) throw new Error('billing reconciliation unsafe');
    return [...this.records.entries()].filter(([path, value]) => {
      const row = value as { state?: string; dueAt?: Date };
      return path.startsWith('playBillingReconcileWork/') && ['ready','retry','working'].includes(row.state ?? '') && row.dueAt instanceof Date && row.dueAt <= now;
    }).sort(([a,av], [b,bv]) => (av as {dueAt:Date}).dueAt.getTime() - (bv as {dueAt:Date}).dueAt.getTime() || a.localeCompare(b))
      .slice(0,limit).map(([path,value]) => {const row=value as ReconciliationDue;return {accountSubject:path.slice(path.indexOf('/')+1),dueAt:new Date(row.dueAt),...(row.lastSuccessfulVerificationAt===undefined?{}:{lastSuccessfulVerificationAt:new Date(row.lastSuccessfulVerificationAt)})};});
  }

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
        findSubjectBinding: async (subject) => {
          for (const [path, value] of working) {
            if (path.startsWith('playBillingPurchaseBindings/') && value !== null && typeof value === 'object' &&
                'accountSubject' in value && value.accountSubject === subject) return structuredClone(value);
          }
          return undefined;
        },
        findSubjectRoute: async (subject) => {
          for (const [path, value] of working) {
            if (path.startsWith('playBillingAccountRoutes/') && value !== null && typeof value === 'object' &&
                'accountSubject' in value && value.accountSubject === subject) return structuredClone(value);
          }
          return undefined;
        },
        findSubjectBrokerRoute: async (subject) => {
          for (const [path, value] of working) {
            if (path.startsWith('playBillingBrokerRoutes/') && value !== null && typeof value === 'object' &&
                'accountSubject' in value && value.accountSubject === subject) return structuredClone(value);
          }
          return undefined;
        },
        findAnyEventWork: async () => {
          for (const [path, value] of working) if (path.startsWith('playBillingEventWork/')) return structuredClone(value);
          return undefined;
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
