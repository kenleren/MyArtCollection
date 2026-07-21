import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
const value = (name) => { const i = process.argv.indexOf(`--${name}`); const result = i < 0 ? undefined : process.argv[i + 1]; if (!result || result.startsWith("--"))
    throw new Error(`SBOM ${name} required`); return result; };
const root = resolve(process.cwd());
const repositoryRoot = execFileSync("git", ["-C", root, "rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
const anchoredPath = (input) => input.startsWith("backend/release_policy_workers_free/") ? resolve(repositoryRoot, input) : resolve(input);
const anchor = value("anchor");
const output = anchoredPath(value("output"));
const lockInput = process.argv.includes("--lock") ? anchoredPath(value("lock")) : resolve(root, "package-lock.json");
if (!/^[0-9a-f]{40}$/.test(anchor) || !output || output === root || !lockInput)
    throw new Error("SBOM anchor rejected");
const git = (...args) => execFileSync("git", ["-C", root, ...args], { encoding: "utf8" }).trim();
const epoch = Number(git("show", "-s", "--format=%ct", anchor));
if (!Number.isSafeInteger(epoch))
    throw new Error("SBOM epoch rejected");
const lockBytes = readFileSync(lockInput);
const lock = JSON.parse(lockBytes.toString("utf8"));
const hash = (input) => createHash("sha256").update(input).digest("hex");
const packages = Object.entries(lock.packages).map(([path, row], index) => ({ SPDXID: `SPDXRef-Package-${index}`, name: row.name ?? (path || lock.name), versionInfo: row.version ?? lock.version, downloadLocation: "NOASSERTION", filesAnalyzed: false, licenseConcluded: "NOASSERTION", licenseDeclared: "NOASSERTION", copyrightText: "NOASSERTION", ...(row.integrity ? { checksums: [{ algorithm: "SHA512", checksumValue: Buffer.from(row.integrity.replace(/^sha512-/, ""), "base64").toString("hex") }] } : {}) }));
const rootPackage = packages[0];
if (!rootPackage)
    throw new Error("SBOM root package missing");
const relationships = [{ spdxElementId: "SPDXRef-DOCUMENT", relationshipType: "DESCRIBES", relatedSpdxElement: rootPackage.SPDXID }, ...packages.slice(1).map((pkg) => ({ spdxElementId: rootPackage.SPDXID, relationshipType: "DEPENDS_ON", relatedSpdxElement: pkg.SPDXID }))];
const created = new Date(epoch * 1000).toISOString().replace(".000", "");
const document = { SPDXID: "SPDXRef-DOCUMENT", spdxVersion: "SPDX-2.3", dataLicense: "CC0-1.0", name: "Archivale Workers Free release-policy adapter", documentNamespace: `https://archivale.app/spdx/release-policy-workers-free/${anchor}/${hash(lockBytes)}`, creationInfo: { created, creators: ["Tool: Archivale release-policy SBOM generator"] }, packages, relationships };
mkdirSync(dirname(output), { recursive: true });
writeFileSync(output, `${JSON.stringify(document)}\n`, { flag: "w" });
