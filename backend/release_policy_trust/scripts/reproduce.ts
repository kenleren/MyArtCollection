import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { argument, git, hashBytes, hashFile, packageRoot, repoRoot, validateOid } from "./shared.js";

function files(root: string): string[] {
  const output: string[] = [];
  const visit = (directory: string): void => {
    for (const name of readdirSync(directory).sort()) {
      if (["node_modules", "dist", "review"].includes(name)) continue;
      const path = join(directory, name);
      if (statSync(path).isDirectory()) visit(path); else output.push(path);
    }
  };
  visit(root);
  return output;
}
function directoryDigest(root: string): string {
  const hash = createHash("sha256");
  for (const path of files(root)) { hash.update(path.slice(root.length + 1)); hash.update("\0"); hash.update(readFileSync(path)); hash.update("\0"); }
  return hash.digest("hex");
}
function sbom(lockPath: string): Buffer {
  const lock = JSON.parse(readFileSync(lockPath, "utf8")) as { packages: Record<string, { name?: string; version?: string; integrity?: string }> };
  const components = Object.entries(lock.packages).filter(([path]) => path !== "").map(([path, row]) => ({ bom_ref: path, integrity: row.integrity ?? "workspace", name: row.name ?? basename(path), type: "library", version: row.version ?? "0" })).sort((a, b) => a.bom_ref.localeCompare(b.bom_ref));
  return Buffer.from(`${JSON.stringify({ bomFormat: "CycloneDX", components, specVersion: "1.6", version: 1 })}\n`);
}
function run(root: string): { build: string; pack: string; sbom: string } {
  execFileSync("npm", ["ci", "--ignore-scripts"], { cwd: root, stdio: "ignore" });
  execFileSync("npm", ["run", "build", "--silent"], { cwd: root, stdio: "ignore" });
  const packDir = join(root, "pack"); mkdirSync(packDir);
  const packed = execFileSync("npm", ["pack", "--ignore-scripts", "--pack-destination", packDir, "--json"], { cwd: root, encoding: "utf8" });
  const filename = (JSON.parse(packed) as Array<{ filename: string }>)[0]!.filename;
  const sbomBytes = sbom(join(root, "package-lock.json")); writeFileSync(join(root, "canonical-sbom.cdx.json"), sbomBytes);
  return { build: directoryDigest(join(root, "dist/src")), pack: hashFile(join(packDir, filename)), sbom: hashBytes(sbomBytes) };
}

const candidateArgument = argument("--candidate");
const candidate = candidateArgument === "INDEX" ? candidateArgument : validateOid(candidateArgument);
const output = resolve(repoRoot, argument("--output"));
if (candidate !== "INDEX") {
  git(["cat-file", "-e", `${candidate}^{commit}`]);
  if ((git(["diff", "--name-only", candidate, "--", "backend/release_policy_trust", ".github/CODEOWNERS", ".github/workflows/release-readiness.yml", "docs/RELEASE_READINESS_CI.md", "docs/RELEASE_POLICY_TRUST.md"], { encoding: "utf8" }) as string).trim() !== "") throw new Error("workspace differs from candidate");
}
const root = join(tmpdir(), `release-policy-reproduce-${process.pid}`); rmSync(root, { recursive: true, force: true });
try {
  const firstRoot = join(root, "first"); const secondRoot = join(root, "second");
  cpSync(packageRoot, firstRoot, { recursive: true, filter: (source) => !/(?:^|\/)(?:node_modules|dist|review)(?:\/|$)/.test(source) });
  cpSync(packageRoot, secondRoot, { recursive: true, filter: (source) => !/(?:^|\/)(?:node_modules|dist|review)(?:\/|$)/.test(source) });
  const first = run(firstRoot); const second = run(secondRoot);
  if (JSON.stringify(first) !== JSON.stringify(second)) throw new Error("build, pack, or SBOM is not byte reproducible");
  mkdirSync(resolve(output, ".."), { recursive: true });
  writeFileSync(output, `${JSON.stringify({ base_commit: "f42582c8eb0d1405cd5e214f6b9c80980225b5f1", build_sha256: first.build, package_lock_sha256: hashFile(join(packageRoot, "package-lock.json")), package_source_sha256: directoryDigest(packageRoot), pack_sha256: first.pack, sbom_sha256: first.sbom, schema_version: 1 }, null, 2)}\n`);
} finally { rmSync(root, { recursive: true, force: true }); }
