import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = process.cwd();
const digest = (value) => createHash("sha256").update(value).digest("hex");
const configBytes = readFileSync(resolve(root, "wrangler.jsonc"));
const config = JSON.parse(configBytes);
const lock = JSON.parse(readFileSync(resolve(root, "package-lock.json"), "utf8"));
const installed = JSON.parse(readFileSync(resolve(root, "node_modules/wrangler/package.json"), "utf8"));
const worker = readFileSync(resolve(root, "evidence/bundle/worker.mjs"));
const bundleMeta = JSON.parse(readFileSync(resolve(root, "evidence/bundle/metafile.json"), "utf8"));
const evidencePath = resolve(root, "evidence/wrangler-preflight.v1.json");
const expectedKeys = ["$schema", "compatibility_date", "compatibility_flags", "durable_objects", "find_additional_modules", "main", "migrations", "name", "no_bundle", "send_metrics"];
if (JSON.stringify(Object.keys(config).sort()) !== JSON.stringify(expectedKeys) || config.main !== "evidence/bundle/worker.mjs" || config.no_bundle !== true || config.find_additional_modules !== false || config.send_metrics !== false || config.compatibility_date !== "2026-07-21" || JSON.stringify(config.compatibility_flags) !== JSON.stringify(["nodejs_compat_v2", "nodejs_compat_do_not_populate_process_env", "disallow_importable_env"]) || JSON.stringify(config.durable_objects) !== JSON.stringify({ bindings: [{ name: "REPOSITORY", class_name: "RepositoryDurableObject" }] }) || JSON.stringify(config.migrations) !== JSON.stringify([{ tag: "v1", new_sqlite_classes: ["RepositoryDurableObject"] }]) || ["assets", "build", "vars", "routes", "redirects"].some((key) => key in config)) throw new Error("wrangler deployment config drift");
if (!bundleMeta.inputs || !bundleMeta.outputs || Object.keys(bundleMeta.outputs).length !== 1) throw new Error("bundle metafile drift");
if (installed.version !== "4.113.0" || lock.packages?.["node_modules/wrangler"]?.version !== "4.113.0") throw new Error("wrangler toolchain drift");
if (existsSync(resolve(root, ".wrangler/deploy/config.json"))) throw new Error("wrangler redirect config rejected");
const outdir = mkdtempSync(join(tmpdir(), "archivale-wrangler-preflight-"));
try {
  execFileSync("npm", ["exec", "--", "wrangler", "deploy", "--config", "wrangler.jsonc", "--dry-run", "--no-bundle", "--outdir", outdir], { cwd: root, stdio: "ignore" });
  const files = readdirSync(outdir).sort(); const emitted = files.filter((name) => /\.(?:mjs|js)$/.test(name));
  if (JSON.stringify(files) !== JSON.stringify(["README.md", "worker.mjs"]) || JSON.stringify(emitted) !== JSON.stringify(["worker.mjs"])) throw new Error("wrangler module set drift");
  const output = readFileSync(resolve(outdir, "worker.mjs"));
  if (!output.equals(worker)) throw new Error("wrangler emitted worker bytes drift");
  const record = { schema_version: 1, tool: "wrangler", tool_version: installed.version, command: ["deploy", "--config", "wrangler.jsonc", "--dry-run", "--no-bundle"], config_sha256: digest(configBytes), bundle_metafile_sha256: digest(readFileSync(resolve(root, "evidence/bundle/metafile.json"))), emitted_module_count: 1, emitted_modules: [{ path: "worker.mjs", sha256: digest(output), bytes: output.byteLength }], durable_object: { binding: "REPOSITORY", class_name: "RepositoryDurableObject", migration_tag: "v1", sqlite_class: "RepositoryDurableObject" } };
  const canonical = `${JSON.stringify(record)}\n`;
  if (process.argv.includes("--generate")) writeFileSync(evidencePath, canonical);
  else if (!existsSync(evidencePath) || readFileSync(evidencePath, "utf8") !== canonical) throw new Error("wrangler preflight evidence drift");
} finally { rmSync(outdir, { recursive: true, force: true }); }
process.stdout.write("wrangler contract passed\n");
