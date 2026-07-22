import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

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
process.stdout.write("wrangler contract passed\n");
