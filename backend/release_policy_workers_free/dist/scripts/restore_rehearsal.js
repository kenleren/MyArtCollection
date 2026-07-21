import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
const root = resolve(process.cwd());
const fixtureBytes = readFileSync(resolve(root, "evidence/restore-fixture.v1.json"));
const fixture = JSON.parse(fixtureBytes.toString("utf8"));
if (!Array.isArray(fixture.rows) || fixture.rows.length === 0)
    throw new Error("restore fixture lost rows");
const keys = new Set();
for (const row of fixture.rows) {
    if (typeof row.durable_row !== "string" || !/^(receipt|generation|outbox|push-child)\//.test(row.durable_row) || typeof row.version !== "number" || !Number.isSafeInteger(row.version) || row.version < 1 || typeof row.value_json !== "string")
        throw new Error("restore fixture schema rejected");
    if (keys.has(row.durable_row))
        throw new Error("restore fixture duplicates durable row");
    keys.add(row.durable_row);
    JSON.parse(row.value_json);
}
// Fixture rows are canonical durable input only; restoration must preserve every
// row and never reconstruct an external Check Run from fixture data.
if ([...keys].some((key) => /(?:token|secret|authorization|headers?|body)/i.test(key)))
    throw new Error("restore fixture contains forbidden material");
const directory = mkdtempSync(resolve(tmpdir(), "archivale-restore-rehearsal-"));
const databasePath = resolve(directory, "durable.sqlite");
let quickCheck = "";
let restoredRows = 0;
let forbiddenMaterial = 0;
try {
    const restored = new DatabaseSync(databasePath);
    restored.exec("CREATE TABLE kv (key TEXT PRIMARY KEY, version INTEGER NOT NULL, value_json TEXT NOT NULL)");
    restored.exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value_json TEXT NOT NULL)");
    restored.exec("INSERT INTO meta(key,value_json) VALUES('schema_version','1')");
    const insert = restored.prepare("INSERT INTO kv(key,version,value_json) VALUES(?,?,?)");
    restored.exec("BEGIN IMMEDIATE");
    try {
        for (const row of fixture.rows)
            insert.run(row.durable_row, row.version, row.value_json);
        restored.exec("COMMIT");
    }
    catch (error) {
        restored.exec("ROLLBACK");
        throw error;
    }
    restored.close();
    const reopened = new DatabaseSync(databasePath, { readOnly: true });
    reopened.exec("PRAGMA query_only=ON");
    quickCheck = String(reopened.prepare("PRAGMA quick_check").get().quick_check);
    const schemaVersion = reopened.prepare("SELECT value_json FROM meta WHERE key='schema_version'").get();
    if (quickCheck !== "ok" || schemaVersion?.value_json !== "1")
        throw new Error("restored SQLite integrity rejected");
    const rows = reopened.prepare("SELECT key,version,value_json FROM kv ORDER BY key").all();
    const expected = fixture.rows.map((row) => ({ key: row.durable_row, version: row.version, value_json: row.value_json })).sort((a, b) => String(a.key).localeCompare(String(b.key)));
    if (JSON.stringify(rows) !== JSON.stringify(expected))
        throw new Error("restored durable rows differ from fixture");
    restoredRows = rows.length;
    forbiddenMaterial = rows.filter((row) => /(?:token|secret|authorization|headers?)/i.test(`${row.key}\n${row.value_json}`)).length;
    if (forbiddenMaterial !== 0)
        throw new Error("restored SQLite contains forbidden material");
    reopened.close();
}
finally {
    rmSync(directory, { recursive: true, force: true });
}
if (existsSync(directory))
    throw new Error("restore rehearsal temporary directory survived cleanup");
const evidence = { schema_version: 1, fixture_sha256: createHash("sha256").update(fixtureBytes).digest("hex"), sqlite_quick_check: quickCheck, row_count: restoredRows, exact_row_match: true, closed_reopen_read_only: true, forbidden_material_count: forbiddenMaterial, temp_cleanup: true };
writeFileSync(resolve(root, "evidence/restore-rehearsal.v1.json"), JSON.stringify(evidence) + "\n");
console.log(`restore rehearsal passed (${restoredRows} durable rows)`);
