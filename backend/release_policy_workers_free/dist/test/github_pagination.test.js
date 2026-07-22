import test from "node:test";
import assert from "node:assert/strict";
import { GitHubAppPort } from "../src/github_app_port.js";
const repositoryId = 1288597824;
const identity = { appId: 1, baseRef: "main", installationId: 2, repositoryId, repositoryName: "kenleren/MyArtCollection" };
const pullPath = `/repositories/${repositoryId}/pulls/1/files`;
const openMainPath = `/repositories/${repositoryId}/pulls`;
const files = Array.from({ length: 100 }, (_, index) => ({ filename: `file-${index}.md`, status: "modified" }));
const pageUrl = (page) => `https://api.github.com${pullPath}?per_page=100&page=${page}`;
const portFor = (response) => new GitHubAppPort(async () => response, async () => "synthetic", identity);
const pull = (overrides = {}) => ({
    number: 1, state: "open", changed_files: 1, created_at: "2026-07-21T00:00:00Z",
    base: { ref: "main", sha: "a".repeat(40), repo: { id: repositoryId, full_name: "kenleren/MyArtCollection" } },
    head: { sha: "b".repeat(40), repo: { id: repositoryId, full_name: "kenleren/MyArtCollection" } },
    ...overrides,
});
test("official pull-request response shape uses frozen App identity and nested base.repo", async () => {
    const port = portFor(new Response(JSON.stringify(pull()), { headers: { "content-type": "application/json" } }));
    assert.deepEqual(await port.getPullRequest(repositoryId, 1), {
        appId: 1, baseRef: "main", baseSha: "a".repeat(40), changedFiles: 1,
        headRepositoryId: repositoryId, headSha: "b".repeat(40), installationId: 2,
        number: 1, repositoryId, repositoryName: "kenleren/MyArtCollection", state: "open",
    });
});
test("official open-main response shape parses without fictional top-level identity fields", async () => {
    const page = await portFor(new Response(JSON.stringify([pull()]), { headers: { "content-type": "application/json" } })).listOpenMainPullRequests(repositoryId, 1, 100);
    assert.equal(page.items[0]?.createdAt, "2026-07-21T00:00:00Z");
    assert.equal(page.items[0]?.appId, identity.appId);
    assert.equal(page.items[0]?.repositoryId, repositoryId);
});
test("open-main fanout freezes documented ascending creation order", async () => {
    const requests = [];
    const port = new GitHubAppPort(async (request) => { requests.push(new Request(request).url); return new Response(JSON.stringify([pull({ number: 1, created_at: "2026-07-21T00:00:00Z" }), pull({ number: 2, created_at: "2026-07-22T00:00:00Z" })]), { headers: { "content-type": "application/json" } }); }, async () => "synthetic", identity);
    const page = await port.listOpenMainPullRequests(repositoryId, 1, 100);
    assert.deepEqual(page.items.map((item) => item.createdAt), ["2026-07-21T00:00:00Z", "2026-07-22T00:00:00Z"]);
    assert.equal(requests[0], `https://api.github.com${openMainPath}?state=open&base=main&sort=created&direction=asc&page=1&per_page=100`);
});
test("pull-request response fails closed without the official nested base repository identity", async () => {
    const fictional = { ...pull(), app: { id: 1 }, installation: { id: 2 }, base_repo: { id: repositoryId, full_name: identity.repositoryName }, base: { ref: "main", sha: "a".repeat(40) } };
    await assert.rejects(() => portFor(new Response(JSON.stringify(fictional), { headers: { "content-type": "application/json" } })).getPullRequest(repositoryId, 1), /github schema rejected/);
    await assert.rejects(() => portFor(new Response(JSON.stringify(pull({ base: { ref: "main", sha: "a".repeat(40), repo: { id: repositoryId + 1, full_name: identity.repositoryName } } })), { headers: { "content-type": "application/json" } })).getPullRequest(repositoryId, 1), /identity rejected/);
    await assert.rejects(() => portFor(new Response(JSON.stringify([{ ...pull(), base: { ref: "main", sha: "a".repeat(40) } }]), { headers: { "content-type": "application/json" } })).listOpenMainPullRequests(repositoryId, 1, 100), /github schema rejected/);
});
test("Link absence terminates even a full final page", async () => {
    const page = await portFor(new Response(JSON.stringify(files), { headers: { "content-type": "application/json" } })).listPullRequestFiles(repositoryId, 1, 1, 100);
    assert.equal(page.items.length, 100);
    assert.equal(page.nextPage, null);
});
test("strict Link relations normalize reordered query keys", async () => {
    const link = `<${pageUrl(2)}>; rel="next", <https://api.github.com${pullPath}?page=30&per_page=100>; rel="last", <https://api.github.com${pullPath}?per_page=100&page=1>; rel="first"`;
    const page = await portFor(new Response(JSON.stringify(files), { headers: { "content-type": "application/json", link } })).listPullRequestFiles(repositoryId, 1, 1, 100);
    assert.equal(page.nextPage, 2);
});
test("pagination rejects page 31 before response body consumption", async () => {
    let reads = 0;
    const link = `<${pageUrl(31)}>; rel="next", <https://api.github.com${pullPath}?page=31&per_page=100>; rel="last"`;
    const response = { redirected: false, ok: true, headers: new Headers({ "content-type": "application/json", link }), get body() { reads++; return new ReadableStream(); } };
    await assert.rejects(() => portFor(response).listPullRequestFiles(repositoryId, 1, 30, 100), /github pagination rejected/);
    assert.equal(reads, 0);
});
test("cross-relation contradictions reject", async () => {
    const link = `<${pageUrl(2)}>; rel="next", <https://api.github.com${pullPath}?page=1&per_page=100>; rel="last"`;
    await assert.rejects(() => portFor(new Response(JSON.stringify(files), { headers: { "content-type": "application/json", link } })).listPullRequestFiles(repositoryId, 1, 1, 100), /github pagination rejected/);
});
test("strict relation state machine accepts normalized beginning, middle, penultimate, and final pages", async () => {
    const cases = [
        { page: 1, link: `<${pageUrl(1)}>; rel="first", <${pageUrl(1)}>; rel="last"`, next: null },
        { page: 2, link: `<${pageUrl(1)}>; rel="first", <${pageUrl(1)}>; rel="prev", <${pageUrl(2)}>; rel="last"`, next: null },
        { page: 2, link: `<${pageUrl(1)}>; rel="prev", <${pageUrl(1)}>; rel="first"`, next: null },
        { page: 1, link: `<${pageUrl(30)}>; rel="last", <${pageUrl(2)}>; rel="next", <${pageUrl(1)}>; rel="first"`, next: 2 },
        { page: 29, link: `<${pageUrl(28)}>; rel="prev", <${pageUrl(30)}>; rel="next", <${pageUrl(30)}>; rel="last", <${pageUrl(1)}>; rel="first"`, next: 30 },
        { page: 29, link: `<${pageUrl(30)}>; rel="next", <${pageUrl(28)}>; rel="prev"`, next: 30 },
        { page: 30, link: `<${pageUrl(30)}>; rel="last", <${pageUrl(29)}>; rel="prev", <${pageUrl(1)}>; rel="first"`, next: null },
        { page: 30, link: `<${pageUrl(29)}>; rel="prev", <${pageUrl(1)}>; rel="first"`, next: null },
    ];
    for (const fixture of cases) {
        const page = await portFor(new Response(JSON.stringify(files), { headers: { "content-type": "application/json", link: fixture.link } })).listPullRequestFiles(repositoryId, 1, fixture.page, 100);
        assert.equal(page.nextPage, fixture.next);
    }
});
test("every malformed or contradictory Link rejects before body consumption", async () => {
    const changedPath = `/repositories/${repositoryId}/pulls/2/files`;
    const cases = [
        "x".repeat(8193),
        [1, 2, 3, 4, 5].map((page) => `<${pageUrl(page)}>; rel="${page === 1 ? "first" : "last"}"`).join(","),
        `<https://api.github.com/${"x".repeat(2050)}>; rel="next"`,
        `<${pageUrl(2)}>; rel="next"\u0080`,
        `${pageUrl(2)}; rel="next"`, `<${pageUrl(2)}; rel="next"`, `<${pageUrl(2)}> rel="next"`,
        `<${pageUrl(2)}>; rel=next`, `<${pageUrl(2)}>; rel="NEXT"`, `<${pageUrl(2)}>; rel="next last"`, `<${pageUrl(2)}>; rel="next"; type="x"`,
        `<../files?page=2&per_page=100>; rel="next"`,
        `<http://api.github.com${pullPath}?per_page=100&page=2>; rel="next"`,
        `<https://api.github.com:444${pullPath}?per_page=100&page=2>; rel="next"`,
        `<https://api.github.example${pullPath}?per_page=100&page=2>; rel="next"`,
        `<https://user@api.github.com${pullPath}?per_page=100&page=2>; rel="next"`,
        `<https://api.github.com${pullPath}?per_page=100&page=2#fragment>; rel="next"`,
        `<https://api.github.com${changedPath}?per_page=100&page=2>; rel="next"`,
        `<https://api.github.com/repositories/${repositoryId}/pulls?state=open&base=main&page=2&per_page=100>; rel="next"`,
        `<https://api.github.com${pullPath}?page=2>; rel="next"`,
        `<https://api.github.com${pullPath}?page=2&per_page=100&extra=x>; rel="next"`,
        `<https://api.github.com${pullPath}?page=2&page=2&per_page=100>; rel="next"`,
        `<https://api.github.com${pullPath}?page=2&per_page=99>; rel="next"`,
        ...["0", "-1", "01", "1.0", "1e1", "9007199254740992", "%32"].map((page) => `<https://api.github.com${pullPath}?per_page=100&page=${page}>; rel="next"`),
        `<${pageUrl(1)}>; rel="prev"`, `<${pageUrl(3)}>; rel="next"`,
        `<${pageUrl(2)}>; rel="next", <${pageUrl(2)}>; rel="next"`,
        `<${pageUrl(1)}>; rel="first", <${pageUrl(1)}>; rel="first"`,
        `<${pageUrl(2)}>; rel="next", <${pageUrl(1)}>; rel="last"`,
        `<${pageUrl(30)}>; rel="last"`,
    ];
    for (const [index, link] of cases.entries()) {
        let bodyReads = 0;
        const response = { redirected: false, ok: true, headers: new Headers({ "content-type": "application/json", link }), get body() { bodyReads += 1; return new ReadableStream({ start(controller) { controller.enqueue(new TextEncoder().encode("[]")); controller.close(); } }); } };
        await assert.rejects(() => portFor(response).listPullRequestFiles(repositoryId, 1, 1, 100), /github pagination rejected/, `negative ${index}`);
        assert.equal(bodyReads, 0, `negative ${index} read body`);
    }
});
test("open-main and app-check pagination use their exact fixed routes", async () => {
    const openLink = `<https://api.github.com/repositories/${repositoryId}/pulls?per_page=100&page=2&direction=asc&base=main&sort=created&state=open>; rel="next"`;
    const open = await portFor(new Response("[]", { headers: { "content-type": "application/json", link: openLink } })).listOpenMainPullRequests(repositoryId, 1, 100);
    assert.equal(open.nextPage, 2);
    const checksLink = `<https://api.github.com/repositories/${repositoryId}/commits/${"b".repeat(40)}/check-runs?per_page=100&page=2>; rel="next"`;
    const checks = await portFor(new Response('{"check_runs":[]}', { headers: { "content-type": "application/json", link: checksLink } })).listAppChecks(repositoryId, "b".repeat(40), 1, 100);
    assert.equal(checks.nextPage, 2);
});
