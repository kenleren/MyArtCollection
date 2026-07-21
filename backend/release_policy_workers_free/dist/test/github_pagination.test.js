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
