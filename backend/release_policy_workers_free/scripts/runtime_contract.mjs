import { createHash, createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import { realpathSync } from "node:fs";
import { relative, resolve, sep } from "node:path";
import { getNodeCompat, Log, LogLevel, Miniflare, NoOpLog } from "miniflare";

const failClosed = () => { process.stderr.write("runtime contract failed\n"); process.exit(1); };
process.once("uncaughtException", failClosed);
process.once("unhandledRejection", failClosed);

const packageRoot = realpathSync(process.cwd());
const repositoryRoot = realpathSync(resolve(packageRoot, "../.."));
const bundleRoot = resolve(repositoryRoot, ".work/release-policy-workers-free/bundle");
const bundle = resolve(bundleRoot, "worker.mjs");
const scriptPath = relative(repositoryRoot, bundle).split(sep).join("/");
if (scriptPath !== ".work/release-policy-workers-free/bundle/worker.mjs" || !scriptPath || scriptPath.startsWith("/") || scriptPath.split("/").includes("..")) throw new Error("bundle script path escapes repository root");
const expectedVersion = "4.20260714.0";
const installed = JSON.parse(readFileSync(resolve(packageRoot, "node_modules/miniflare/package.json"), "utf8"));
const lock = JSON.parse(readFileSync(resolve(packageRoot, "package-lock.json"), "utf8"));
if (installed.version !== expectedVersion || lock.packages?.["node_modules/miniflare"]?.version !== expectedVersion) throw new Error("miniflare version drift");
const bytes = readFileSync(bundle);
const sha256 = createHash("sha256").update(bytes).digest("hex");
const evidence = JSON.parse(readFileSync(resolve(bundleRoot, "bundle-evidence.v1.json"), "utf8"));
if (evidence.sha256 !== sha256 || evidence.bytes !== bytes.byteLength || evidence.esbuild !== "0.25.9" || evidence.miniflare !== expectedVersion) throw new Error("bundle evidence drift");
const manifestBytes = readFileSync(resolve(bundleRoot, "import-manifest.v1.json"));
const manifest = JSON.parse(manifestBytes);
const imports = [...bytes.toString("utf8").matchAll(/(?:from\s+|import\s*)["']([^"']+)["']/g)].map((match) => match[1]).sort();
if (manifest.output !== "worker.mjs" || JSON.stringify(manifest.imports) !== JSON.stringify(imports) || imports.length !== 2 || imports.some((item) => item !== "node:crypto")) throw new Error("import manifest drift");
const ignore = readFileSync(resolve(repositoryRoot, ".gitignore"), "utf8");
if (ignore.split("\n").filter((line) => line === "/.work/release-policy-workers-free/").length !== 1) throw new Error("root generated-output ignore drift");
const flags = ["nodejs_compat", "nodejs_compat_v2", "nodejs_compat_do_not_populate_process_env", "disallow_importable_env"];
function assertCompatibility(candidate) {
  if (JSON.stringify(candidate) !== JSON.stringify(flags)) throw new Error(candidate.includes("nodejs_compat_v2") ? "compatibility-inventory-drift" : "explicit-v2-required");
  const state = getNodeCompat("2026-07-21", candidate);
  if (state.mode !== "v2" || !state.hasNodejsCompatFlag || !state.hasNodejsCompatV2Flag) throw new Error("node-compat-v2-required");
  return state;
}
const nodeCompat = assertCompatibility(flags);
const secret = Array.from(crypto.getRandomValues(new Uint8Array(32)), (value) => String.fromCharCode(97 + (value % 26))).join("");
const bindings = { RELEASE_TRUST_CONFIG_V1: '{"repository_id":1288597824,"app_id":1,"installation_id":1,"github_api_origin":"https://api.github.com"}', GITHUB_WEBHOOK_SECRET: secret, GITHUB_APP_PRIVATE_KEY_PEM: "-----BEGIN PRIVATE KEY-----\nsynthetic-runtime-only\n-----END PRIVATE KEY-----" };
function optionsFor(compatibilityFlags = flags) {
  const log = new NoOpLog();
  if (!(log instanceof Log) || log.level !== LogLevel.NONE) throw new Error("quiet logger contract violated");
  return { rootPath: repositoryRoot, scriptPath, modules: true, modulesRoot: repositoryRoot, compatibilityDate: "2026-07-21", compatibilityFlags, bindings, durableObjects: { REPOSITORY: { className: "RepositoryDurableObject", useSQLite: true } }, durableObjectsPersist: false, kvPersist: false, cachePersist: false, log };
}
const runtime = new Miniflare(optionsFor());
try {
  const missing = await runtime.dispatchFetch("http://runtime.invalid/not-a-route");
  if (missing.status !== 404) throw new Error("same-byte Worker did not execute");
  const raw = new TextEncoder().encode('{"action":"opened","number":1,"repository":{"id":1288597824,"full_name":"kenleren/MyArtCollection"},"installation":{"id":1},"pull_request":{"base":{"ref":"main","repo":{"id":1288597824}},"head":{"repo":{"id":1288597824}}}}');
  const signature = createHmac("sha256", secret).update(raw).digest("hex");
  const headers = { "content-type": "application/json", "x-hub-signature-256": `sha256=${signature}`, "x-github-event": "pull_request", "x-github-delivery": "synthetic" };
  const accepted = await runtime.dispatchFetch("http://runtime.invalid/webhook", { method: "POST", headers, body: raw });
  if (accepted.status !== 202) throw new Error("raw-HMAC positive was not delivered");
  const rejected = await runtime.dispatchFetch("http://runtime.invalid/webhook", { method: "POST", headers: { ...headers, "x-hub-signature-256": `sha256=${"0".repeat(64)}` }, body: raw });
  if (rejected.status !== 401) throw new Error("invalid HMAC was not rejected before DO");
} finally { await runtime.dispose(); }
for (const negative of [flags.filter((flag) => flag !== "nodejs_compat" && flag !== "nodejs_compat_v2"), flags.filter((flag) => flag !== "nodejs_compat_v2"), [...flags, "forbidden_flag"]]) {
  let rejected = false;
  try { assertCompatibility(negative); } catch { rejected = true; }
  if (!rejected) throw new Error("compatibility negative accepted");
}
if (nodeCompat.mode !== "v2") throw new Error("node compatibility proof missing");
console.log("runtime contract passed");
