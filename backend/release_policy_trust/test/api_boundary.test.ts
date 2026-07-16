import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";

test("production GitHub port exposes only the seven allowlisted typed operations", () => {
  const source = readFileSync(resolve(process.cwd(), "src/ports.ts"), "utf8");
  const block = /export interface GitHubCheckRunsPort \{([\s\S]*?)\n\}/.exec(source)?.[1];
  assert.ok(block);
  const methods = [...block.matchAll(/^\s{2}([A-Za-z][A-Za-z0-9]*)\(/gm)].map((match) => match[1]);
  assert.deepEqual(methods, ["getPullRequest", "getMainRef", "listPullRequestFiles", "listOpenMainPullRequests", "listAppChecks", "createCheck", "updateCheck"]);
  for (const forbidden of ["request", "graphql", "createStatus", "token"]) assert.equal(methods.includes(forbidden), false);
  assert.equal(/conclusion:\s*"neutral"|conclusion:\s*"skipped"/.test(source), false);
});
