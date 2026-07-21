import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
const root = resolve(process.cwd());
const lock = JSON.parse(readFileSync(resolve(root, "package-lock.json"), "utf8"));
const packages = Object.entries(lock.packages).map(([path, row]) => ({ SPDXID: `SPDXRef-${path || "root"}`.replace(/[^A-Za-z0-9.-]/g, "-"), name: row.name ?? (path || lock.name), versionInfo: row.version ?? lock.version, ...(row.integrity ? { checksums: [{ algorithm: "SHA256", checksumValue: row.integrity.replace(/^sha512-/, "") }] } : {}) })).sort((a, b) => a.SPDXID.localeCompare(b.SPDXID));
writeFileSync(resolve(root, "evidence/sbom.spdx.json"), JSON.stringify({ SPDXID: "SPDXRef-DOCUMENT", spdxVersion: "SPDX-2.3", name: lock.name, packages }) + "\n");
