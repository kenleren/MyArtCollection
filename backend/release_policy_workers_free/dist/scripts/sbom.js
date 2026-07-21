import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
const root = resolve(process.cwd());
const lock = JSON.parse(readFileSync(resolve(root, "package-lock.json"), "utf8"));
writeFileSync(resolve(root, "evidence/sbom.spdx.json"), JSON.stringify({ SPDXID: "SPDXRef-DOCUMENT", spdxVersion: "SPDX-2.3", name: lock.name, packages: [{ SPDXID: "SPDXRef-Package", name: lock.name, versionInfo: lock.version }] }) + "\n");
