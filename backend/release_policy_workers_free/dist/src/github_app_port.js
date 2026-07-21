import { githubRoute } from "./github_routes.js";
const MAX_RESPONSE_BYTES = { installationToken: 16_384, pullRequest: 131_072, mainRef: 16_384, pullFiles: 1_048_576, openMainPulls: 1_048_576, appChecks: 1_048_576, createCheck: 131_072, updateCheck: 131_072 };
const PAGE_CEILING = { pullFiles: 30, openMainPulls: 10, appChecks: 30 };
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
    if (bytes.length === 0 || bytes.length > 8192 || !/^[\x20\x09-\x7e]+$/.test(link))
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
    constructor(fetcher, authorization) {
        this.fetcher = fetcher;
        this.authorization = authorization;
    }
    async json(route, args, query = "", body, page) {
        const base = githubRoute(route, args, query);
        const token = await this.authorization();
        if (!token || /[\r\n]/.test(token))
            throw new Error("github authorization unavailable");
        const init = body === undefined ? { headers: { ...Object.fromEntries(base.headers), Authorization: `Bearer ${token}` } } : { headers: { ...Object.fromEntries(base.headers), Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify(body) };
        const response = await this.fetcher(new Request(base, init));
        if (response.redirected || !response.ok || !/^application\/json(?:;|$)/i.test(response.headers.get("content-type") ?? ""))
            throw new Error("github route rejected");
        const nextPage = page === undefined ? null : parsePagination(response.headers.get("link"), new URL(base.url), route, page);
        return { value: await boundedJson(response, MAX_RESPONSE_BYTES[route]), nextPage };
    }
    async getPullRequest(repositoryId, number) { return this.json("pullRequest", [repositoryId, number]).then(({ value }) => this.pr(value)); }
    async getMainRef(repositoryId) { const { value } = await this.json("mainRef", [repositoryId]); const v = value; return { repositoryId, ref: "refs/heads/main", sha: this.string(v.object && v.object.sha) }; }
    async listPullRequestFiles(repositoryId, number, page, perPage) { const { value, nextPage } = await this.json("pullFiles", [repositoryId, number], `page=${page}&per_page=${perPage}`, undefined, page); return { items: this.array(value).map((x) => ({ path: this.string(x.filename), status: this.string(x.status), ...(typeof x.previous_filename === "string" ? { previousPath: x.previous_filename } : {}) })), nextPage }; }
    async listOpenMainPullRequests(repositoryId, page, perPage) { const { value, nextPage } = await this.json("openMainPulls", [repositoryId], `state=open&base=main&page=${page}&per_page=${perPage}`, undefined, page); return { items: this.array(value).map((x) => ({ ...this.pr(x), createdAt: this.string(x.created_at) })), nextPage }; }
    async listAppChecks(repositoryId, headSha, page, perPage) { const { value, nextPage } = await this.json("appChecks", [repositoryId, headSha], `page=${page}&per_page=${perPage}`, undefined, page); const v = value; return { items: this.array(v.check_runs).map((x) => this.check(repositoryId, x)), nextPage }; }
    async createCheck(input) { return this.json("createCheck", [input.repositoryId], "", { name: input.name, head_sha: input.headSha, external_id: input.externalId, status: "in_progress" }).then(({ value }) => this.check(input.repositoryId, value)); }
    async updateCheck(input) { await this.json("updateCheck", [input.repositoryId, input.checkId], "", { status: "completed", conclusion: input.conclusion, output: { title: "Release policy", summary: input.summary } }); }
    array(v) { if (!Array.isArray(v))
        throw new Error("github schema rejected"); return v.map((x) => { if (!x || typeof x !== "object" || Array.isArray(x))
        throw new Error("github schema rejected"); return x; }); }
    string(v) { if (typeof v !== "string" || v.length === 0)
        throw new Error("github schema rejected"); return v; }
    number(v) { if (typeof v !== "number" || !Number.isSafeInteger(v) || v <= 0)
        throw new Error("github schema rejected"); return v; }
    pr(v) { const x = v; const base = x.base; const head = x.head; const repo = x.base_repo; return { appId: this.number(x.app?.id), baseRef: this.string(base?.ref), baseSha: this.string(base?.sha), changedFiles: this.number(x.changed_files), headRepositoryId: this.number(head?.repo?.id), headSha: this.string(head?.sha), installationId: this.number(x.installation?.id), number: this.number(x.number), repositoryId: this.number(repo?.id), repositoryName: this.string(repo?.full_name), state: "open" }; }
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
        const key = await crypto.subtle.importKey("pkcs8", pemBytes(input.privateKeyPem), { hash: "SHA-256", name: "RSASSA-PKCS1-v1_5" }, false, ["sign"]);
        const signature = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`)));
        const request = githubRoute("installationToken", [input.installationId]);
        const response = await input.fetcher(new Request(request, { headers: { ...Object.fromEntries(request.headers), Authorization: `Bearer ${header}.${claims}.${base64Url(signature)}` } }));
        if (response.redirected || !response.ok || !/^application\/json(?:;|$)/i.test(response.headers.get("content-type") ?? ""))
            throw new Error("github installation token rejected");
        const body = await boundedJson(response, MAX_RESPONSE_BYTES.installationToken);
        if (typeof body.token !== "string" || body.token.length === 0 || /[\r\n]/.test(body.token))
            throw new Error("github installation token malformed");
        return body.token;
    };
}
