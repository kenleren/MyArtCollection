import assert from "node:assert/strict";
import test from "node:test";
import { collectPullRequestFiles, enumerateMatchingChecks, enumerateOpenMainPullRequests } from "../src/pagination.js";
import { changed, FakePort, identity, openPr, pages, SHA_B } from "./helpers.js";

test("file pagination accepts exact bounds and rejects 3,001", async () => {
  for (const count of [0, 1, 99, 100, 101, 2999, 3000]) {
    const port = new FakePort(); const rows = Array.from({ length: count }, (_, index) => changed(index)); port.filePages = pages(rows);
    assert.equal((await collectPullRequestFiles(port, 33, 7, count)).length, count);
  }
  const overflow = new FakePort(); overflow.filePages = pages(Array.from({ length: 3001 }, (_, index) => changed(index)));
  await assert.rejects(collectPullRequestFiles(overflow, 33, 7, 3001), /invalid changed-file count/);
});

test("pagination fails on count/link/page shape races", async () => {
  const short = new FakePort(); short.filePages.set(1, { items: [changed(1)], nextPage: 2 });
  await assert.rejects(collectPullRequestFiles(short, 33, 7, 1), /nonfinal page/);
  const skipped = new FakePort(); skipped.filePages.set(1, { items: Array.from({ length: 100 }, (_, i) => changed(i)), nextPage: 3 });
  await assert.rejects(collectPullRequestFiles(skipped, 33, 7, 100), /exact next page/);
  const race = new FakePort(); race.filePages = pages([changed(1)]);
  await assert.rejects(collectPullRequestFiles(race, 33, 7, 2), /raced/);
});

test("open-main PR two-pass bounds and identity checks", async () => {
  for (const count of [0, 99, 100, 101, 999, 1000]) {
    const port = new FakePort(); port.openPages = pages(Array.from({ length: count }, (_, index) => openPr(index + 1)));
    assert.equal((await enumerateOpenMainPullRequests(port, identity)).count, count);
  }
  const overflow = new FakePort(); overflow.openPages = pages(Array.from({ length: 1001 }, (_, index) => openPr(index + 1)));
  await assert.rejects(enumerateOpenMainPullRequests(overflow, identity), /page ceiling|row ceiling/);
  const duplicate = new FakePort(); duplicate.openPages = pages([openPr(1), openPr(1)]);
  await assert.rejects(enumerateOpenMainPullRequests(duplicate, identity), /duplicate/);
  const fork = new FakePort(); const row = openPr(1); row.headRepositoryId = 44; fork.openPages = pages([row]);
  await assert.rejects(enumerateOpenMainPullRequests(fork, identity), /fork/);
});

test("check enumeration excludes same-name Actions checks and rejects duplicates", async () => {
  const port = new FakePort();
  port.checkPages = pages([
    { appId: 99, checkId: 1, externalId: "g", headSha: SHA_B, name: "trusted", repositoryId: 33 },
    { appId: 11, checkId: 2, externalId: "g", headSha: SHA_B, name: "trusted", repositoryId: 33 },
  ]);
  assert.deepEqual((await enumerateMatchingChecks(port, identity, SHA_B, "trusted", "g")).map((row) => row.checkId), [2]);
  port.checkPages = pages([{ appId: 11, checkId: 2, externalId: "g", headSha: SHA_B, name: "trusted", repositoryId: 33 }, { appId: 11, checkId: 2, externalId: "g", headSha: SHA_B, name: "trusted", repositoryId: 33 }]);
  await assert.rejects(enumerateMatchingChecks(port, identity, SHA_B, "trusted", "g"), /duplicate/);
});

test("check pagination accepts 3,000 and rejects cursor beyond page 30", async () => {
  const rows = Array.from({ length: 3000 }, (_, index) => ({ appId: 11, checkId: index + 1, externalId: "other", headSha: SHA_B, name: "trusted", repositoryId: 33 }));
  const exact = new FakePort(); exact.checkPages = pages(rows);
  assert.equal((await enumerateMatchingChecks(exact, identity, SHA_B, "trusted", "generation")).length, 0);
  const overflow = new FakePort(); overflow.checkPages = pages([...rows, { ...rows[0]!, checkId: 3001 }]);
  await assert.rejects(enumerateMatchingChecks(overflow, identity, SHA_B, "trusted", "generation"), /page ceiling|row ceiling/);
});

test("open-main enumeration rejects pass drift, order, wrong state, and inaccessible head", async () => {
  const drift = new FakePort(); let calls = 0;
  drift.listOpenMainPullRequests = async () => ({ items: calls++ === 0 ? [openPr(1)] : [openPr(2)], nextPage: null });
  await assert.rejects(enumerateOpenMainPullRequests(drift, identity), /changed between passes/);
  const order = new FakePort(); order.openPages = pages([openPr(2), openPr(1)]);
  await assert.rejects(enumerateOpenMainPullRequests(order, identity), /created-ascending/);
  const state = new FakePort(); const closed = { ...openPr(1), state: "closed" as unknown as "open" };
  state.openPages = pages([closed]);
  await assert.rejects(enumerateOpenMainPullRequests(state, identity), /identity mismatch/);
  const inaccessible = new FakePort(); const bad = openPr(1); bad.headSha = "missing"; inaccessible.openPages = pages([bad]);
  await assert.rejects(enumerateOpenMainPullRequests(inaccessible, identity), /inaccessible/);
});
