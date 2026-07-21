import { readFileSync } from "node:fs";
import { resolve } from "node:path";
const fixture = JSON.parse(readFileSync(resolve(process.cwd(), "evidence/restore-fixture.v1.json"), "utf8"));
if (fixture.rows.length === 0)
    throw new Error("restore fixture lost rows");
