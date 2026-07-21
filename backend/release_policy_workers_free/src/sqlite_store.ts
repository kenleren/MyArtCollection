import { sha256 } from "@archivale/release-policy-trust";
import type { DurableStorage } from "./platform.js";
import { reserveQuota, type QuotaVector } from "./quota.js";

export class CasConflict extends Error {}
export class IncompatibleSqliteSchema extends Error {}
export interface Transaction { get(key: string): unknown; putIfAbsent(key: string, value: unknown): void; compareAndSwap(key: string, version: number, value: unknown): void }
export const SQLITE_SCHEMA_ID = "archivale-release-policy-workers-free/sqlite-v2";
export const KV_DDL = "CREATE TABLE kv(key TEXT NOT NULL PRIMARY KEY,version INTEGER NOT NULL CHECK(version>=1),value_json TEXT NOT NULL CHECK(json_valid(value_json))) STRICT, WITHOUT ROWID";
export const META_DDL = "CREATE TABLE meta(key TEXT NOT NULL PRIMARY KEY,value_json TEXT NOT NULL CHECK(json_valid(value_json))) STRICT, WITHOUT ROWID";
const SCHEMA_PREIMAGE = `schema_id=${SQLITE_SCHEMA_ID}\nschema_version=2\nobject.1=table|kv|${KV_DDL}\nobject.2=table|meta|${META_DDL}\napplication_indexes=none\napplication_triggers=none\napplication_views=none\nmetadata.1=activation/digest|json-string|sha256:<64-lower-hex>\nmetadata.2=compatibility/digest|json-string|sha256:<64-lower-hex>\nmetadata.3=schema/digest|json-string|sha256:<64-lower-hex>\nmetadata.4=schema/id|json-string|${SQLITE_SCHEMA_ID}\nmetadata.5=schema/state|json-string|ready\nmetadata.6=schema/version|json-integer|2\n`;
export const SQLITE_SCHEMA_DIGEST = `sha256:${sha256(SCHEMA_PREIMAGE)}`;
const expectedMetadata = (activationDigest: string, compatibilityDigest: string): Record<string, string> => ({ "schema/id": JSON.stringify(SQLITE_SCHEMA_ID), "schema/version": "2", "schema/state": JSON.stringify("ready"), "schema/digest": JSON.stringify(SQLITE_SCHEMA_DIGEST), "compatibility/digest": JSON.stringify(compatibilityDigest), "activation/digest": JSON.stringify(activationDigest) });
const rowArray = (storage: DurableStorage, sql: string, ...values: unknown[]): Array<Record<string, unknown>> => storage.sql.exec(sql, ...values).toArray() as Array<Record<string, unknown>>;
export class SqliteStore {
  constructor(private readonly storage: DurableStorage) {}
  /** This must run in blockConcurrencyWhile before a dispatcher or port exists. */
  initialize(activationDigest: string, compatibilityDigest: string): void {
    if (!/^sha256:[0-9a-f]{64}$/.test(activationDigest) || !/^sha256:[0-9a-f]{64}$/.test(compatibilityDigest)) throw new IncompatibleSqliteSchema("activation identity rejected");
    this.storage.transactionSync(() => {
      const objects = rowArray(this.storage, "SELECT type,name,sql FROM sqlite_schema WHERE name NOT LIKE '_cf_%' ORDER BY type,name");
      if (objects.length === 0) {
        this.storage.sql.exec(KV_DDL); this.storage.sql.exec(META_DDL);
        for (const [key, value] of Object.entries(expectedMetadata(activationDigest, compatibilityDigest))) this.storage.sql.exec("INSERT INTO meta(key,value_json) VALUES(?,?)", key, value);
        this.assertCompatible(activationDigest, compatibilityDigest); return;
      }
      this.assertCompatible(activationDigest, compatibilityDigest);
    });
  }
  private assertCompatible(activationDigest: string, compatibilityDigest: string): void {
    const objects = rowArray(this.storage, "SELECT type,name,sql FROM sqlite_schema WHERE name NOT LIKE '_cf_%' ORDER BY type,name");
    const tables = objects.filter((row) => row.type === "table");
    const expected = [{ type: "table", name: "kv", sql: KV_DDL }, { type: "table", name: "meta", sql: META_DDL }];
    if (JSON.stringify(tables) !== JSON.stringify(expected) || objects.some((row) => row.type !== "table")) throw new IncompatibleSqliteSchema("application schema rejected");
    for (const table of ["kv", "meta"]) {
      const columns = rowArray(this.storage, `PRAGMA table_xinfo(${table})`); const expectedColumns = table === "kv" ? ["key", "version", "value_json"] : ["key", "value_json"];
      if (columns.length !== expectedColumns.length || columns.some((row, index) => row.name !== expectedColumns[index] || row.hidden !== 0) || rowArray(this.storage, `PRAGMA foreign_key_list(${table})`).length !== 0) throw new IncompatibleSqliteSchema("application columns rejected");
      const indexes = rowArray(this.storage, `PRAGMA index_list(${table})`); if (indexes.length !== 1 || indexes[0]?.name !== `sqlite_autoindex_${table}_1` || indexes[0]?.unique !== 1 || indexes[0]?.origin !== "pk" || indexes[0]?.partial !== 0) throw new IncompatibleSqliteSchema("application index rejected");
    }
    const values = Object.fromEntries(rowArray(this.storage, "SELECT key,value_json FROM meta WHERE key IN ('schema/id','schema/version','schema/state','schema/digest','compatibility/digest','activation/digest') ORDER BY key").map((row) => [row.key as string, row.value_json as string]));
    const wanted = expectedMetadata(activationDigest, compatibilityDigest); const wantedSorted = Object.fromEntries(Object.entries(wanted).sort(([a], [b]) => a.localeCompare(b))); if (JSON.stringify(values) !== JSON.stringify(wantedSorted)) throw new IncompatibleSqliteSchema("application metadata rejected");
  }
  async transact<T>(work: (transaction: Transaction) => T): Promise<T> { return this.storage.transactionSync(() => work(new SqliteTransaction(this.storage))); }
  async read(key: string): Promise<unknown> { const row = rowArray(this.storage, "SELECT value_json FROM kv WHERE key=?", key)[0] as { value_json: string } | undefined; return row === undefined ? undefined : JSON.parse(row.value_json); }
  entries(prefix: string): Array<{ key: string; value: unknown }> { if (!/^(receipt|generation|outbox|push-child|binding|current)\/$/.test(prefix)) throw new Error("scheduler prefix rejected"); return rowArray(this.storage, "SELECT key,value_json FROM kv WHERE key LIKE ? ORDER BY key", `${prefix}%`).map((row) => ({ key: row.key as string, value: JSON.parse(row.value_json as string) })); }
  rowCount(): number { return Number((rowArray(this.storage, "SELECT count(*) AS count FROM kv")[0] as { count: number }).count); }
  databaseBytes(): number { const bytes = this.storage.sql.databaseSize; if (!Number.isSafeInteger(bytes) || bytes < 0) throw new Error("SQLite storage measurement unavailable"); return bytes; }
  reserveQuota(now: number, vector: QuotaVector) { return reserveQuota(this.storage, now, vector); }
  readMeta<T>(key: string): T | undefined { const row = rowArray(this.storage, "SELECT value_json FROM meta WHERE key=?", key)[0] as { value_json: string } | undefined; return row === undefined ? undefined : JSON.parse(row.value_json) as T; }
  writeMeta(key: string, value: unknown): void { this.storage.sql.exec("INSERT INTO meta(key,value_json) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json", key, JSON.stringify(value)); }
  incrementMeta(key: string, amount = 1, ceiling = 1_000_000): number { const prior = this.readMeta<number>(key); const base = prior === undefined ? 0 : typeof prior === "number" && Number.isSafeInteger(prior) && prior >= 0 ? prior : ceiling; const next = Math.min(base + amount, ceiling); this.writeMeta(key, next); return next; }
}
class SqliteTransaction implements Transaction {
  constructor(private readonly storage: DurableStorage) {}
  get(key: string): unknown { const row = rowArray(this.storage, "SELECT value_json FROM kv WHERE key=?", key)[0] as { value_json: string } | undefined; return row === undefined ? undefined : JSON.parse(row.value_json); }
  putIfAbsent(key: string, value: unknown): void { const row = this.storage.sql.exec("INSERT INTO kv(key,version,value_json) VALUES(?,1,?) ON CONFLICT(key) DO NOTHING RETURNING key", key, JSON.stringify(value)).toArray()[0]; if (row === undefined) throw new CasConflict("unique key already exists"); }
  compareAndSwap(key: string, version: number, value: unknown): void { const row = this.storage.sql.exec("UPDATE kv SET version=version+1,value_json=? WHERE key=? AND version=? RETURNING key", JSON.stringify(value), key, version).toArray()[0]; if (row === undefined) throw new CasConflict("CAS lost"); }
}
