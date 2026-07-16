import type { AppCheck, CreateCheckInput, GitHubCheckRunsPort, MainRefSnapshot, OpenMainPullRequest, Page, PullRequestSnapshot, UpdateCheckInput } from "../src/ports.js";
import type { ChangedFile } from "../src/paths.js";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { loadCanonicalPolicy } from "../src/policy.js";

export const SHA_A = "a".repeat(40);
export const SHA_B = "b".repeat(40);
export const identity = { appId: 11, baseRef: "main" as const, installationId: 22, repositoryId: 33, repositoryName: "kenleren/MyArtCollection" };
export function policy() { return loadCanonicalPolicy(readFileSync(resolve(process.cwd(), "policy/release-policy.v1.json"))); }

export function pr(number = 7): PullRequestSnapshot {
  return { appId: 11, baseRef: "main", baseSha: SHA_A, changedFiles: 0, headRepositoryId: 33, headSha: SHA_B, installationId: 22, number, repositoryId: 33, repositoryName: "kenleren/MyArtCollection", state: "open" };
}

export function pages<T>(rows: readonly T[]): Map<number, Page<T>> {
  const output = new Map<number, Page<T>>();
  if (rows.length === 0) { output.set(1, { items: [], nextPage: null }); return output; }
  for (let offset = 0; offset < rows.length; offset += 100) {
    const page = offset / 100 + 1;
    const items = rows.slice(offset, offset + 100);
    output.set(page, { items, nextPage: offset + 100 < rows.length ? page + 1 : null });
  }
  return output;
}

export class FakePort implements GitHubCheckRunsPort {
  pull = pr();
  main: MainRefSnapshot = { ref: "refs/heads/main", repositoryId: 33, sha: SHA_A };
  filePages = pages<ChangedFile>([]);
  openPages = pages<OpenMainPullRequest>([]);
  checkPages = pages<AppCheck>([]);
  createBehavior: "success" | "ambiguous" | "definite" | "failure" = "success";
  updateBehavior: "success" | "ambiguous" | "failure" = "success";
  onCreate?: (input: CreateCheckInput) => void | Promise<void>;
  onUpdate?: (input: UpdateCheckInput) => void | Promise<void>;
  updates: UpdateCheckInput[] = [];
  created: CreateCheckInput[] = [];

  async getPullRequest(): Promise<PullRequestSnapshot> { return structuredClone(this.pull); }
  async getMainRef(): Promise<MainRefSnapshot> { return structuredClone(this.main); }
  async listPullRequestFiles(_repositoryId: number, _number: number, page: number): Promise<Page<ChangedFile>> { return structuredClone(this.filePages.get(page) ?? { items: [], nextPage: null }); }
  async listOpenMainPullRequests(_repositoryId: number, page: number): Promise<Page<OpenMainPullRequest>> { return structuredClone(this.openPages.get(page) ?? { items: [], nextPage: null }); }
  async listAppChecks(_repositoryId: number, _headSha: string, page: number): Promise<Page<AppCheck>> { return structuredClone(this.checkPages.get(page) ?? { items: [], nextPage: null }); }
  async createCheck(input: CreateCheckInput): Promise<AppCheck> {
    this.created.push(input);
    await this.onCreate?.(input);
    if (this.createBehavior === "ambiguous") { const { AmbiguousCreateError } = await import("../src/checks.js"); throw new AmbiguousCreateError(); }
    if (this.createBehavior === "definite") { const { DefinitiveNotSentError } = await import("../src/checks.js"); throw new DefinitiveNotSentError(); }
    if (this.createBehavior === "failure") throw new Error("API failure");
    return { appId: 11, checkId: 44, externalId: input.externalId, headSha: input.headSha, name: input.name, repositoryId: input.repositoryId };
  }
  async updateCheck(input: UpdateCheckInput): Promise<void> {
    this.updates.push(input);
    await this.onUpdate?.(input);
    if (this.updateBehavior === "ambiguous") { const { AmbiguousUpdateError } = await import("../src/checks.js"); throw new AmbiguousUpdateError(); }
    if (this.updateBehavior === "failure") throw new Error("API failure");
  }
}

export function changed(index: number, status: ChangedFile["status"] = "modified"): ChangedFile { return { path: `lib/file-${String(index).padStart(4, "0")}.dart`, status }; }
export function openPr(number: number): OpenMainPullRequest { return { ...pr(number), createdAt: new Date(number * 1000).toISOString() }; }
