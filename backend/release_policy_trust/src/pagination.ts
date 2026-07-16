import { canonicalHash } from "./canonical.js";
import { fail } from "./errors.js";
import type { AppCheck, ExpectedIdentity, GitHubCheckRunsPort, OpenMainPullRequest, Page } from "./ports.js";
import type { ChangedFile } from "./paths.js";

async function collect<T>(fetch: (page: number) => Promise<Page<T>>, maxPages: number, maxRows: number): Promise<T[]> {
  const rows: T[] = [];
  for (let page = 1; page <= maxPages; page += 1) {
    const result = await fetch(page);
    if (!Number.isInteger(result.nextPage) && result.nextPage !== null) fail("invalid_input", "invalid pagination cursor");
    if (result.nextPage !== null && result.nextPage !== page + 1) fail("invalid_input", "pagination cursor must be exact next page");
    if (result.nextPage !== null && result.items.length !== 100) fail("invalid_input", "nonfinal page must contain 100 rows");
    if (result.items.length > 100) fail("overflow", "page exceeds 100 rows");
    rows.push(...result.items);
    if (rows.length > maxRows) fail("overflow", "pagination row ceiling exceeded");
    if (result.nextPage === null) return rows;
    if (page === maxPages) fail("overflow", "pagination page ceiling exceeded");
  }
  return fail("overflow", "pagination did not terminate");
}

export async function collectPullRequestFiles(port: GitHubCheckRunsPort, repositoryId: number, number: number, expectedCount: number): Promise<ChangedFile[]> {
  if (!Number.isInteger(expectedCount) || expectedCount < 0 || expectedCount > 3000) fail("overflow", "invalid changed-file count");
  const rows = await collect((page) => port.listPullRequestFiles(repositoryId, number, page, 100), 30, 3000);
  if (rows.length !== expectedCount) fail("snapshot_race", "changed-file count raced pagination");
  return rows;
}

function validateOpenPr(row: OpenMainPullRequest, identity: ExpectedIdentity): void {
  for (const value of [row.number, row.repositoryId, row.installationId, row.appId, row.headRepositoryId]) {
    if (!Number.isSafeInteger(value) || value <= 0) fail("identity", "invalid numeric PR identity");
  }
  if (row.repositoryId !== identity.repositoryId || row.installationId !== identity.installationId || row.appId !== identity.appId || row.repositoryName !== identity.repositoryName || row.baseRef !== "main" || row.state !== "open") fail("identity", "open PR identity mismatch");
  if (!/^[0-9a-f]{40}$/.test(row.baseSha) || !/^[0-9a-f]{40}$/.test(row.headSha) || row.headRepositoryId !== identity.repositoryId) fail("identity", "fork or inaccessible PR head");
}

export async function enumerateOpenMainPullRequests(port: GitHubCheckRunsPort, identity: ExpectedIdentity): Promise<{ count: number; digest: string; rows: OpenMainPullRequest[] }> {
  const pass = async (): Promise<OpenMainPullRequest[]> => {
    const rows = await collect((page) => port.listOpenMainPullRequests(identity.repositoryId, page, 100), 10, 1000);
    const seen = new Set<number>();
    let priorCreated = -1;
    for (const row of rows) {
      validateOpenPr(row, identity);
      if (seen.has(row.number)) fail("invalid_input", "duplicate open PR number");
      seen.add(row.number);
      const created = Date.parse(row.createdAt);
      if (!Number.isFinite(created) || created < priorCreated) fail("invalid_input", "open PR page is not created-ascending");
      priorCreated = created;
    }
    return rows.sort((a, b) => a.number - b.number);
  };
  const first = await pass();
  const second = await pass();
  const firstDigest = canonicalHash(first);
  if (firstDigest !== canonicalHash(second)) fail("snapshot_race", "open PR enumeration changed between passes");
  return { count: first.length, digest: firstDigest, rows: first };
}

export async function enumerateMatchingChecks(port: GitHubCheckRunsPort, identity: ExpectedIdentity, headSha: string, name: string, externalId: string): Promise<AppCheck[]> {
  const rows = await collect((page) => port.listAppChecks(identity.repositoryId, headSha, page, 100), 30, 3000);
  const ids = new Set<number>();
  return rows.filter((row) => {
    if (!Number.isSafeInteger(row.checkId) || row.checkId <= 0 || ids.has(row.checkId)) fail("invalid_input", "invalid or duplicate check id");
    ids.add(row.checkId);
    return row.appId === identity.appId && row.repositoryId === identity.repositoryId && row.headSha === headSha && row.name === name && row.externalId === externalId;
  });
}
