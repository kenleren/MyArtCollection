import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = process.cwd();
const config = JSON.parse(readFileSync(resolve(root, "wrangler.jsonc"), "utf8"));
const lock = JSON.parse(readFileSync(resolve(root, "package-lock.json"), "utf8"));
const installed = JSON.parse(readFileSync(resolve(root, "node_modules/wrangler/package.json"), "utf8"));
const worker = readFileSync(resolve(root, "evidence/bundle/worker.mjs"));
const evidence = JSON.parse(readFileSync(resolve(root, "evidence/bundle/bundle-evidence.v1.json"), "utf8"));
if (config.main !== "evidence/bundle/worker.mjs" || config.no_bundle !== true || config.find_additional_modules !== false || config.send_metrics !== false) throw new Error("wrangler deployment config drift");
if (installed.version !== "4.113.0" || lock.packages?.["node_modules/wrangler"]?.version !== "4.113.0") throw new Error("wrangler toolchain drift");
if (createHash("sha256").update(worker).digest("hex") !== evidence.sha256 || worker.byteLength !== evidence.bytes) throw new Error("reviewed worker bytes drift");
if (existsSync(resolve(root, ".wrangler/deploy/config.json"))) throw new Error("wrangler redirect config rejected");
const outdir = mkdtempSync(join(tmpdir(), "archivale-wrangler-preflight-"));
try {
  execFileSync("npm", ["exec", "--", "wrangler", "deploy", "--config", "wrangler.jsonc", "--dry-run", "--no-bundle", "--outdir", outdir, "--metafile", resolve(outdir, "metafile.json")], { cwd: root, stdio: "ignore" });
  const emitted = readdirSync(outdir).filter((name) => /\.(?:mjs|js)$/.test(name));
  if (emitted.length !== 1) throw new Error("wrangler module set drift");
  const output = readFileSync(resolve(outdir, emitted[0]));
  if (!output.equals(worker)) throw new Error("wrangler emitted worker bytes drift");
} finally { rmSync(outdir, { recursive: true, force: true }); }
process.stdout.write("wrangler contract passed\n");
