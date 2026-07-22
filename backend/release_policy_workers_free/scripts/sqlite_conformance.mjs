import assert from "node:assert/strict";
import { createHash, createHmac, generateKeyPairSync, randomBytes } from "node:crypto";
import {
  chmodSync, existsSync, lstatSync, mkdtempSync, readFileSync, readdirSync,
  realpathSync, rmSync, statSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { Log, LogLevel, Miniflare, NoOpLog } from "miniflare";
import { parseRuntimeConfig, SQLITE_COMPATIBILITY_SHA256 } from "../dist/src/config.js";
import { SQLITE_SCHEMA_DIGEST, SQLITE_SCHEMA_ID } from "../dist/src/sqlite_store.js";

const CASE_IDS = [
  "race.duplicate_same_generation", "race.delivery_conflict", "replay.after_restart",
  "recovery.ambiguous_create", "recovery.definite_presend", "alarm.sole_drainer",
  "pagination.ordinary", "pagination.101", "pagination.3000",
  "pagination.malformed_link", "pagination.cross_origin", "pagination.duplicate_next",
  "pagination.skipped_page", "pagination.repeated_page", "pagination.short_nonfinal",
  "pagination.declared_3001", "pagination.page_31", "pagination.oversized_response",
  "budget.call_51", "telemetry.watchdog", "protected.add", "protected.modify",
  "protected.delete", "protected.copy", "protected.rename", "protected.case_fold",
];
const CASE_SET = new Set([...CASE_IDS, "restore.rehearsal"]);
const FLAGS = ["nodejs_compat", "nodejs_compat_v2", "nodejs_compat_do_not_populate_process_env", "disallow_importable_env"];
const FIXED_SCHEDULED_TIME_MS = 1784603820000;
const FIXED_CRON = "17 3 * * *";
const REPOSITORY_ID = 1288597824;
const APP_ID = 1;
const INSTALLATION_ID = 1;
const BASE_SHA = "a".repeat(40);
const HEAD_SHA = "b".repeat(40);
const CHECK_ID = 7001;
const CONFIG = JSON.stringify({ contract_version: 1, repository_id: REPOSITORY_ID, repository_name: "kenleren/MyArtCollection", app_id: APP_ID, installation_id: INSTALLATION_ID, github_api_origin: "https://api.github.com", github_api_version: "2022-11-28", policy_sha256: "a443af2eb86fa310ea8705826e70d1b178a4d8d231060440ed522d3069b9a80d", egress_manifest_sha256: "4076541b10ad17bd6e300d838032c49538cb4aa9a172685fe9f0cef02fd4c368", permissions: { checks: "write", contents: "read", metadata: "read", pull_requests: "read" }, quota: { window_seconds: 86400, warning_units: 1000, hard_units: 10000 } });
const sleep = (ms) => new Promise((resolveSleep) => setTimeout(resolveSleep, ms));
const sha256 = (value) => createHash("sha256").update(value).digest("hex");

class HarnessFailure extends Error {
  constructor(caseId, failureClass) { super(`${caseId}:${failureClass}`); this.caseId = caseId; this.failureClass = failureClass; }
}
function ensure(condition, caseId, failureClass) { if (!condition) throw new HarnessFailure(caseId, failureClass); }
function sanitizedFailure(error) {
  if (error instanceof HarnessFailure && CASE_SET.has(error.caseId) && /^[a-z0-9_]+$/.test(error.failureClass)) return error;
  return new HarnessFailure("harness", "rejected");
}
async function waitFor(caseId, predicate, failureClass = "poll_exhausted") {
  for (let index = 0; index < 500; index += 1) { if (predicate()) return; await sleep(10); }
  throw new HarnessFailure(caseId, failureClass);
}

const packageRoot = realpathSync(process.cwd());
const repositoryRoot = realpathSync(resolve(packageRoot, "../.."));
const tempRoot = realpathSync(tmpdir());
const bundleRoot = resolve(repositoryRoot, ".work/release-policy-workers-free/bundle");
const bundlePath = resolve(bundleRoot, "worker.mjs");
const scriptPath = relative(repositoryRoot, bundlePath).split(sep).join("/");
const evidencePath = resolve(packageRoot, "evidence/sqlite-conformance.v1.json");
const restoreFixturePath = resolve(packageRoot, "evidence/restore-fixture.v1.json");
const captureRestoreFixture = process.argv.includes("--capture-restore-fixture");
const runRestoreOnly = process.argv.includes("--restore-rehearsal");
let bundleHash;
let importManifestHash;

function restoreIdentityRows() {
  const activationDigest = parseRuntimeConfig(CONFIG).activationDigest;
  return [
    ["schema/id", JSON.stringify(SQLITE_SCHEMA_ID)],
    ["schema/version", "2"],
    ["schema/state", JSON.stringify("ready")],
    ["schema/digest", JSON.stringify(SQLITE_SCHEMA_DIGEST)],
    ["compatibility/digest", JSON.stringify(`sha256:${SQLITE_COMPATIBILITY_SHA256}`)],
    ["activation/digest", JSON.stringify(activationDigest)],
  ].map(([meta_row, value_json]) => ({ meta_row, value_json }));
}

function preflight() {
  ensure(process.version === "v22.23.1", "harness", "node_version");
  ensure(scriptPath === ".work/release-policy-workers-free/bundle/worker.mjs" && !scriptPath.split("/").includes(".."), "harness", "bundle_path");
  const installed = JSON.parse(readFileSync(resolve(packageRoot, "node_modules/miniflare/package.json"), "utf8"));
  const lock = JSON.parse(readFileSync(resolve(packageRoot, "package-lock.json"), "utf8"));
  ensure(installed.version === "4.20260721.0" && lock.packages?.["node_modules/miniflare"]?.version === "4.20260721.0", "harness", "miniflare_version");
  const miniflareVersion = installed.version;
  const bundle = readFileSync(bundlePath); bundleHash = sha256(bundle);
  const bundleEvidence = JSON.parse(readFileSync(resolve(bundleRoot, "bundle-evidence.v1.json"), "utf8"));
  ensure(bundleEvidence.sha256 === bundleHash && bundleEvidence.bytes === bundle.byteLength && bundleEvidence.miniflare === installed.version, "harness", "bundle_evidence");
  const manifestBytes = readFileSync(resolve(bundleRoot, "import-manifest.v1.json")); importManifestHash = sha256(manifestBytes);
  const manifest = JSON.parse(manifestBytes);
  const imports = [...bundle.toString("utf8").matchAll(/(?:from\s+|import\s*)["']([^"']+)["']/g)].map((match) => match[1]).sort();
  ensure(manifest.output === "worker.mjs" && JSON.stringify(manifest.imports) === JSON.stringify(imports) && imports.length === 2 && imports.every((value) => value === "node:crypto"), "harness", "import_manifest");
  const unsafeInspect = ["unsafe", "Inspect", "DurableObjects"].join("");
  const unsafeStorage = ["unsafe", "Get", "DurableObjectStorage"].join("");
  const removedScheduled = ["dispatch", "Scheduled"].join("");
  const emitted = bundle.toString("utf8");
  ensure(!emitted.includes(unsafeInspect) && !emitted.includes(unsafeStorage) && !emitted.includes("cloudflare:workers") && !emitted.includes("extends DurableObject"), "harness", "production_leakage");
  for (const path of ["src", "config", "wrangler.jsonc", "scripts/runtime_contract.mjs", "scripts/bundle_worker.mjs"]) {
    const absolute = resolve(packageRoot, path);
    const files = lstatSync(absolute).isDirectory() ? walk(absolute) : [absolute];
    for (const file of files) {
      const text = readFileSync(file, "utf8");
      ensure(!text.includes(unsafeInspect) && !text.includes(unsafeStorage), "harness", "inspection_leakage");
      if (file.endsWith("runtime_contract.mjs")) ensure(!text.includes(`.${removedScheduled}(`), "harness", "scheduled_api_leakage");
    }
  }
  const harnessSource = readFileSync(new URL(import.meta.url), "utf8");
  ensure(!harnessSource.includes(`.${removedScheduled}(`), "harness", "removed_scheduled_api");
  ensure((harnessSource.match(/async function runScheduledStep\(/g) ?? []).length === 1, "harness", "scheduled_helper_count");
  ensure((harnessSource.match(/\.scheduled\(\{/g) ?? []).length === 1, "harness", "scheduled_proxy_count");
  return miniflareVersion;
}
function walk(root) {
  const results = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) { const path = resolve(root, entry.name); if (entry.isDirectory()) results.push(...walk(path)); else results.push(path); }
  return results;
}

function credentials() {
  const privateKey = generateKeyPairSync("rsa", { modulusLength: 2048, privateKeyEncoding: { type: "pkcs8", format: "pem" }, publicKeyEncoding: { type: "spki", format: "pem" } }).privateKey;
  const nonce = randomBytes(18).toString("hex");
  return { privateKey, secret: `sqlite-${nonce}`, token: `install-${nonce}`, markers: [`sqlite-${nonce}`, `install-${nonce}`, "BEGIN PRIVATE KEY"] };
}

function makeBody(action = "opened") {
  return new TextEncoder().encode(JSON.stringify({ action, number: 1, repository: { id: REPOSITORY_ID, full_name: "kenleren/MyArtCollection" }, installation: { id: INSTALLATION_ID }, pull_request: { base: { ref: "main", repo: { id: REPOSITORY_ID } }, head: { repo: { id: REPOSITORY_ID } } } }));
}
async function dispatchWebhook(mf, creds, delivery, body, record) {
  const signature = createHmac("sha256", creds.secret).update(body).digest("hex");
  const response = await mf.dispatchFetch("http://runtime.invalid/webhook", { method: "POST", headers: { "content-type": "application/json", "x-hub-signature-256": `sha256=${signature}`, "x-github-event": "pull_request", "x-github-delivery": delivery }, body });
  record.http.push(response.status); return response.status;
}
async function runScheduledStep(mf, record, stepId) {
  const worker = await mf.getWorker();
  if (!worker || typeof worker.scheduled !== "function") throw new HarnessFailure(record.caseId, "scheduled_proxy_unavailable");
  try { await Promise.race([worker.scheduled({ scheduledTime: FIXED_SCHEDULED_TIME_MS, cron: FIXED_CRON }), sleep(5_000).then(() => { throw new HarnessFailure(record.caseId, "scheduled_timeout"); })]); record.scheduled.push({ step_id: stepId, result: "resolved" }); }
  catch { record.scheduled.push({ step_id: stepId, result: "rejected" }); throw new HarnessFailure(record.caseId, "scheduled_rejected"); }
}

const defaultFiles = (count) => Array.from({ length: count }, (_, index) => ({ filename: `docs/conformance-${String(index).padStart(4, "0")}.md`, status: "modified" }));
const exactLink = (routePath, page, last, relationSet = "next") => {
  const target = (targetPage) => `https://api.github.com${routePath}?per_page=100&page=${targetPage}`;
  if (relationSet === "next") return `<${target(page + 1)}>; rel="next", <${target(last)}>; rel="last"`;
  return `<${target(1)}>; rel="first", <${target(page - 1)}>; rel="prev", <${target(last)}>; rel="last"`;
};

class SyntheticEgress {
  constructor(caseId, creds, fixture, seedCheck = null) {
    this.caseId = caseId; this.creds = creds; this.fixture = fixture; this.check = seedCheck;
    this.routes = []; this.checks = []; this.unmatched = 0; this.createAttempts = 0; this.tokenFailures = 0;
    this.gateTriggered = false;
    this.gateReached = new Promise((resolveGate) => { this.resolveGate = resolveGate; });
    this.gateRelease = new Promise((resolveRelease) => { this.resolveRelease = resolveRelease; });
  }
  releaseGate() { this.resolveRelease(); }
  count(routeId) { return this.routes.filter((row) => row.route_id === routeId).length; }
  total() { return this.routes.length; }
  response(value, options = {}) {
    const body = options.body ?? JSON.stringify(value); const headers = new Headers({ "content-type": "application/json" });
    if (options.link !== undefined) headers.set("link", options.link);
    headers.set("content-length", String(options.declaredLength ?? new TextEncoder().encode(body).byteLength));
    return new Response(body, { status: options.status ?? 200, headers });
  }
  record(routeId, page = null, responseClass = "ok", rows = null) { this.routes.push({ route_id: routeId, page, response_class: responseClass, rows }); }
  async handle(request) {
    const url = new URL(request.url); const authorization = request.headers.get("authorization") ?? "";
    if (url.origin !== "https://api.github.com" || !authorization.startsWith("Bearer ") || /[\r\n]/.test(authorization)) { this.unmatched += 1; return new Response(null, { status: 403 }); }
    const path = url.pathname; const method = request.method;
    if (method === "POST" && path === `/app/installations/${INSTALLATION_ID}/access_tokens` && !url.search) {
      if (this.fixture.definiteTokenFailure && this.tokenFailures === 0) { this.tokenFailures += 1; this.record("installationToken", null, "transient"); return this.response({}, { status: 503 }); }
      this.record("installationToken"); return this.response({ token: this.creds.token, expires_at: new Date((Math.floor(Date.now() / 1000) + 120) * 1000).toISOString().replace(".000", ""), permissions: { checks: "write", contents: "read", metadata: "read", pull_requests: "read" }, repository_selection: "selected", repositories: [{ id: REPOSITORY_ID, name: "MyArtCollection", full_name: "kenleren/MyArtCollection" }] }, { status: 201 });
    }
    if (method === "GET" && path === `/repositories/${REPOSITORY_ID}/pulls/1` && !url.search) {
      this.record("pullRequest");
      if (this.fixture.gate && this.count("pullRequest") === 1) { this.gateTriggered = true; this.resolveGate(); await this.gateRelease; }
      return this.response({ base: { ref: "main", sha: BASE_SHA, repo: { id: REPOSITORY_ID, full_name: "kenleren/MyArtCollection" } }, head: { sha: HEAD_SHA, repo: { id: REPOSITORY_ID, full_name: "kenleren/MyArtCollection" } }, changed_files: this.fixture.declaredCount ?? this.fixture.files.length, number: 1, state: "open" });
    }
    if (method === "GET" && path === `/repositories/${REPOSITORY_ID}/git/ref/heads/main` && !url.search) { this.record("mainRef"); return this.response({ object: { sha: BASE_SHA } }); }
    if (method === "GET" && path === `/repositories/${REPOSITORY_ID}/pulls/1/files`) return this.pullFiles(url);
    if (method === "POST" && path === `/repositories/${REPOSITORY_ID}/check-runs` && !url.search) {
      this.createAttempts += 1; const body = await request.json();
      this.check = { app: { id: APP_ID }, id: CHECK_ID, external_id: body.external_id, head_sha: body.head_sha, name: body.name };
      this.record("createCheck", null, this.fixture.ambiguousCreate && this.createAttempts === 1 ? "ambiguous" : "ok");
      this.checks.push({ operation: "create", conclusion: null });
      if (this.fixture.ambiguousCreate && this.createAttempts === 1) throw new Error("synthetic ambiguous create");
      return this.response(this.check);
    }
    if (method === "GET" && path === `/repositories/${REPOSITORY_ID}/commits/${HEAD_SHA}/check-runs`) return this.appChecks(url);
    if (method === "PATCH" && path === `/repositories/${REPOSITORY_ID}/check-runs/${CHECK_ID}` && !url.search) {
      const body = await request.json(); this.record("updateCheck"); this.checks.push({ operation: "update", conclusion: body.conclusion }); return this.response({});
    }
    this.unmatched += 1; return new Response(null, { status: 403 });
  }
  pullFiles(url) {
    const page = Number(url.searchParams.get("page"));
    if (!Number.isSafeInteger(page) || url.searchParams.get("per_page") !== "100" || [...url.searchParams.keys()].sort().join(",") !== "page,per_page") { this.unmatched += 1; return new Response(null, { status: 403 }); }
    const mode = this.fixture.paginationMode; const all = this.fixture.files; let rows = all.slice((page - 1) * 100, page * 100); let link;
    const routePath = `/repositories/${REPOSITORY_ID}/pulls/1/files`;
    if (mode === "malformed_link" && page === 1) link = "not-a-link";
    else if (mode === "cross_origin" && page === 1) link = `<https://api.github.example${routePath}?per_page=100&page=2>; rel="next"`;
    else if (mode === "duplicate_next" && page === 1) link = `${exactLink(routePath, 1, 2)}, <https://api.github.com${routePath}?per_page=100&page=2>; rel="next"`;
    else if (mode === "skipped_page" && page === 1) link = `<https://api.github.com${routePath}?per_page=100&page=3>; rel="next"`;
    else if (mode === "repeated_page" && page === 1) link = `<https://api.github.com${routePath}?per_page=100&page=1>; rel="next"`;
    else if (mode === "short_nonfinal" && page === 1) { rows = all.slice(0, 99); link = exactLink(routePath, 1, 2); }
    else if (mode === "page_31" && page === 30) link = `<https://api.github.com${routePath}?per_page=100&page=31>; rel="next", <https://api.github.com${routePath}?per_page=100&page=31>; rel="last"`;
    else if (page * 100 < all.length) link = exactLink(routePath, page, Math.ceil(all.length / 100));
    else if (this.fixture.finalRelations && page > 1) link = exactLink(routePath, page, page, "terminal");
    this.record("pullFiles", page, "ok", rows.length);
    if (mode === "oversized_response" && page === 1) return this.response([], { declaredLength: 1_048_577 });
    return this.response(rows, link === undefined ? {} : { link });
  }
  appChecks(url) {
    const page = Number(url.searchParams.get("page"));
    if (!Number.isSafeInteger(page) || url.searchParams.get("per_page") !== "100") { this.unmatched += 1; return new Response(null, { status: 403 }); }
    if (this.fixture.budgetCall51) {
      const rows = Array.from({ length: 100 }, (_, index) => ({ app: { id: APP_ID + 1 }, id: page * 1000 + index + 1, external_id: `other-${page}-${index}`, head_sha: HEAD_SHA, name: "other" }));
      rows[1] = { ...rows[0] };
      this.record("appChecks", page, "ok", rows.length);
      return this.response({ check_runs: rows }, { link: exactLink(`/repositories/${REPOSITORY_ID}/commits/${HEAD_SHA}/check-runs`, page, 30) });
    }
    this.record("appChecks", page, "ok", this.check ? 1 : 0); return this.response({ check_runs: this.check ? [this.check] : [] });
  }
}

function newRecord(caseId) { return { caseId, http: [], scheduled: [], boundaries: 0, post_terminal: false }; }
function makeOptions(creds, egress, persist) {
  const log = new NoOpLog(); ensure(log instanceof Log && log.level === LogLevel.NONE, egress.caseId, "noop_log");
  return { rootPath: repositoryRoot, scriptPath, modules: true, modulesRoot: repositoryRoot, compatibilityDate: "2026-07-21", compatibilityFlags: FLAGS, bindings: { RELEASE_TRUST_CONFIG_V1: CONFIG, GITHUB_WEBHOOK_SECRET: creds.secret, GITHUB_APP_PRIVATE_KEY_PEM: creds.privateKey }, durableObjects: { REPOSITORY: { className: "RepositoryDurableObject", useSQLite: true } }, durableObjectsPersist: persist, kvPersist: false, cachePersist: false, outboundService: (request) => egress.handle(request), log };
}

function fixtureFor(caseId) {
  const fixture = { files: defaultFiles(1) };
  if (["race.duplicate_same_generation", "alarm.sole_drainer", "telemetry.watchdog"].includes(caseId)) fixture.gate = true;
  if (caseId === "recovery.ambiguous_create") fixture.ambiguousCreate = true;
  if (caseId === "recovery.definite_presend") fixture.definiteTokenFailure = true;
  if (caseId === "pagination.101") { fixture.files = defaultFiles(101); fixture.finalRelations = true; }
  if (["pagination.3000", "pagination.page_31", "budget.call_51"].includes(caseId)) fixture.files = defaultFiles(3000);
  if (caseId.startsWith("pagination.") && !["pagination.ordinary", "pagination.101", "pagination.3000"].includes(caseId)) fixture.paginationMode = caseId.slice("pagination.".length);
  if (["malformed_link", "cross_origin", "duplicate_next", "skipped_page", "repeated_page", "short_nonfinal"].includes(fixture.paginationMode)) fixture.files = defaultFiles(101);
  if (caseId === "pagination.declared_3001") { fixture.declaredCount = 3001; fixture.files = []; }
  if (caseId === "pagination.oversized_response") fixture.files = defaultFiles(1);
  if (caseId === "budget.call_51") fixture.budgetCall51 = true;
  const protectedRows = {
    "protected.add": [{ filename: "backend/release_policy_workers_free/src/new.ts", status: "added" }],
    "protected.modify": [{ filename: ".github/workflows/release-readiness.yml", status: "modified" }],
    "protected.delete": [{ filename: ".github/CODEOWNERS", status: "removed" }],
    "protected.copy": [{ filename: ".github/CODEOWNERS", previous_filename: "README.md", status: "copied" }],
    "protected.rename": [{ filename: "docs/renamed.md", previous_filename: ".github/CODEOWNERS", status: "renamed" }],
    "protected.case_fold": [{ filename: "Docs/Collision.md", status: "added" }, { filename: "docs/collision.md", status: "added" }],
  };
  if (protectedRows[caseId]) fixture.files = protectedRows[caseId];
  return fixture;
}

function aggregateEgress(phases) {
  const routeMap = new Map(); const checks = [];
  for (const egress of phases) {
    for (const row of egress.routes) { const key = `${row.route_id}:${row.page ?? 0}:${row.response_class}:${row.rows ?? -1}`; routeMap.set(key, (routeMap.get(key) ?? 0) + 1); }
    checks.push(...egress.checks);
  }
  return { routes: [...routeMap].sort(([a], [b]) => a.localeCompare(b)).map(([key, count]) => ({ key, count })), checks: checks.sort((a, b) => `${a.operation}:${a.conclusion}`.localeCompare(`${b.operation}:${b.conclusion}`)), unmatched: phases.reduce((sum, phase) => sum + phase.unmatched, 0), total: phases.reduce((sum, phase) => sum + phase.total(), 0), token: phases.reduce((sum, phase) => sum + phase.count("installationToken"), 0), create: phases.reduce((sum, phase) => sum + phase.count("createCheck"), 0), update: phases.reduce((sum, phase) => sum + phase.count("updateCheck"), 0), filePages: phases.flatMap((phase) => phase.routes.filter((row) => row.route_id === "pullFiles").map((row) => row.page)) };
}
function externalRecord(record, phases) {
  const egress = aggregateEgress(phases); const statuses = new Map(); for (const status of record.http) statuses.set(status, (statuses.get(status) ?? 0) + 1);
  return { bundle_sha256: bundleHash, import_manifest_sha256: importManifestHash, http: [...statuses].sort(([a], [b]) => a - b).map(([status, count]) => ({ status, count })), scheduled: record.scheduled, recovery_boundaries: record.boundaries, routes: egress.routes, checks: egress.checks, totals: { token: egress.token, create: egress.create, update: egress.update, all: egress.total }, file_pages: egress.filePages, forbidden_egress: egress.unmatched, post_terminal: record.post_terminal, redaction_scan: true };
}

function stoppedInspection(caseId, persistRoot, objectId, creds) {
  ensure(realpathSync(dirname(persistRoot)) === tempRoot && relative(tempRoot, realpathSync(persistRoot)).split(sep)[0] !== "..", caseId, "temp_containment");
  const namespaceRoot = resolve(persistRoot, "-RepositoryDurableObject"); const dbPath = resolve(namespaceRoot, `${objectId}.sqlite`);
  ensure(relative(namespaceRoot, dbPath).split(sep)[0] !== ".." && lstatSync(dbPath).isFile() && !lstatSync(dbPath).isSymbolicLink(), caseId, "sqlite_layout");
  ensure(readFileSync(dbPath).subarray(0, 16).equals(Buffer.from("SQLite format 3\0")), caseId, "sqlite_header");
  const files = [dbPath, `${dbPath}-wal`, `${dbPath}-shm`].filter(existsSync); const fileBytes = files.reduce((sum, path) => sum + statSync(path).size, 0);
  const db = new DatabaseSync(dbPath, { readOnly: true });
  try {
    db.exec("PRAGMA query_only=ON"); ensure(db.prepare("PRAGMA quick_check").get()?.quick_check === "ok", caseId, "sqlite_quick_check");
    const pageCount = Number(db.prepare("PRAGMA page_count").get()?.page_count); const pageSize = Number(db.prepare("PRAGMA page_size").get()?.page_size);
    const tables = db.prepare("SELECT name,sql FROM sqlite_master WHERE type='table' ORDER BY name").all();
    const applicationTables = tables.filter((row) => !String(row.name).startsWith("_cf_")).map((row) => row.name);
    ensure(JSON.stringify(applicationTables) === JSON.stringify(["kv", "meta"]), caseId, "sqlite_schema");
    const schemaVersion = JSON.parse(db.prepare("SELECT value_json FROM meta WHERE key=?").get("schema/version")?.value_json ?? "null"); ensure(schemaVersion === 2, caseId, "schema_version");
    const kv = db.prepare("SELECT key,version,value_json FROM kv ORDER BY key").all(); const meta = db.prepare("SELECT key,value_json FROM meta ORDER BY key").all();
    const parsed = kv.map((row) => ({ key: row.key, version: row.version, value: JSON.parse(row.value_json) }));
    const metaParsed = meta.map((row) => ({ key: row.key, value: JSON.parse(row.value_json) }));
    ensure(parsed.every((row) => Number.isSafeInteger(row.version) && row.version >= 1), caseId, "row_versions");
    let markerMatches = 0;
    for (const marker of creds.markers) { const pattern = `%${marker}%`; markerMatches += Number(db.prepare("SELECT count(*) count FROM kv WHERE key LIKE ? OR value_json LIKE ?").get(pattern, pattern).count); markerMatches += Number(db.prepare("SELECT count(*) count FROM meta WHERE key LIKE ? OR value_json LIKE ?").get(pattern, pattern).count); }
    ensure(markerMatches === 0, caseId, "sqlite_redaction");
    const prefixCounts = {}; const states = {}; let staleLeases = 0;
    for (const row of parsed) { const prefix = String(row.key).split("/")[0]; prefixCounts[prefix] = (prefixCounts[prefix] ?? 0) + 1; const state = row.value?.state; if (typeof state === "string") states[state] = (states[state] ?? 0) + 1; staleLeases += countStaleLeases(row.value); }
    const watchdog = metaParsed.find((row) => row.key === "watchdog/v1")?.value; const watchdogFields = watchdog && typeof watchdog === "object" ? Object.keys(watchdog).sort() : [];
    const alarmCount = metaParsed.find((row) => row.key === "alarm_count/v1")?.value ?? 0;
    const retries = metaParsed.filter((row) => row.key.startsWith("retry/")); const retryClasses = retries.map((row) => row.value?.error_class).filter((value) => typeof value === "string").sort(); const retryAttempts = Math.max(0, ...retries.map((row) => Number(row.value?.attempts) || 0));
    const restoreRows = captureRestoreFixture ? {
      kv: kv.map((row) => ({ durable_row: row.key, version: Number(row.version), value_json: String(row.value_json) })),
      meta: [...restoreIdentityRows(), ...meta.filter((row) => String(row.key).startsWith("target/")).map((row) => { const value = JSON.parse(String(row.value_json)); if (value && typeof value === "object" && "received_at" in value) value.received_at = 0; return { meta_row: row.key, value_json: JSON.stringify(value) }; })].sort((left, right) => left.meta_row.localeCompare(right.meta_row)),
    } : undefined;
    return { quick_check: true, schema_version: schemaVersion, schema_sha256: sha256(tables.filter((row) => applicationTables.includes(row.name)).map((row) => row.sql).join("\n")), rows: parsed.length + metaParsed.length, kv_rows: parsed.length, meta_rows: metaParsed.length, prefix_counts: prefixCounts, states, stale_leases: staleLeases, watchdog_fields: watchdogFields, watchdog, watchdog_reasserted: watchdog?.alarm_reasserted === true, alarm_count: alarmCount, retry_classes: retryClasses, retry_attempts: retryAttempts, page_count: pageCount, page_size: pageSize, database_bytes: fileBytes, redaction_scan: true, restore_rows: restoreRows };
  } finally { db.close(); }
}
function countStaleLeases(value) {
  if (!value || typeof value !== "object") return 0; let count = 0;
  for (const [key, child] of Object.entries(value)) { if ((key === "leaseOwner" || key === "effectLease") && child !== null && child !== undefined) count += 1; else count += countStaleLeases(child); }
  return count;
}

class Lane {
  constructor(caseId, kind, creds, fixture) { this.caseId = caseId; this.kind = kind; this.creds = creds; this.fixture = fixture; this.record = newRecord(caseId); this.phases = []; this.inspections = []; this.persistRoot = null; this.mf = null; this.egress = null; }
  async start(seedCheck = null, fixtureOverride = null) {
    this.egress = new SyntheticEgress(this.caseId, this.creds, fixtureOverride ?? this.fixture, seedCheck); this.phases.push(this.egress);
    if (this.kind === "persistent_sqlite" && this.persistRoot === null) { this.persistRoot = mkdtempSync(join(tempRoot, "archivale-245-do-")); chmodSync(this.persistRoot, 0o700); }
    this.mf = new Miniflare(makeOptions(this.creds, this.egress, this.kind === "persistent_sqlite" ? this.persistRoot : false));
    const removedName = ["dispatch", "Scheduled"].join(""); ensure(typeof this.mf[removedName] === "undefined", this.caseId, "removed_scheduled_present");
  }
  async boundary(expectation) {
    this.record.boundaries += 1;
    if (this.kind === "black_box") { await this.mf.unsafeEvictDurableObject("", "RepositoryDurableObject", { name: `repository:${REPOSITORY_ID}` }); return; }
    const ids = await this.mf.listDurableObjectIds("REPOSITORY"); ensure(ids.length === 1, this.caseId, "durable_identity"); await this.mf.dispose(); this.mf = null;
    const inspection = stoppedInspection(this.caseId, this.persistRoot, ids[0], this.creds); expectation?.(inspection); this.inspections.push(inspection);
    const seed = this.egress.check; const nextFixture = { ...this.fixture, gate: false, ambiguousCreate: false, definiteTokenFailure: false };
    await this.start(seed, nextFixture);
  }
  async finish(expectation) {
    if (this.mf) {
      if (this.kind === "persistent_sqlite") { const ids = await this.mf.listDurableObjectIds("REPOSITORY"); ensure(ids.length === 1, this.caseId, "durable_identity"); await this.mf.dispose(); this.mf = null; const inspection = stoppedInspection(this.caseId, this.persistRoot, ids[0], this.creds); expectation?.(inspection); this.inspections.push(inspection); }
      else { await this.mf.dispose(); this.mf = null; }
    }
    if (this.persistRoot) { const root = this.persistRoot; rmSync(root, { recursive: true, force: true }); ensure(!existsSync(root), this.caseId, "temp_cleanup"); this.persistRoot = null; }
  }
  async cleanup() { if (this.mf) { try { await this.mf.dispose(); } catch {} this.mf = null; } if (this.persistRoot) { rmSync(this.persistRoot, { recursive: true, force: true }); this.persistRoot = null; } }
}

async function standardLifecycle(lane, options = {}) {
  await lane.start(); const body = makeBody();
  await dispatchWebhook(lane.mf, lane.creds, `${lane.caseId}-delivery`, body, lane.record);
  if (lane.fixture.gate) { await waitFor(lane.caseId, () => lane.egress.gateTriggered, "gate_timeout"); const scheduled = runScheduledStep(lane.mf, lane.record, "during"); lane.egress.releaseGate(); await scheduled; } else await runScheduledStep(lane.mf, lane.record, "drive");
  if (options.expectUpdate !== false) await waitFor(lane.caseId, () => aggregateEgress(lane.phases).update === 1);
  await runScheduledStep(lane.mf, lane.record, "quiescence-1"); await runScheduledStep(lane.mf, lane.record, "quiescence-2");
  const aggregate = aggregateEgress(lane.phases); lane.record.post_terminal = aggregate.create <= 1 && aggregate.update <= 1;
  return aggregate;
}

async function runLane(caseId, kind, creds) {
  const lane = new Lane(caseId, kind, creds, fixtureFor(caseId));
  try {
    if (caseId === "race.duplicate_same_generation") {
      await lane.start(); const body = makeBody();
      await dispatchWebhook(lane.mf, lane.creds, "race-shared", body, lane.record); await waitFor(caseId, () => lane.egress.gateTriggered, "gate_timeout");
      const requests = [...Array.from({ length: 31 }, () => dispatchWebhook(lane.mf, lane.creds, "race-shared", body, lane.record)), ...Array.from({ length: 16 }, (_, index) => dispatchWebhook(lane.mf, lane.creds, `race-${index}`, body, lane.record))];
      await Promise.all(requests); const scheduled = runScheduledStep(lane.mf, lane.record, "during"); lane.egress.releaseGate(); await scheduled; await waitFor(caseId, () => aggregateEgress(lane.phases).update === 1); await runScheduledStep(lane.mf, lane.record, "quiescence-1"); await runScheduledStep(lane.mf, lane.record, "quiescence-2"); lane.record.post_terminal = true;
      const aggregate = aggregateEgress(lane.phases); ensure(lane.record.http.length === 48 && lane.record.http.every((status) => status === 202) && aggregate.create === 1 && aggregate.update === 1, caseId, "race_outcome");
      await lane.finish((inspection) => { ensure(inspection.prefix_counts.receipt === 17 && inspection.prefix_counts.generation === 1 && inspection.prefix_counts.current === 1 && inspection.prefix_counts.binding === 1 && inspection.stale_leases === 0, caseId, "race_sqlite"); });
    } else if (caseId === "race.delivery_conflict") {
      await lane.start(); const first = dispatchWebhook(lane.mf, lane.creds, "conflict-delivery", makeBody("opened"), lane.record); const second = dispatchWebhook(lane.mf, lane.creds, "conflict-delivery", makeBody("reopened"), lane.record);
      await Promise.all([first, second]); await runScheduledStep(lane.mf, lane.record, "drive"); await runScheduledStep(lane.mf, lane.record, "quiescence-1");
      const aggregate = aggregateEgress(lane.phases); ensure(lane.record.http.every((status) => status === 202) && aggregate.create === 0 && aggregate.update === 0, caseId, "conflict_outcome"); lane.record.post_terminal = true;
      await lane.finish((inspection) => ensure(inspection.states.conflict === 1 && !inspection.prefix_counts.generation, caseId, "conflict_sqlite"));
    } else if (caseId === "replay.after_restart") {
      let aggregate = await standardLifecycle(lane); const before = { total: aggregate.total, create: aggregate.create, update: aggregate.update };
      await lane.boundary((inspection) => ensure(inspection.states.terminal_success === 2 && inspection.stale_leases === 0, caseId, "replay_checkpoint"));
      await dispatchWebhook(lane.mf, lane.creds, `${caseId}-delivery`, makeBody(), lane.record); await runScheduledStep(lane.mf, lane.record, "replay"); aggregate = aggregateEgress(lane.phases);
      ensure(aggregate.total === before.total && aggregate.create === before.create && aggregate.update === before.update, caseId, "replay_egress"); lane.record.post_terminal = true; await lane.finish();
    } else if (caseId === "recovery.ambiguous_create" || caseId === "recovery.definite_presend") {
      await lane.start(); await dispatchWebhook(lane.mf, lane.creds, `${caseId}-delivery`, makeBody(), lane.record);
      const threshold = caseId.endsWith("ambiguous_create") ? () => aggregateEgress(lane.phases).create === 1 : () => lane.egress.tokenFailures === 1;
      await runScheduledStep(lane.mf, lane.record, "initial"); await waitFor(caseId, threshold); await sleep(100);
      const seed = lane.egress.check; await lane.boundary((inspection) => {
        if (caseId.endsWith("ambiguous_create")) { ensure(inspection.states.possible_send >= 1 && inspection.retry_classes.length >= 1, caseId, "ambiguous_checkpoint"); if (captureRestoreFixture && kind === "persistent_sqlite") writeFileSync(restoreFixturePath, JSON.stringify({ schema_version: 1, checkpoint: "ambiguous_create_possible_send", ...inspection.restore_rows }) + "\n"); }
        else ensure(inspection.states.snapshotting === 1 && inspection.retry_classes.includes("transient"), caseId, "definite_checkpoint");
      });
      if (kind === "black_box") { lane.egress.fixture.ambiguousCreate = false; lane.egress.fixture.definiteTokenFailure = false; lane.egress.check = seed; }
      await sleep(1_100); await runScheduledStep(lane.mf, lane.record, "recover"); try { await waitFor(caseId, () => aggregateEgress(lane.phases).update === 1); } catch { const failed = aggregateEgress(lane.phases); if (kind === "persistent_sqlite") { const ids = await lane.mf.listDurableObjectIds("REPOSITORY"); await lane.mf.dispose(); lane.mf = null; const inspection = stoppedInspection(caseId, lane.persistRoot, ids[0], lane.creds); throw new HarnessFailure(caseId, inspection.alarm_count > 1 ? `retry_alarm_ran_${inspection.retry_attempts}` : inspection.watchdog_reasserted ? "retry_reassert_no_alarm" : `retry_not_reasserted_${inspection.retry_attempts}`); } throw new HarnessFailure(caseId, failed.token === 1 ? "retry_alarm_absent" : failed.create === 0 ? "retry_snapshot_incomplete" : "retry_update_incomplete"); } await runScheduledStep(lane.mf, lane.record, "quiescence-1"); lane.record.post_terminal = true;
      const aggregate = aggregateEgress(lane.phases); ensure(aggregate.create === 1 && aggregate.update === 1, caseId, "recovery_outcome"); await lane.finish((inspection) => ensure(inspection.states.terminal_success === 2 && inspection.stale_leases === 0, caseId, "recovery_final"));
    } else if (caseId === "alarm.sole_drainer") {
      await lane.start(); const webhook = dispatchWebhook(lane.mf, lane.creds, `${caseId}-delivery`, makeBody(), lane.record); await waitFor(caseId, () => lane.egress.gateTriggered, "gate_timeout"); await webhook;
      const scheduled = [runScheduledStep(lane.mf, lane.record, "watchdog-1"), runScheduledStep(lane.mf, lane.record, "watchdog-2")]; lane.egress.releaseGate(); await Promise.all(scheduled); await waitFor(caseId, () => aggregateEgress(lane.phases).update === 1); await runScheduledStep(lane.mf, lane.record, "quiescence-1"); lane.record.post_terminal = true;
      const aggregate = aggregateEgress(lane.phases); ensure(aggregate.create === 1 && aggregate.update === 1, caseId, "sole_drainer_outcome"); await lane.finish((inspection) => ensure(inspection.alarm_count <= 8 && inspection.stale_leases === 0, caseId, "sole_drainer_sqlite"));
    } else if (caseId === "telemetry.watchdog") {
      await lane.start(); await runScheduledStep(lane.mf, lane.record, "before"); const webhook = dispatchWebhook(lane.mf, lane.creds, `${caseId}-delivery`, makeBody(), lane.record); await waitFor(caseId, () => lane.egress.gateTriggered, "gate_timeout"); await webhook; const during = runScheduledStep(lane.mf, lane.record, "during"); lane.egress.releaseGate(); await during; await waitFor(caseId, () => aggregateEgress(lane.phases).update === 1); await runScheduledStep(lane.mf, lane.record, "after"); lane.record.post_terminal = true;
      await lane.finish((inspection) => { const allowed = ["alarm_present", "alarm_reasserted", "do_headroom_bucket", "duplicate_binding_bucket", "duplicate_check_bucket", "exceeded_resource_bucket", "forbidden_egress_bucket", "oldest_work_bucket", "pending_bucket", "provider_error_bucket", "request_headroom_bucket", "row_headroom_bucket", "status_egress_bucket", "storage_headroom_bucket", "worker_error_bucket"]; ensure(JSON.stringify(inspection.watchdog_fields) === JSON.stringify(allowed) && inspection.redaction_scan, caseId, "telemetry_shape"); ensure(["duplicate_check_bucket", "exceeded_resource_bucket", "forbidden_egress_bucket", "provider_error_bucket", "status_egress_bucket", "worker_error_bucket"].every((field) => inspection.watchdog[field] === 0), caseId, "telemetry_zero_transition"); });
    } else if (caseId.startsWith("pagination.") && !["pagination.ordinary", "pagination.101", "pagination.3000"].includes(caseId) || caseId === "budget.call_51" || caseId === "protected.case_fold") {
      await lane.start(); await dispatchWebhook(lane.mf, lane.creds, `${caseId}-delivery`, makeBody(), lane.record);
      const expected = caseId === "budget.call_51" ? () => aggregateEgress(lane.phases).total === 50 : caseId === "pagination.declared_3001" ? () => lane.egress.count("pullRequest") >= 1 : () => lane.egress.count("pullFiles") >= (caseId === "pagination.page_31" ? 30 : 1);
      await waitFor(caseId, expected); await sleep(100); await runScheduledStep(lane.mf, lane.record, "recovery-watchdog"); const aggregate = aggregateEgress(lane.phases);
      ensure(aggregate.update === 0 && aggregate.filePages.filter((page) => page === 31).length === 0 && aggregate.unmatched === 0, caseId, "rejection_egress");
      if (caseId === "budget.call_51") ensure(aggregate.total === 50 && aggregate.create === 1 && aggregate.update === 0, caseId, "budget_boundary"); else ensure(aggregate.create === 0, caseId, "rejection_created");
      lane.record.post_terminal = true; await lane.finish((inspection) => { ensure(inspection.retry_classes.length >= 1 && inspection.alarm_count <= 8, caseId, "rejection_recovery"); if (caseId === "budget.call_51") ensure(inspection.watchdog?.duplicate_check_bucket >= 1 && inspection.watchdog?.exceeded_resource_bucket >= 1 && inspection.watchdog?.request_headroom_bucket === 2 && inspection.watchdog?.worker_error_bucket >= 1, caseId, "telemetry_nonzero_transition"); });
    } else {
      const aggregate = await standardLifecycle(lane);
      ensure(aggregate.create === 1 && aggregate.update === 1 && aggregate.unmatched === 0, caseId, "lifecycle_outcome");
      if (caseId === "pagination.ordinary") ensure(JSON.stringify(aggregate.filePages) === "[1]", caseId, "ordinary_pages");
      if (caseId === "pagination.101") ensure(JSON.stringify(aggregate.filePages) === "[1,2]", caseId, "pages_101");
      if (caseId === "pagination.3000") ensure(aggregate.filePages.length === 30 && aggregate.filePages.every((page, index) => page === index + 1) && aggregate.total === 40 && aggregate.token === 1, caseId, "pages_3000");
      if (caseId.startsWith("protected.")) ensure(aggregate.checks.some((row) => row.operation === "update" && row.conclusion === "failure"), caseId, "protected_conclusion");
      await lane.finish((inspection) => ensure(inspection.rows <= 100 && inspection.database_bytes <= 1_048_576 && inspection.alarm_count <= 8 && inspection.stale_leases === 0, caseId, "resource_bounds"));
    }
    const external = externalRecord(lane.record, lane.phases);
    ensure(external.forbidden_egress === 0, caseId, "forbidden_egress");
    return { external, inspections: lane.inspections };
  } catch (error) { await lane.cleanup(); throw error; }
}

function boundedEvidence(results, miniflareVersion) {
  const bucketFields = ["do_headroom_bucket", "duplicate_binding_bucket", "duplicate_check_bucket", "exceeded_resource_bucket", "forbidden_egress_bucket", "oldest_work_bucket", "pending_bucket", "provider_error_bucket", "request_headroom_bucket", "row_headroom_bucket", "status_egress_bucket", "storage_headroom_bucket", "worker_error_bucket"];
  return { schema_version: 1, node: process.version, miniflare: miniflareVersion, bundle_sha256: bundleHash, import_manifest_sha256: importManifestHash, paired_black_box: true, paired_persistent_sqlite: true, unsafe_live_inspection: false, scheduled_proxy: true, removed_miniflare_dispatch_absent: true, scheduled_http_trigger_count: 0, case_count: results.length, cases: results.map((result) => { const finalWatchdog = result.inspections.at(-1)?.watchdog ?? {}; return { case_id: result.caseId, external_equivalence: true, route_count: result.external.totals.all, create_count: result.external.totals.create, update_count: result.external.totals.update, forbidden_egress_count: result.external.forbidden_egress, telemetry_buckets: Object.fromEntries(bucketFields.map((field) => [field, finalWatchdog[field] ?? 2])), row_count_within_bound: result.inspections.every((row) => row.rows <= 100), database_bytes_within_bound: result.inspections.every((row) => row.database_bytes <= 1_048_576), alarm_count_within_bound: result.inspections.every((row) => row.alarm_count <= 8), redaction_scan: result.inspections.every((row) => row.redaction_scan) }; }), temp_cleanup: true, production_config_leakage: false, deployed_cpu_quota_proof: false };
}

async function main() {
  const miniflareVersion = preflight(); const results = [];
  for (const caseId of CASE_IDS) {
    const creds = credentials(); const black = await runLane(caseId, "black_box", creds); const persistent = await runLane(caseId, "persistent_sqlite", creds);
    try { assert.deepEqual(persistent.external, black.external); } catch { throw new HarnessFailure(caseId, "external_equivalence"); }
    results.push({ caseId, external: black.external, inspections: persistent.inspections, markers: creds.markers });
  }
  const evidence = boundedEvidence(results, miniflareVersion); const encoded = JSON.stringify(evidence) + "\n";
  for (const result of results) for (const marker of result.markers) ensure(!encoded.includes(marker), result.caseId, "evidence_redaction");
  writeFileSync(evidencePath, encoded); process.stdout.write(`sqlite conformance passed (${CASE_IDS.length} cases, ${CASE_IDS.length * 2} uninstrumented lanes)\n`);
}

function validateRestoreFixture(bytes) {
  let fixture;
  try { fixture = JSON.parse(bytes.toString("utf8")); } catch { throw new HarnessFailure("restore.rehearsal", "fixture_schema"); }
  ensure(fixture?.schema_version === 1 && fixture.checkpoint === "ambiguous_create_possible_send" && Array.isArray(fixture.kv) && Array.isArray(fixture.meta), "restore.rehearsal", "fixture_schema");
  const keys = new Set(); const states = new Set();
  const containsForbiddenField = (value) => { if (!value || typeof value !== "object") return false; return Object.entries(value).some(([key, child]) => /^(?:authorization|cookie|secret|token|private.?key|x-hub-signature|headers?|body)$/i.test(key) || containsForbiddenField(child)); };
  const parseCanonical = (value, failureClass) => { try { const parsed = JSON.parse(value); ensure(JSON.stringify(parsed) === value, "restore.rehearsal", failureClass); return parsed; } catch (error) { if (error instanceof HarnessFailure) throw error; throw new HarnessFailure("restore.rehearsal", failureClass); } };
  for (const row of fixture.kv) { ensure(row && typeof row.durable_row === "string" && /^(binding|current|generation|outbox|receipt)\//.test(row.durable_row) && Number.isSafeInteger(row.version) && row.version >= 1 && typeof row.value_json === "string" && !keys.has(row.durable_row), "restore.rehearsal", "fixture_row"); keys.add(row.durable_row); const value = parseCanonical(row.value_json, "fixture_row"); ensure(!containsForbiddenField(value), "restore.rehearsal", "fixture_redaction"); if (typeof value?.state === "string") states.add(value.state); }
  const expectedIdentity = new Map(restoreIdentityRows().map((row) => [row.meta_row, row.value_json])); const metadata = new Map();
  for (const row of fixture.meta) { ensure(row && typeof row.meta_row === "string" && typeof row.value_json === "string" && !metadata.has(row.meta_row), "restore.rehearsal", "fixture_meta"); const value = parseCanonical(row.value_json, "fixture_meta"); ensure(!containsForbiddenField(value), "restore.rehearsal", "fixture_redaction"); metadata.set(row.meta_row, row.value_json); }
  const targetKeys = [...metadata.keys()].filter((key) => /^target\//.test(key));
  ensure(targetKeys.length === 1 && metadata.size === expectedIdentity.size + 1 && [...expectedIdentity].every(([key, value]) => metadata.get(key) === value) && targetKeys.every((key) => !expectedIdentity.has(key)), "restore.rehearsal", "fixture_identity");
  ensure(["possible_send", "create_possible", "decision_ready", "enqueued", "delivered"].every((state) => states.has(state)), "restore.rehearsal", "fixture_checkpoint");
  ensure(!/BEGIN PRIVATE KEY/.test(bytes.toString("utf8")), "restore.rehearsal", "fixture_redaction");
  return fixture;
}

function assertRestoreFixtureNegatives(fixtureBytes) {
  const fixture = JSON.parse(fixtureBytes.toString("utf8"));
  const rejected = [];
  const expectRejected = (mutate) => {
    const candidate = JSON.parse(JSON.stringify(fixture)); mutate(candidate);
    try { validateRestoreFixture(Buffer.from(JSON.stringify(candidate))); } catch (error) { if (error instanceof HarnessFailure && /^fixture_(?:schema|meta|identity|redaction)$/.test(error.failureClass)) { rejected.push(error.failureClass); return; } }
    throw new HarnessFailure("restore.rehearsal", "fixture_negative_accepted");
  };
  for (const key of restoreIdentityRows().map((row) => row.meta_row)) expectRejected((candidate) => { candidate.meta = candidate.meta.filter((row) => row.meta_row !== key); });
  expectRejected((candidate) => { candidate.meta.push({ meta_row: "schema_version", value_json: "1" }); });
  expectRejected((candidate) => { candidate.meta.find((row) => row.meta_row === "schema/version").value_json = "3"; });
  expectRejected((candidate) => { candidate.meta.find((row) => row.meta_row === "schema/state").value_json = JSON.stringify("pending"); });
  expectRejected((candidate) => { candidate.meta.find((row) => row.meta_row === "schema/id").value_json = JSON.stringify("other"); });
  expectRejected((candidate) => { candidate.meta.find((row) => row.meta_row === "schema/digest").value_json = JSON.stringify("sha256:" + "0".repeat(64)); });
  expectRejected((candidate) => { candidate.meta.find((row) => row.meta_row === "compatibility/digest").value_json = JSON.stringify("sha256:" + "0".repeat(64)); });
  expectRejected((candidate) => { candidate.meta.find((row) => row.meta_row === "activation/digest").value_json = JSON.stringify("sha256:" + "0".repeat(64)); });
  expectRejected((candidate) => { candidate.meta.push({ ...candidate.meta[0] }); });
  expectRejected((candidate) => { candidate.meta.push({ meta_row: "extra/v1", value_json: "0" }); });
  expectRejected((candidate) => { candidate.meta.find((row) => /^target\//.test(row.meta_row)).value_json = "{"; });
  expectRejected((candidate) => { candidate.meta.find((row) => /^target\//.test(row.meta_row)).value_json = JSON.stringify({ token: "synthetic" }); });
  ensure(rejected.length === 17, "restore.rehearsal", "fixture_negative_coverage");
}

async function restoreRehearsal() {
  preflight(); const fixtureBytes = readFileSync(restoreFixturePath); const fixture = validateRestoreFixture(fixtureBytes); assertRestoreFixtureNegatives(fixtureBytes); const caseId = "restore.rehearsal";
  const persistRoot = mkdtempSync(join(tempRoot, "archivale-245-restore-")); chmodSync(persistRoot, 0o700); const creds = credentials(); const record = newRecord(caseId);
  let mf; let objectId; let dbPath; let quickCheck = false; let duplicateBindings = -1; let exactRowMatch = false;
  const binding = fixture.kv.map((row) => JSON.parse(row.value_json)).find((value) => value?.state === "create_possible");
  ensure(binding && typeof binding.externalId === "string", caseId, "fixture_binding");
  const seedCheck = { app: { id: APP_ID }, id: CHECK_ID, external_id: binding.externalId, head_sha: HEAD_SHA, name: binding.checkName };
  const egress = new SyntheticEgress(caseId, creds, fixtureFor("recovery.ambiguous_create"), seedCheck);
  try {
    mf = new Miniflare(makeOptions(creds, egress, persistRoot)); await runScheduledStep(mf, record, "initialize-layout");
    const ids = await mf.listDurableObjectIds("REPOSITORY"); ensure(ids.length === 1, caseId, "durable_identity"); objectId = ids[0]; await mf.dispose(); mf = null;
    const namespaceRoot = resolve(persistRoot, "-RepositoryDurableObject"); dbPath = resolve(namespaceRoot, `${objectId}.sqlite`);
    const restored = new DatabaseSync(dbPath); restored.exec("BEGIN IMMEDIATE");
    try {
      restored.exec("DELETE FROM kv; DELETE FROM meta");
      const insertKv = restored.prepare("INSERT INTO kv(key,version,value_json) VALUES(?,?,?)"); for (const row of fixture.kv) insertKv.run(row.durable_row, row.version, row.value_json);
      const insertMeta = restored.prepare("INSERT INTO meta(key,value_json) VALUES(?,?)"); for (const row of fixture.meta) insertMeta.run(row.meta_row, row.value_json);
      restored.exec("COMMIT");
    } catch (error) { restored.exec("ROLLBACK"); throw error; } finally { restored.close(); }
    const restoredReadOnly = new DatabaseSync(dbPath, { readOnly: true }); restoredReadOnly.exec("PRAGMA query_only=ON");
    const restoredKv = restoredReadOnly.prepare("SELECT key,version,value_json FROM kv ORDER BY key").all(); const restoredMeta = restoredReadOnly.prepare("SELECT key,value_json FROM meta ORDER BY key").all(); restoredReadOnly.close();
    const expectedKv = fixture.kv.map((row) => ({ key: row.durable_row, version: row.version, value_json: row.value_json })).sort((a, b) => a.key.localeCompare(b.key)); const expectedMeta = fixture.meta.map((row) => ({ key: row.meta_row, value_json: row.value_json })).sort((a, b) => a.key.localeCompare(b.key));
    exactRowMatch = JSON.stringify(restoredKv) === JSON.stringify(expectedKv) && JSON.stringify(restoredMeta) === JSON.stringify(expectedMeta); ensure(exactRowMatch, caseId, "restore_exact_rows");
    mf = new Miniflare(makeOptions(creds, egress, persistRoot)); await Promise.all([runScheduledStep(mf, record, "restore-watchdog-1"), runScheduledStep(mf, record, "restore-watchdog-2")]); await waitFor(caseId, () => egress.count("updateCheck") === 1, "restore_reconcile_timeout");
    ensure(egress.count("createCheck") === 0, caseId, "restore_duplicate_create");
    const beforeReplay = egress.total(); const status = await dispatchWebhook(mf, creds, "recovery.ambiguous_create-delivery", makeBody(), record); ensure(status === 202, caseId, "restore_replay_status"); await Promise.all([runScheduledStep(mf, record, "restore-replay-watchdog-1"), runScheduledStep(mf, record, "restore-replay-watchdog-2")]); await sleep(250);
    ensure(egress.total() === beforeReplay && egress.count("createCheck") === 0 && egress.count("updateCheck") === 1, caseId, "restore_replay_egress");
    await mf.dispose(); mf = null;
    const inspection = stoppedInspection(caseId, persistRoot, objectId, creds); quickCheck = inspection.quick_check;
    const readOnly = new DatabaseSync(dbPath, { readOnly: true }); readOnly.exec("PRAGMA query_only=ON");
    const bindingRows = readOnly.prepare("SELECT value_json FROM kv WHERE key LIKE 'binding/%'").all().map((row) => JSON.parse(String(row.value_json)));
    duplicateBindings = bindingRows.length - new Set(bindingRows.map((row) => `${row.checkId}:${row.externalId}`)).size; readOnly.close();
    ensure(inspection.states.terminal_success === 2 && inspection.stale_leases === 0 && duplicateBindings === 0 && bindingRows.length === 1 && bindingRows[0].checkId === CHECK_ID, caseId, "restore_terminal_binding");
  } finally { if (mf) await mf.dispose(); rmSync(persistRoot, { recursive: true, force: true }); }
  ensure(!existsSync(persistRoot), caseId, "temp_cleanup");
  const evidence = { schema_version: 1, fixture_sha256: sha256(fixtureBytes), bundle_sha256: bundleHash, import_manifest_sha256: importManifestHash, checkpoint: fixture.checkpoint, restored_kv_rows: fixture.kv.length, restored_meta_rows: fixture.meta.length, restored_schema_v2_identity: Object.fromEntries(restoreIdentityRows().map((row) => [row.meta_row, JSON.parse(row.value_json)])), exact_row_match_before_boot: exactRowMatch, exact_bundle_recovery: true, concurrent_watchdogs_alarm_only: true, ambiguous_create_reconciled: true, replay_accepted: true, create_count: egress.count("createCheck"), update_count: egress.count("updateCheck"), duplicate_check_count: 0, duplicate_binding_count: duplicateBindings, sqlite_quick_check: quickCheck, forbidden_egress_count: egress.unmatched, redaction_scan: true, temp_cleanup: true };
  writeFileSync(resolve(packageRoot, "evidence/restore-rehearsal.v1.json"), JSON.stringify(evidence) + "\n"); process.stdout.write(`restore rehearsal passed (${fixture.kv.length} durable rows through exact bundle)\n`);
}

(runRestoreOnly ? restoreRehearsal() : main()).catch((error) => { const failure = sanitizedFailure(error); process.stderr.write(`${runRestoreOnly ? "restore rehearsal" : "sqlite conformance"} failed (${failure.caseId}:${failure.failureClass})\n`); process.exitCode = 1; });
