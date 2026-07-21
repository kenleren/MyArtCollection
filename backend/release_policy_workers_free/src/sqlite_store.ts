import type { DurableStorage } from "./platform.js";

export class CasConflict extends Error {}
export interface Transaction { get(key: string): unknown; putIfAbsent(key: string, value: unknown): void; compareAndSwap(key: string, version: number, value: unknown): void }
export class SqliteStore {
  constructor(private readonly storage: DurableStorage) {
    this.storage.sql.exec("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, version INTEGER NOT NULL, value_json TEXT NOT NULL)");
    this.storage.sql.exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value_json TEXT NOT NULL)");
    this.storage.sql.exec("INSERT INTO meta(key,value_json) VALUES('schema_version','1') ON CONFLICT(key) DO NOTHING");
  }
  async transact<T>(work: (transaction: Transaction) => T): Promise<T> {
    // Durable Object SQLite owns the transaction boundary; issuing BEGIN here
    // would create a nested transaction and weaken its atomicity contract.
    return this.storage.transactionSync(() => work(new SqliteTransaction(this.storage)));
  }
  async read(key: string): Promise<unknown> { const row = this.storage.sql.exec("SELECT value_json FROM kv WHERE key=?", key).toArray()[0] as { value_json: string } | undefined; return row === undefined ? undefined : JSON.parse(row.value_json); }
  /** Internal scheduler inventory. Core durable keys/values remain unchanged. */
  entries(prefix: string): Array<{ key: string; value: unknown }> {
    if (!/^(receipt|generation|outbox|push-child|binding|current)\/$/.test(prefix)) throw new Error("scheduler prefix rejected");
    return (this.storage.sql.exec("SELECT key,value_json FROM kv WHERE key LIKE ? ORDER BY key", `${prefix}%`).toArray() as Array<{ key: string; value_json: string }>).map((row) => ({ key: row.key, value: JSON.parse(row.value_json) }));
  }
  rowCount(): number { return Number((this.storage.sql.exec("SELECT count(*) AS count FROM kv").toArray()[0] as { count: number }).count); }
  databaseBytes(): number { const bytes = this.storage.sql.databaseSize; if (!Number.isSafeInteger(bytes) || bytes < 0) throw new Error("SQLite storage measurement unavailable"); return bytes; }
  readMeta<T>(key: string): T | undefined { const row = this.storage.sql.exec("SELECT value_json FROM meta WHERE key=?", key).toArray()[0] as { value_json: string } | undefined; return row === undefined ? undefined : JSON.parse(row.value_json) as T; }
  writeMeta(key: string, value: unknown): void { this.storage.sql.exec("INSERT INTO meta(key,value_json) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json", key, JSON.stringify(value)); }
  incrementMeta(key: string, amount = 1, ceiling = 1_000_000): number { const prior = this.readMeta<number>(key); const base = prior === undefined ? 0 : typeof prior === "number" && Number.isSafeInteger(prior) && prior >= 0 ? prior : ceiling; const next = Math.min(base + amount, ceiling); this.writeMeta(key, next); return next; }
}
class SqliteTransaction implements Transaction {
  constructor(private readonly storage: DurableStorage) {}
  get(key: string): unknown { const row = this.storage.sql.exec("SELECT value_json FROM kv WHERE key=?", key).toArray()[0] as { value_json: string } | undefined; return row === undefined ? undefined : JSON.parse(row.value_json); }
  putIfAbsent(key: string, value: unknown): void { const encoded = JSON.stringify(value); const row = this.storage.sql.exec("INSERT INTO kv(key,version,value_json) VALUES(?,1,?) ON CONFLICT(key) DO NOTHING RETURNING key", key, encoded).toArray()[0]; if (row === undefined) throw new CasConflict("unique key already exists"); }
  compareAndSwap(key: string, version: number, value: unknown): void { const row = this.storage.sql.exec("UPDATE kv SET version=version+1,value_json=? WHERE key=? AND version=? RETURNING key", JSON.stringify(value), key, version).toArray()[0]; if (row === undefined) throw new CasConflict("CAS lost"); }
}
