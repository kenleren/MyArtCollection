/** The sole network-capable module.  Its public shape is the core's closed
 * Check Runs port: callers cannot construct URLs, send statuses, or use GraphQL. */
import type { AppCheck, CreateCheckInput, GitHubCheckRunsPort, MainRefSnapshot, OpenMainPullRequest, Page, PullRequestSnapshot, UpdateCheckInput } from "@archivale/release-policy-trust";
import type { ChangedFile } from "@archivale/release-policy-trust";
import { githubRoute, type Route } from "./github_routes.js";

type Json = Record<string, unknown> | unknown[];
const MAX_RESPONSE_BYTES: Record<Route, number> = { installationToken: 16_384, pullRequest: 131_072, mainRef: 16_384, pullFiles: 1_048_576, openMainPulls: 1_048_576, appChecks: 1_048_576, createCheck: 131_072, updateCheck: 131_072 };
async function boundedJson(response: Response, limit: number): Promise<Json> {
  const declared = response.headers.get("content-length"); if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > limit)) throw new Error("github response exceeds bound");
  const reader = response.body?.getReader(); if (!reader) throw new Error("github response missing body"); const chunks: Uint8Array[] = []; let size = 0;
  try { for (;;) { const next = await reader.read(); if (next.done) break; size += next.value.byteLength; if (size > limit) { await reader.cancel(); throw new Error("github response exceeds bound"); } chunks.push(next.value); } } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size); let offset = 0; for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)) as Json; } catch { throw new Error("github JSON rejected"); }
}
export class GitHubAppPort implements GitHubCheckRunsPort {
  constructor(private readonly fetcher: typeof fetch, private readonly authorization: () => Promise<string>) {}
  private async json(route: Route, args: readonly (string | number)[], query = "", body?: unknown): Promise<Json> {
    const base = githubRoute(route, args, query);
    const token = await this.authorization();
    if (!token || /[\r\n]/.test(token)) throw new Error("github authorization unavailable");
    const init = body === undefined ? { headers: { ...Object.fromEntries(base.headers), Authorization: `Bearer ${token}` } } : { headers: { ...Object.fromEntries(base.headers), Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify(body) };
    const response = await this.fetcher(new Request(base, init));
    if (response.redirected || !response.ok || !/^application\/json(?:;|$)/i.test(response.headers.get("content-type") ?? "")) throw new Error("github route rejected");
    return boundedJson(response, MAX_RESPONSE_BYTES[route]);
  }
  async getPullRequest(repositoryId: number, number: number): Promise<PullRequestSnapshot> { return this.json("pullRequest", [repositoryId, number]).then((v) => this.pr(v)); }
  async getMainRef(repositoryId: number): Promise<MainRefSnapshot> { const v = await this.json("mainRef", [repositoryId]) as Record<string, unknown>; return { repositoryId, ref: "refs/heads/main", sha: this.string(v.object && (v.object as Record<string, unknown>).sha) }; }
  async listPullRequestFiles(repositoryId: number, number: number, page: number, perPage: number): Promise<Page<ChangedFile>> { const v = await this.json("pullFiles", [repositoryId, number], `page=${page}&per_page=${perPage}`); return { items: this.array(v).map((x) => ({ path: this.string(x.filename), status: this.string(x.status) as ChangedFile["status"], ...(typeof x.previous_filename === "string" ? { previousPath: x.previous_filename } : {}) })), nextPage: this.next(v, page) }; }
  async listOpenMainPullRequests(repositoryId: number, page: number, perPage: number): Promise<Page<OpenMainPullRequest>> { const v = await this.json("openMainPulls", [repositoryId], `state=open&base=main&page=${page}&per_page=${perPage}`); return { items: this.array(v).map((x) => ({ ...this.pr(x), createdAt: this.string(x.created_at) })), nextPage: this.next(v, page) }; }
  async listAppChecks(repositoryId: number, headSha: string, page: number, perPage: number): Promise<Page<AppCheck>> { const v = await this.json("appChecks", [repositoryId, headSha], `page=${page}&per_page=${perPage}`) as Record<string, unknown>; return { items: this.array(v.check_runs).map((x) => this.check(repositoryId, x)), nextPage: this.next(v.check_runs ?? [], page) }; }
  async createCheck(input: CreateCheckInput): Promise<AppCheck> { return this.json("createCheck", [input.repositoryId], "", { name: input.name, head_sha: input.headSha, external_id: input.externalId, status: "in_progress" }).then((v) => this.check(input.repositoryId, v)); }
  async updateCheck(input: UpdateCheckInput): Promise<void> { await this.json("updateCheck", [input.repositoryId, input.checkId], "", { status: "completed", conclusion: input.conclusion, output: { title: "Release policy", summary: input.summary } }); }
  private array(v: unknown): Record<string, unknown>[] { if (!Array.isArray(v)) throw new Error("github schema rejected"); return v.map((x) => { if (!x || typeof x !== "object" || Array.isArray(x)) throw new Error("github schema rejected"); return x as Record<string, unknown>; }); }
  private string(v: unknown): string { if (typeof v !== "string" || v.length === 0) throw new Error("github schema rejected"); return v; }
  private number(v: unknown): number { if (typeof v !== "number" || !Number.isSafeInteger(v) || v <= 0) throw new Error("github schema rejected"); return v; }
  private next(v: unknown, page: number): number | null { return this.array(v).length === 0 ? null : page + 1; }
  private pr(v: unknown): PullRequestSnapshot { const x = v as Record<string, unknown>; const base = x.base as Record<string, unknown>; const head = x.head as Record<string, unknown>; const repo = x.base_repo as Record<string, unknown> | undefined; return { appId: this.number((x.app as Record<string, unknown>)?.id), baseRef: this.string(base?.ref), baseSha: this.string(base?.sha), changedFiles: this.number(x.changed_files), headRepositoryId: this.number((head?.repo as Record<string, unknown>)?.id), headSha: this.string(head?.sha), installationId: this.number((x.installation as Record<string, unknown>)?.id), number: this.number(x.number), repositoryId: this.number(repo?.id), repositoryName: this.string(repo?.full_name), state: "open" }; }
  private check(repositoryId: number, v: unknown): AppCheck { const x = v as Record<string, unknown>; return { appId: this.number((x.app as Record<string, unknown>)?.id), checkId: this.number(x.id), externalId: this.string(x.external_id), headSha: this.string(x.head_sha), name: this.string(x.name), repositoryId }; }
}

function base64Url(bytes: Uint8Array): string {
  let binary = ""; for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}
function pemBytes(pem: string): Uint8Array {
  if (!/^-----BEGIN PRIVATE KEY-----\r?\n[\sA-Za-z0-9+/=]+\r?\n-----END PRIVATE KEY-----\s*$/.test(pem)) throw new Error("github private key malformed");
  const binary = atob(pem.replace(/-----[^-]+-----|\s/g, ""));
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}
/** Builds an App JWT and installation token only in memory for the one fixed route. */
export function githubInstallationAuthorization(input: { appId: number; installationId: number; privateKeyPem: string; fetcher: typeof fetch; now?: () => number }): () => Promise<string> {
  return async () => {
    const now = Math.floor((input.now?.() ?? Date.now()) / 1000);
    const header = base64Url(new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
    const claims = base64Url(new TextEncoder().encode(JSON.stringify({ iat: now - 30, exp: now + 540, iss: input.appId })));
    const key = await crypto.subtle.importKey("pkcs8", pemBytes(input.privateKeyPem), { hash: "SHA-256", name: "RSASSA-PKCS1-v1_5" }, false, ["sign"]);
    const signature = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`)));
    const request = githubRoute("installationToken", [input.installationId]);
    const response = await input.fetcher(new Request(request, { headers: { ...Object.fromEntries(request.headers), Authorization: `Bearer ${header}.${claims}.${base64Url(signature)}` } }));
    if (response.redirected || !response.ok || !/^application\/json(?:;|$)/i.test(response.headers.get("content-type") ?? "")) throw new Error("github installation token rejected");
    const body = await boundedJson(response, MAX_RESPONSE_BYTES.installationToken) as { token?: unknown };
    if (typeof body.token !== "string" || body.token.length === 0 || /[\r\n]/.test(body.token)) throw new Error("github installation token malformed");
    return body.token;
  };
}
