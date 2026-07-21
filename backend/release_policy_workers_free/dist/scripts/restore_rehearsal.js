import { readFileSync } from "node:fs";
import { resolve } from "node:path";
const fixture = JSON.parse(readFileSync(resolve(process.cwd(), "evidence/restore-fixture.v1.json"), "utf8"));
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
