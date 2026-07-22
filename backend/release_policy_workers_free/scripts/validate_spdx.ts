import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
const get = (name: string): string => { const i = process.argv.indexOf(`--${name}`); const value = i < 0 ? undefined : process.argv[i + 1]; if (!value) throw new Error(`SPDX ${name} required`); return value; };
const anchor = get("anchor"); const root = resolve(process.cwd()); const repositoryRoot = execFileSync("git", ["-C", root, "rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim(); const inputValue = get("input"); const input = inputValue.startsWith("backend/release_policy_workers_free/") ? resolve(repositoryRoot, inputValue) : resolve(inputValue);
if (!/^[0-9a-f]{40}$/.test(anchor)) throw new Error("SPDX anchor rejected");
const git = (...args: string[]) => execFileSync("git", ["-C", root, ...args], { encoding: "utf8" }).trim();
const epoch = Number(git("show", "-s", "--format=%ct", anchor)); const lock = execFileSync("git", ["-C", root, "show", `${anchor}:backend/release_policy_workers_free/package-lock.json`]);
const doc = JSON.parse(readFileSync(input, "utf8")) as Record<string, unknown>;
const expectedNamespace = `https://archivale.app/spdx/release-policy-workers-free/${anchor}/${createHash("sha256").update(lock).digest("hex")}`;
if (doc.spdxVersion !== "SPDX-2.3" || doc.SPDXID !== "SPDXRef-DOCUMENT" || doc.dataLicense !== "CC0-1.0" || doc.documentNamespace !== expectedNamespace || (doc.creationInfo as Record<string, unknown> | undefined)?.created !== new Date(epoch * 1000).toISOString().replace(".000", "")) throw new Error("SPDX document metadata rejected");
const packages = doc.packages; const relationships = doc.relationships;
if (!Array.isArray(packages) || packages.length === 0 || !Array.isArray(relationships)) throw new Error("SPDX graph rejected");
const ids = new Set<string>(); for (const pkg of packages) { if (!pkg || typeof pkg !== "object") throw new Error("SPDX package rejected"); const row = pkg as Record<string, unknown>; if (typeof row.SPDXID !== "string" || ids.has(row.SPDXID) || typeof row.name !== "string" || typeof row.versionInfo !== "string" || row.downloadLocation !== "NOASSERTION" || row.filesAnalyzed !== false || row.licenseConcluded !== "NOASSERTION" || row.licenseDeclared !== "NOASSERTION" || row.copyrightText !== "NOASSERTION") throw new Error("SPDX package rejected"); ids.add(row.SPDXID); }
if (!relationships.some((row) => row && typeof row === "object" && (row as Record<string, unknown>).spdxElementId === "SPDXRef-DOCUMENT" && (row as Record<string, unknown>).relationshipType === "DESCRIBES" && ids.has((row as Record<string, unknown>).relatedSpdxElement as string))) throw new Error("SPDX relationship rejected");
for (const relationship of relationships) { if (!relationship || typeof relationship !== "object") throw new Error("SPDX relationship rejected"); const row = relationship as Record<string, unknown>; if (!ids.has(row.spdxElementId as string) && row.spdxElementId !== "SPDXRef-DOCUMENT") throw new Error("SPDX relationship rejected"); if (!ids.has(row.relatedSpdxElement as string)) throw new Error("SPDX relationship rejected"); }
