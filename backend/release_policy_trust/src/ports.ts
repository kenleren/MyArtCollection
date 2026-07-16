import type { ChangedFile } from "./paths.js";

export interface ExpectedIdentity {
  appId: number;
  installationId: number;
  repositoryId: number;
  repositoryName: string;
  baseRef: "main";
}
export interface PullRequestSnapshot {
  appId: number;
  baseRef: string;
  baseSha: string;
  changedFiles: number;
  headRepositoryId: number;
  headSha: string;
  installationId: number;
  number: number;
  repositoryId: number;
  repositoryName: string;
  state: "open";
}
export interface MainRefSnapshot { repositoryId: number; ref: "refs/heads/main"; sha: string }
export interface Page<T> { items: readonly T[]; nextPage: number | null }
export interface OpenMainPullRequest extends PullRequestSnapshot { createdAt: string }
export interface AppCheck {
  appId: number;
  checkId: number;
  externalId: string;
  headSha: string;
  name: string;
  repositoryId: number;
}
export interface CreateCheckInput { externalId: string; headSha: string; name: string; repositoryId: number }
export interface UpdateCheckInput { checkId: number; conclusion: "success" | "failure"; repositoryId: number; summary: string }

// This is deliberately the complete production API capability surface. There
// is no generic request, GraphQL, token, commit-status, neutral, or skipped API.
export interface GitHubCheckRunsPort {
  getPullRequest(repositoryId: number, number: number): Promise<PullRequestSnapshot>;
  getMainRef(repositoryId: number): Promise<MainRefSnapshot>;
  listPullRequestFiles(repositoryId: number, number: number, page: number, perPage: 100): Promise<Page<ChangedFile>>;
  listOpenMainPullRequests(repositoryId: number, page: number, perPage: 100): Promise<Page<OpenMainPullRequest>>;
  listAppChecks(repositoryId: number, headSha: string, page: number, perPage: 100): Promise<Page<AppCheck>>;
  createCheck(input: CreateCheckInput): Promise<AppCheck>;
  updateCheck(input: UpdateCheckInput): Promise<void>;
}

export interface DurableTransaction {
  get(key: string): unknown;
  putIfAbsent(key: string, value: unknown): void;
  compareAndSwap(key: string, expectedVersion: number, value: unknown): void;
}
export interface DurableStorePort {
  transact<T>(work: (transaction: DurableTransaction) => T): Promise<T>;
  read(key: string): Promise<unknown>;
}
