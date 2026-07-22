/** The sole network-capable module.  Its public shape is the core's closed
 * Check Runs port: callers cannot construct URLs, send statuses, or use GraphQL. */
import { DefinitiveNotSentError } from "@archivale/release-policy-trust";
import { githubRoute, isExactGithubRequest } from "./github_routes.js";
const MAX_RESPONSE_BYTES = { installationToken: 16_384, pullRequest: 131_072, mainRef: 16_384, pullFiles: 1_048_576, openMainPulls: 1_048_576, appChecks: 1_048_576, createCheck: 131_072, updateCheck: 131_072 };
const PAGE_CEILING = { pullFiles: 30, openMainPulls: 10, appChecks: 30 };
const callFetch = (fetcher, request, init) => Reflect.apply(fetcher, globalThis, init === undefined ? [request] : [request, init]);
function paginationRejected() { throw new Error("github pagination rejected"); }
function canonicalPage(value, ceiling) { if (!/^[1-9][0-9]*$/.test(value))
    return paginationRejected(); const page = Number(value); if (!Number.isSafeInteger(page) || page > ceiling)
    return paginationRejected(); return page; }
function exactQuery(url, request, page, route) {
    if (!url.search || /%/.test(url.search))
        return paginationRejected();
    const expected = request.search.slice(1).split("&");
    const actual = url.search.slice(1).split("&");
    if (actual.length !== expected.length || new Set(actual.map((x) => x.split("=")[0])).size !== actual.length)
        return paginationRejected();
    const values = new Map(actual.map((entry) => { const pieces = entry.split("="); if (pieces.length !== 2 || !pieces[0] || !pieces[1])
        return paginationRejected(); return [pieces[0], pieces[1]]; }));
    for (const entry of expected) {
        const [key, value] = entry.split("=");
        if (!key || !value || !values.has(key))
            return paginationRejected();
        if (key === "page") {
            if (canonicalPage(values.get(key), PAGE_CEILING[route]) !== page)
                return paginationRejected();
        }
        else if (values.get(key) !== value)
            return paginationRejected();
    }
}
function parsePagination(link, request, route, current) {
    if (link === null)
        return null;
    const bytes = new TextEncoder().encode(link);
    if (bytes.length === 0 || bytes.length > 8192 || !/^(?:[\x20-\x7e]|\t)+$/.test(link))
        return paginationRejected();
    const members = link.split(",");
    if (members.length > 4 || members.some((member) => new TextEncoder().encode(member).length === 0 || new TextEncoder().encode(member).length > 2048))
        return paginationRejected();
    const relations = new Map();
    for (const member of members) {
        const match = /^[ \t]*<(https:\/\/api\.github\.com\/[^<>"\s]+)>[ \t]*;[ \t]*rel="(next|prev|first|last)"[ \t]*$/.exec(member);
        if (!match)
            return paginationRejected();
        const [, targetText, relation] = match;
        if (!targetText || !relation || relations.has(relation))
            return paginationRejected();
        let target;
        try {
            target = new URL(targetText);
        }
        catch {
            return paginationRejected();
        }
        if (target.origin !== "https://api.github.com" || target.username || target.password || target.hash || target.pathname !== request.pathname)
            return paginationRejected();
        const targetPage = canonicalPage(target.searchParams.get("page") ?? "", PAGE_CEILING[route]);
        exactQuery(target, request, targetPage, route);
        relations.set(relation, targetPage);
    }
    const first = relations.get("first");
    const prev = relations.get("prev");
    const next = relations.get("next");
    const last = relations.get("last");
    if (first !== undefined && first !== 1)
        return paginationRejected();
    if (prev !== undefined && (current === 1 || prev !== current - 1))
        return paginationRejected();
    if (next !== undefined && next !== current + 1)
        return paginationRejected();
    if (last !== undefined && (last < current || last > PAGE_CEILING[route]))
        return paginationRejected();
    if (next === undefined && last !== undefined && last !== current)
        return paginationRejected();
    if (next !== undefined && last !== undefined && last < next)
        return paginationRejected();
    return next ?? null;
}
async function boundedJson(response, limit) {
    const declared = response.headers.get("content-length");
    if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > limit))
        throw new Error("github response exceeds bound");
    const reader = response.body?.getReader();
    if (!reader)
        throw new Error("github response missing body");
    const chunks = [];
    let size = 0;
    try {
        for (;;) {
            const next = await reader.read();
            if (next.done)
                break;
            size += next.value.byteLength;
            if (size > limit) {
                await reader.cancel();
                throw new Error("github response exceeds bound");
            }
            chunks.push(next.value);
        }
    }
    finally {
        reader.releaseLock();
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.byteLength;
    }
    try {
        return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    }
    catch {
        throw new Error("github JSON rejected");
    }
}
export class GitHubAppPort {
    fetcher;
    authorization;
    identity;
    measure;
    constructor(fetcher, authorization, identity, measure = () => { }) {
        this.fetcher = fetcher;
        this.authorization = authorization;
        this.identity = identity;
        this.measure = measure;
    }
    async json(route, args, query = "", body, page) {
        if (route !== "installationToken" && args[0] !== this.identity.repositoryId)
            throw new DefinitiveNotSentError("github repository rejected");
        const base = githubRoute({ installationId: this.identity.installationId, repositoryId: this.identity.repositoryId }, route, args, query);
        const token = await this.authorization();
        if (!token || /[\r\n]/.test(token))
            throw new Error("github authorization unavailable");
        const headers = new Headers(base.headers);
        headers.set("Authorization", `Bearer ${token}`);
        if (body !== undefined)
            headers.set("Content-Type", "application/json");
        const outbound = new Request(base.url, { method: base.method, redirect: "manual", headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
        let response;
        try {
            response = await callFetch(this.fetcher, outbound);
        }
        catch (error) {
            if (!(error instanceof DefinitiveNotSentError))
                this.measure({ metric: "provider_error", value: 1 });
            throw error;
        }
        if (response.redirected || !response.ok || !/^application\/json(?:;|$)/i.test(response.headers.get("content-type") ?? "")) {
            this.measure({ metric: "provider_error", value: 1 });
            throw new Error("github route rejected");
        }
        const nextPage = page === undefined ? null : parsePagination(response.headers.get("link"), new URL(base.url), route, page);
        return { value: await boundedJson(response, MAX_RESPONSE_BYTES[route]), nextPage };
    }
    async getPullRequest(repositoryId, number) { return this.json("pullRequest", [repositoryId, number]).then(({ value }) => this.pr(value)); }
    async getMainRef(repositoryId) { const { value } = await this.json("mainRef", [repositoryId]); const v = value; return { repositoryId, ref: "refs/heads/main", sha: this.string(v.object && v.object.sha) }; }
    async listPullRequestFiles(repositoryId, number, page, perPage) { const { value, nextPage } = await this.json("pullFiles", [repositoryId, number], `page=${page}&per_page=${perPage}`, undefined, page); return { items: this.array(value).map((x) => ({ path: this.string(x.filename), status: this.string(x.status), ...(typeof x.previous_filename === "string" ? { previousPath: x.previous_filename } : {}) })), nextPage }; }
    async listOpenMainPullRequests(repositoryId, page, perPage) { const { value, nextPage } = await this.json("openMainPulls", [repositoryId], `state=open&base=main&sort=created&direction=asc&page=${page}&per_page=${perPage}`, undefined, page); return { items: this.array(value).map((x) => ({ ...this.pr(x), createdAt: this.string(x.created_at) })), nextPage }; }
    async listAppChecks(repositoryId, headSha, page, perPage) { const { value, nextPage } = await this.json("appChecks", [repositoryId, headSha], `page=${page}&per_page=${perPage}`, undefined, page); const v = value; const items = this.array(v.check_runs).map((x) => this.check(repositoryId, x)); const seen = new Set(); let duplicates = 0; for (const item of items) {
        const key = `${item.appId}:${item.checkId}:${item.externalId}`;
        if (seen.has(key))
            duplicates += 1;
        else
            seen.add(key);
    } if (duplicates > 0)
        this.measure({ metric: "duplicate_check", value: duplicates }); return { items, nextPage }; }
    async createCheck(input) { return this.json("createCheck", [input.repositoryId], "", { name: input.name, head_sha: input.headSha, external_id: input.externalId, status: "in_progress" }).then(({ value }) => this.check(input.repositoryId, value)); }
    async updateCheck(input) { await this.json("updateCheck", [input.repositoryId, input.checkId], "", { status: "completed", conclusion: input.conclusion, output: { title: "Release policy", summary: input.summary } }); }
    array(v) { if (!Array.isArray(v))
        throw new Error("github schema rejected"); return v.map((x) => { if (!x || typeof x !== "object" || Array.isArray(x))
        throw new Error("github schema rejected"); return x; }); }
    string(v) { if (typeof v !== "string" || v.length === 0)
        throw new Error("github schema rejected"); return v; }
    number(v) { if (typeof v !== "number" || !Number.isSafeInteger(v) || v <= 0)
        throw new Error("github schema rejected"); return v; }
    pr(v) {
        if (!v || typeof v !== "object" || Array.isArray(v))
            throw new Error("github schema rejected");
        const x = v;
        const base = x.base;
        const head = x.head;
        const baseRepo = base?.repo;
        const headRepo = head?.repo;
        const repositoryId = this.number(baseRepo?.id);
        const repositoryName = this.string(baseRepo?.full_name);
        const state = this.string(x.state);
        const baseRef = this.string(base?.ref);
        if (repositoryId !== this.identity.repositoryId || repositoryName !== this.identity.repositoryName || baseRef !== this.identity.baseRef || state !== "open")
            throw new Error("github PR identity rejected");
        return { appId: this.identity.appId, baseRef, baseSha: this.string(base?.sha), changedFiles: this.number(x.changed_files), headRepositoryId: this.number(headRepo?.id), headSha: this.string(head?.sha), installationId: this.identity.installationId, number: this.number(x.number), repositoryId, repositoryName, state };
    }
    check(repositoryId, v) { const x = v; return { appId: this.number(x.app?.id), checkId: this.number(x.id), externalId: this.string(x.external_id), headSha: this.string(x.head_sha), name: this.string(x.name), repositoryId }; }
}
function base64Url(bytes) {
    let binary = "";
    for (const byte of bytes)
        binary += String.fromCharCode(byte);
    return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}
function pemBytes(pem) {
    if (!/^-----BEGIN PRIVATE KEY-----\r?\n[\sA-Za-z0-9+/=]+\r?\n-----END PRIVATE KEY-----\s*$/.test(pem))
        throw new Error("github private key malformed");
    const binary = atob(pem.replace(/-----[^-]+-----|\s/g, ""));
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}
/** Builds an App JWT and installation token only in memory for the one fixed route. */
export function githubInstallationAuthorization(input) {
    return async () => {
        const now = Math.floor((input.now?.() ?? Date.now()) / 1000);
        const header = base64Url(new TextEncoder().encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
        const claims = base64Url(new TextEncoder().encode(JSON.stringify({ iat: now - 30, exp: now + 540, iss: input.appId })));
        const key = await globalThis.crypto.subtle.importKey("pkcs8", pemBytes(input.privateKeyPem), { hash: "SHA-256", name: "RSASSA-PKCS1-v1_5" }, false, ["sign"]);
        const signature = new Uint8Array(await globalThis.crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`)));
        const identity = { installationId: input.installationId, repositoryId: input.repositoryId };
        const request = githubRoute(identity, "installationToken", [input.installationId]);
        const headers = new Headers(request.headers);
        headers.set("Authorization", `Bearer ${header}.${claims}.${base64Url(signature)}`);
        headers.set("Content-Type", "application/json");
        const bodyText = JSON.stringify({ repository_ids: [input.repositoryId], permissions: { checks: "write", contents: "read", metadata: "read", pull_requests: "read" } });
        const outbound = new Request(request.url, { method: request.method, redirect: "manual", headers, body: bodyText });
        const response = await callFetch(input.fetcher, outbound);
        if (response.redirected || response.status !== 201 || !/^application\/json(?:;|$)/i.test(response.headers.get("content-type") ?? ""))
            throw new Error("github installation token rejected");
        const body = await boundedJson(response, MAX_RESPONSE_BYTES.installationToken);
        if (typeof body.token !== "string" || body.token.length < 1 || body.token.length > 512 || !/^[\x21-\x7e]+$/.test(body.token) || body.repository_selection !== "selected")
            throw new Error("github installation token malformed");
        const permissions = body.permissions;
        const requiredPermissions = { checks: "write", contents: "read", metadata: "read", pull_requests: "read" };
        if (!permissions || typeof permissions !== "object" || Array.isArray(permissions) || JSON.stringify(Object.entries(permissions).sort(([a], [b]) => a.localeCompare(b))) !== JSON.stringify(Object.entries(requiredPermissions).sort(([a], [b]) => a.localeCompare(b))))
            throw new Error("github installation scope rejected");
        const repositories = body.repositories;
        if (!Array.isArray(repositories) || repositories.length !== 1 || !repositories[0] || typeof repositories[0] !== "object")
            throw new Error("github installation scope rejected");
        const repository = repositories[0];
        if (repository.id !== input.repositoryId || repository.name !== "MyArtCollection" || repository.full_name !== "kenleren/MyArtCollection")
            throw new Error("github installation scope rejected");
        if (typeof body.expires_at !== "string" || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(body.expires_at))
            throw new Error("github installation expiry rejected");
        const expiry = Date.parse(body.expires_at);
        const nowMs = (input.now?.() ?? Date.now());
        if (!Number.isSafeInteger(expiry) || expiry < nowMs + 60_000 || expiry > nowMs + 65 * 60_000)
            throw new Error("github installation expiry rejected");
        return body.token;
    };
}
/** One alarm owns one transient authorization/session budget. Nothing from the
 * session is persisted or reused by a later event. */
export function classifyGitHubEgress(identity, request) {
    const url = new URL(request.url);
    if (/^\/repositories\/[1-9][0-9]*\/statuses\/[0-9a-f]{40}$/.test(url.pathname))
        return "status";
    return isExactGithubRequest(identity, request) ? "allowed" : "forbidden";
}
export function enforceGitHubEgress(identity, request, measure) {
    const classification = classifyGitHubEgress(identity, request);
    if (classification === "allowed")
        return;
    measure({ metric: classification === "status" ? "status_egress" : "forbidden_egress", value: 1 });
    throw new DefinitiveNotSentError("github egress route rejected");
}
export function githubAlarmPort(input) {
    let outboundCalls = 0;
    const budgetedFetch = async (request, init) => {
        const outbound = request instanceof Request ? request : new Request(request, init);
        const identity = { installationId: input.installationId, repositoryId: input.repositoryId };
        enforceGitHubEgress(identity, outbound, input.measure ?? (() => { }));
        if (input.reserveOutbound && !input.reserveOutbound()) {
            input.measure?.({ metric: "exceeded_resource", value: 1 });
            throw new DefinitiveNotSentError("github quota exhausted");
        }
        outboundCalls += 1;
        input.measure?.({ metric: "request_high_water", value: outboundCalls });
        if (outboundCalls > 50) {
            input.measure?.({ metric: "exceeded_resource", value: 1 });
            throw new DefinitiveNotSentError("github alarm subrequest budget exhausted");
        }
        return callFetch(input.fetcher, outbound, request instanceof Request ? init : undefined);
    };
    const issueAuthorization = githubInstallationAuthorization({ ...input, fetcher: budgetedFetch });
    let authorization;
    return new GitHubAppPort(budgetedFetch, () => authorization ??= issueAuthorization(), { appId: input.appId, baseRef: "main", installationId: input.installationId, repositoryId: input.repositoryId, repositoryName: input.repositoryName }, input.measure);
}
