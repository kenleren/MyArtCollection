import { controlRecordFromSnapshot, entitlementRecordFromSnapshot, FirestoreDurableBrokerStore, type DurableFirestoreLike } from './durable_protection.js';
import { fail } from './credit_identity_protocol.js';
export const CREDIT_COLLECTIONS = {
    control: 'brokerCreditIdentityControl', accounts: 'brokerCreditAccounts', routes: 'brokerCreditRoutes', authority: 'brokerCreditAuthority'
} as const;
export type CreditCollection = (typeof CREDIT_COLLECTIONS)[keyof typeof CREDIT_COLLECTIONS];
export interface CreditTransaction {
    get<T>(collection: string, id: string): Promise<T | undefined>;
    set<T>(collection: string, id: string, value: T): void;
    readOperator(uid: string): Promise<{
        entitled: boolean;
        breakerOpen: boolean;
    }>;
    findAccountRoute(accountSubject: string): Promise<unknown | undefined>;
    /** Bounded internal accounting query; never a client-supplied collection. */
    findFirst?(collection: string, field?: string, value?: string): Promise<unknown | undefined>;
}
export interface CreditIdentityDatabase {
    readonly collectionPrefix?: string;
    transaction<T>(work: (tx: CreditTransaction) => Promise<T>): Promise<T>;
}
/** Broker default DB only. No billing DB access or durable UID locator in bridge collections. */
export class FirestoreCreditIdentityDatabase implements CreditIdentityDatabase {
    private readonly old: FirestoreDurableBrokerStore;
    constructor(private readonly firestore: DurableFirestoreLike & {
        databaseId?: string;
        collection?: (path: string) => any;
    }, legacyStore?: FirestoreDurableBrokerStore) {
        if (legacyStore && legacyStore.firestore !== firestore) fail();
        if (firestore.databaseId !== '(default)')
            fail();
        this.old = legacyStore ?? new FirestoreDurableBrokerStore(firestore);
    }
    get collectionPrefix(): string { return this.old.collectionPrefix; }
    transaction<T>(work: (tx: CreditTransaction) => Promise<T>): Promise<T> {
        return this.firestore.runTransaction(async (raw) => work({
            get: async <V>(collection: string, id: string) => { const s = await raw.get(this.firestore.doc(`${collection}/${id}`)); return s.exists ? normalize(s.data()) as V : undefined; },
            set: <V>(collection: string, id: string, value: V) => { raw.set(this.firestore.doc(`${collection}/${id}`), value as Record<string, unknown>); },
            readOperator: async (uid) => {
                const [a, b] = await Promise.all([raw.get(this.old.controlRef()), raw.get(this.old.entitlementRef(uid))]);
                const control = controlRecordFromSnapshot(a), entitlement = b.exists ? entitlementRecordFromSnapshot(b) : {
                    entitled: false
                };
                if (!control || !entitlement)
                    fail();
                return {
                    breakerOpen: control.breakerOpen, entitled: entitlement.entitled
                };
            },
            findFirst: async (collection, field, value) => {
                if (!this.firestore.collection) fail();
                let query = this.firestore.collection(collection);
                if (field !== undefined) query = query.where(field, '==', value);
                const result = await (raw as any).get(query.limit(1));
                return result.empty ? undefined : normalize(result.docs[0].data());
            },
            findAccountRoute: async (subject) => {
                if (!this.firestore.collection)
                    fail();
                const query = this.firestore.collection(CREDIT_COLLECTIONS.routes).where('accountSubject', '==', subject).limit(1);
                const result = await (raw as any).get(query);
                return result.empty ? undefined : normalize(result.docs[0].data());
            },
        }));
    }
}
function normalize(value: any): any {
    if (value && typeof value.toDate === 'function')
        return value.toDate();
    if (value instanceof Date)
        return new Date(value);
    if (Array.isArray(value))
        return value.map(normalize);
    if (value && typeof value === 'object')
        return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, normalize(v)]));
    return value;
}
/** Deterministic serial transactions for synthetic tests; never selected by a live factory. */
export class InMemoryCreditIdentityDatabase implements CreditIdentityDatabase {
    constructor(readonly collectionPrefix = 'brokerDurable') {}
    private rows = new Map<string, unknown>();
    private tail: Promise<void> = Promise.resolve();
    private operators = new Map<string, {
        entitled: boolean;
        breakerOpen: boolean;
    }>();
    beforeTransaction?: () => Promise<void>;
    afterTransaction?: () => Promise<void>;
    async transaction<T>(work: (tx: CreditTransaction) => Promise<T>): Promise<T> {
        await this.beforeTransaction?.();
        const prior = this.tail;
        let release!: () => void;
        this.tail = new Promise<void>(r => release = r);
        await prior;
        let result: T;
        try {
            const rows = structuredClone(this.rows);
            result = await work({
                get: async <V>(c: string, id: string) => structuredClone(rows.get(`${c}/${id}`)) as V | undefined,
                set: (c, id, v) => { rows.set(`${c}/${id}`, structuredClone(v)); }, readOperator: async (uid) => {
                    const v = this.operators.get(uid);
                    if (!v)
                        fail();
                    return {
                        ...v
                    };
                },
                findFirst: async (collection, field, value) => {
                    for (const [path, row] of rows)
                        if (path.startsWith(collection + '/') && (field === undefined || (row as any)?.[field] === value))
                            return structuredClone(row);
                    return undefined;
                },
                findAccountRoute: async (subject) => {
                    for (const [path, v] of rows)
                        if (path.startsWith(`${CREDIT_COLLECTIONS.routes}/`) && (v as any)?.accountSubject === subject)
                            return structuredClone(v);
                    return undefined;
                }
            });
            this.rows = rows;
        }
        finally {
            release();
        }
        await this.afterTransaction?.();
        return result!;
    }
    setOperator(uid: string, value: {
        entitled: boolean;
        breakerOpen: boolean;
    }): void { this.operators.set(uid, {
        ...value
    }); }
    setForTest(c: string, id: string, value: unknown): void { this.rows.set(`${c}/${id}`, structuredClone(value)); }
    deleteForTest(c: string, id: string): void { this.rows.delete(`${c}/${id}`); }
    snapshotForTest(): Map<string, unknown> { return structuredClone(this.rows); }
}
