import { readFileSync, writeFileSync } from "node:fs"; import { resolve } from "node:path";
const root = resolve(process.cwd()); const lock = JSON.parse(readFileSync(resolve(root, "package-lock.json"), "utf8")) as { name: string; version: string; packages: Record<string, { name?: string; version?: string; integrity?: string }> };
function checksum(integrity: string): { algorithm: "SHA512"; checksumValue: string } {
  if (!integrity.startsWith("sha512-")) throw new Error("unsupported package integrity algorithm");
  const encoded = integrity.slice("sha512-".length);
  const bytes = Buffer.from(encoded, "base64");
  if (bytes.length !== 64 || bytes.toString("base64") !== encoded) throw new Error("invalid package integrity digest");
  return { algorithm: "SHA512", checksumValue: bytes.toString("hex") };
}
const packages = Object.entries(lock.packages).map(([path, row]) => ({ SPDXID: `SPDXRef-${path || "root"}`.replace(/[^A-Za-z0-9.-]/g, "-"), name: row.name ?? (path || lock.name), versionInfo: row.version ?? lock.version, ...(row.integrity ? { checksums: [checksum(row.integrity)] } : {}) })).sort((a, b) => a.SPDXID.localeCompare(b.SPDXID));
writeFileSync(resolve(root, "evidence/sbom.spdx.json"), JSON.stringify({ SPDXID: "SPDXRef-DOCUMENT", spdxVersion: "SPDX-2.3", name: lock.name, packages }) + "\n");
