/** Minimal structural Cloudflare surface; production bindings are supplied by Workers. */
export interface Sql { readonly databaseSize: number; exec(query: string, ...values: unknown[]): { toArray(): unknown[] } }
export interface DurableStorage { sql: Sql; transactionSync<T>(work: () => T): T; setAlarm(time: number): Promise<void>; getAlarm(): Promise<number | null> }
export interface DurableState { storage: DurableStorage; blockConcurrencyWhile<T>(work: () => Promise<T>): Promise<T> }
export interface DurableStub { fetch(input: Request): Promise<Response> }
export interface DurableNamespace { idFromName(name: string): unknown; get(id: unknown): DurableStub }
