import { GITHUB_API_VERSION, githubApiOrigin, REPOSITORY_ID } from "./config.js";
export type Route = "installationToken" | "pullRequest" | "mainRef" | "pullFiles" | "openMainPulls" | "appChecks" | "createCheck" | "updateCheck";
export interface FrozenEgressIdentity { readonly installationId: number; readonly repositoryId: typeof REPOSITORY_ID }
const positive = (value: string | number): boolean => typeof value === "number" ? Number.isSafeInteger(value) && value > 0 : /^[0-9a-f]{40}$/.test(value);
function requireIdentity(identity: FrozenEgressIdentity, route: Route, args: readonly (string | number)[]): void {
  if (!Number.isSafeInteger(identity.installationId) || identity.installationId <= 0 || identity.repositoryId !== REPOSITORY_ID || args.some((arg) => !positive(arg))) throw new Error("github route rejected");
  if (route === "installationToken") { if (args.length !== 1 || args[0] !== identity.installationId) throw new Error("github route rejected"); return; }
  if (args[0] !== identity.repositoryId) throw new Error("github route rejected");
}
const routes: Record<Route, { method: "GET" | "POST" | "PATCH"; path: (a: readonly (string | number)[]) => string }> = {
  installationToken: { method: "POST", path: ([id]) => `/app/installations/${id}/access_tokens` }, pullRequest: { method: "GET", path: ([repo, pr]) => `/repositories/${repo}/pulls/${pr}` }, mainRef: { method: "GET", path: ([repo]) => `/repositories/${repo}/git/ref/heads/main` }, pullFiles: { method: "GET", path: ([repo, pr]) => `/repositories/${repo}/pulls/${pr}/files` }, openMainPulls: { method: "GET", path: ([repo]) => `/repositories/${repo}/pulls` }, appChecks: { method: "GET", path: ([repo, sha]) => `/repositories/${repo}/commits/${sha}/check-runs` }, createCheck: { method: "POST", path: ([repo]) => `/repositories/${repo}/check-runs` }, updateCheck: { method: "PATCH", path: ([repo, id]) => `/repositories/${repo}/check-runs/${id}` },
};
export function githubRoute(identity: FrozenEgressIdentity, route: Route, args: readonly (string | number)[], query = ""): Request {
  requireIdentity(identity, route, args); if (query && !/^[A-Za-z0-9_=&-]+$/.test(query)) throw new Error("github route rejected");
  const spec = routes[route]; const url = new URL(spec.path(args), githubApiOrigin); url.search = query;
  return new Request(url.toString(), { method: spec.method, redirect: "manual", headers: { Accept: "application/vnd.github+json", "X-GitHub-Api-Version": GITHUB_API_VERSION } });
}
export function isExactGithubRequest(identity: FrozenEgressIdentity, request: Request): boolean {
  const url = new URL(request.url); if (url.origin !== githubApiOrigin || url.username || url.password || url.hash || request.redirect !== "manual" || request.headers.get("accept") !== "application/vnd.github+json" || request.headers.get("x-github-api-version") !== GITHUB_API_VERSION) return false;
  const prefix = `/repositories/${identity.repositoryId}`;
  const patterns: Array<[string, RegExp]> = [["POST", new RegExp(`^/app/installations/${identity.installationId}/access_tokens$`)], ["GET", new RegExp(`^${prefix}/pulls/[1-9][0-9]*$`)], ["GET", new RegExp(`^${prefix}/git/ref/heads/main$`)], ["GET", new RegExp(`^${prefix}/pulls/[1-9][0-9]*/files$`)], ["GET", new RegExp(`^${prefix}/pulls$`)], ["GET", new RegExp(`^${prefix}/commits/[0-9a-f]{40}/check-runs$`)], ["POST", new RegExp(`^${prefix}/check-runs$`)], ["PATCH", new RegExp(`^${prefix}/check-runs/[1-9][0-9]*$`)]];
  if (!patterns.some(([method, path]) => request.method === method && path.test(url.pathname))) return false;
  if (url.search && !/^\?(?:page=[1-9][0-9]*&per_page=100|state=open&base=main&page=[1-9][0-9]*&per_page=100)$/.test(url.search)) return false;
  return true;
}
