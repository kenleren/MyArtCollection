import test from "node:test";
import assert from "node:assert/strict";
import { GitHubAppPort } from "../src/github_app_port.js";
const repositoryId = 1288597824;
const pullPath = `/repositories/${repositoryId}/pulls/1/files`;
const files = Array.from({ length: 100 }, (_, index) => ({ filename: `file-${index}.md`, status: "modified" }));
const pageUrl = (page) => `https://api.github.com${pullPath}?per_page=100&page=${page}`;
const portFor = (response) => new GitHubAppPort(async () => response, async () => "synthetic");
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
    const openLink = `<https://api.github.com/repositories/${repositoryId}/pulls?per_page=100&page=2&base=main&state=open>; rel="next"`;
    const open = await portFor(new Response("[]", { headers: { "content-type": "application/json", link: openLink } })).listOpenMainPullRequests(repositoryId, 1, 100);
    assert.equal(open.nextPage, 2);
    const checksLink = `<https://api.github.com/repositories/${repositoryId}/commits/${"b".repeat(40)}/check-runs?per_page=100&page=2>; rel="next"`;
    const checks = await portFor(new Response('{"check_runs":[]}', { headers: { "content-type": "application/json", link: checksLink } })).listAppChecks(repositoryId, "b".repeat(40), 1, 100);
    assert.equal(checks.nextPage, 2);
});
