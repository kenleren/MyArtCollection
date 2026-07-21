import { createHmac, generateKeyPairSync } from "node:crypto";
import { realpathSync, readFileSync } from "node:fs";
import { relative, resolve, sep } from "node:path";
import { mkdtempSync, rmSync, chmodSync, readdirSync, statSync, readFileSync as readBytes } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { Log, LogLevel, Miniflare, NoOpLog } from "miniflare";

const root = realpathSync(resolve(process.cwd(), "../.."));
const bundle = resolve(root, ".work/release-policy-workers-free/bundle/worker.mjs");
const scriptPath = relative(root, bundle).split(sep).join("/");
const secret = "sqlite-conformance-synthetic-secret"; const privateKey = generateKeyPairSync("rsa", { modulusLength: 2048, privateKeyEncoding: { type: "pkcs8", format: "pem" }, publicKeyEncoding: { type: "spki", format: "pem" } }).privateKey;
const sha = "a".repeat(40); const head = "b".repeat(40); let check; const routes = [];
const outboundService = async (request) => { const url = new URL(request.url); if (url.origin !== "https://api.github.com") return new Response("", { status: 403 }); routes.push(`${request.method}:${url.pathname}`); const json = (value) => new Response(JSON.stringify(value), { headers: { "content-type": "application/json" } }); if (url.pathname === "/app/installations/1/access_tokens") return json({ token: "synthetic-installation-token" }); if (/\/pulls\/1$/.test(url.pathname)) return json({ app: { id: 1 }, base: { ref: "main", sha, repo: { id: 1288597824 } }, base_repo: { id: 1288597824, full_name: "kenleren/MyArtCollection" }, head: { sha: head, repo: { id: 1288597824 } }, installation: { id: 1 }, changed_files: 1, number: 1 }); if (/\/git\/ref\/heads\/main$/.test(url.pathname)) return json({ object: { sha } }); if (/\/pulls\/1\/files$/.test(url.pathname)) return json([{ filename: "README.md", status: "modified" }]); if (/\/check-runs$/.test(url.pathname) && request.method === "POST") { const body = await request.json(); return json(check = { app: { id: 1 }, id: 7001, external_id: body.external_id, head_sha: body.head_sha, name: body.name }); } if (/\/check-runs\/7001$/.test(url.pathname)) return json({}); if (/\/check-runs$/.test(url.pathname)) return json({ check_runs: check ? [check] : [] }); return new Response("", { status: 403 }); };
const flags = ["nodejs_compat", "nodejs_compat_v2", "nodejs_compat_do_not_populate_process_env", "disallow_importable_env"];
if (process.version !== "v22.23.1") throw new Error("pinned Node runtime required");
const persist = mkdtempSync(join(tmpdir(), "archivale-245-do-")); chmodSync(persist, 0o700);
const make = () => { const log = new NoOpLog(); if (!(log instanceof Log) || log.level !== LogLevel.NONE) throw new Error("quiet logger contract violated"); return new Miniflare({ rootPath: root, scriptPath, modules: true, modulesRoot: root, compatibilityDate: "2026-07-21", compatibilityFlags: flags, bindings: { RELEASE_TRUST_CONFIG_V1: '{"repository_id":1288597824,"app_id":1,"installation_id":1,"github_api_origin":"https://api.github.com"}', GITHUB_WEBHOOK_SECRET: secret, GITHUB_APP_PRIVATE_KEY_PEM: privateKey }, durableObjects: { REPOSITORY: { className: "RepositoryDurableObject", useSQLite: true } }, durableObjectsPersist: persist, kvPersist: false, cachePersist: false, outboundService, log }); };
const mf = make();
const FIXED_SCHEDULED_TIME_MS = 1784603820000; const FIXED_CRON = "17 3 * * *";
async function runScheduledStep(instance, record, stepId) { const worker = await instance.getWorker(); if (!worker || typeof worker.scheduled !== "function") throw new Error(`${stepId}:scheduled_proxy_unavailable`); await worker.scheduled({ scheduledTime: FIXED_SCHEDULED_TIME_MS, cron: FIXED_CRON }); record.push({ step_id: stepId, result: "resolved" }); }
try {
  const raw = new TextEncoder().encode('{"action":"opened","number":1,"repository":{"id":1288597824,"full_name":"kenleren/MyArtCollection"},"installation":{"id":1},"pull_request":{"base":{"ref":"main","repo":{"id":1288597824}},"head":{"repo":{"id":1288597824}}}}');
  const sig = createHmac("sha256", secret).update(raw).digest("hex");
  const headers = { "content-type": "application/json", "x-hub-signature-256": `sha256=${sig}`, "x-github-event": "pull_request", "x-github-delivery": "sqlite-conformance" };
  const responses = await Promise.all(Array.from({ length: 32 }, () => mf.dispatchFetch("http://runtime.invalid/webhook", { method: "POST", headers, body: raw })));
  if (responses.some((response) => response.status !== 202)) throw new Error("concurrent ingress rejected");
  await runScheduledStep(mf, [], "watchdog");
  for (let index = 0; index < 5_500 && !check; index++) await new Promise((resolve) => setTimeout(resolve, 10));
  if (!check || routes.filter((route) => route === "POST:/repositories/1288597824/check-runs").length !== 1) throw new Error(`synthetic lifecycle did not create one Check: ${routes.join(",")}`);
  const ids = await mf.listDurableObjectIds("REPOSITORY"); if (ids.length !== 1) throw new Error("durable object identity mismatch");
} finally { await mf.dispose(); }
try { const dbPath = join(persist, "-RepositoryDurableObject", `${(readdirSync(join(persist, "-RepositoryDurableObject")).find((name) => name.endsWith(".sqlite")) ?? "").replace(/[^A-Za-z0-9._-]/g, "")}`); if (!dbPath.endsWith(".sqlite") || !statSync(dbPath).isFile() || !readBytes(dbPath).subarray(0, 16).equals(Buffer.from("SQLite format 3\0"))) throw new Error("persistent SQLite layout rejected"); const db = new DatabaseSync(dbPath, { readOnly: true }); try { db.exec("PRAGMA query_only=ON"); if (db.prepare("PRAGMA quick_check").get()?.quick_check !== "ok") throw new Error("SQLite quick check failed"); const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('kv','meta') ORDER BY name").all(); if (JSON.stringify(tables.map((x) => x.name)) !== JSON.stringify(["kv", "meta"])) throw new Error("SQLite schema unavailable"); } finally { db.close(); } } finally { rmSync(persist, { recursive: true, force: true }); }
process.stdout.write("sqlite conformance passed\n");
