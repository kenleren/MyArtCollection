import { githubApiOrigin } from "./config.js";
export type Route = "installationToken" | "pullRequest" | "mainRef" | "pullFiles" | "openMainPulls" | "appChecks" | "createCheck" | "updateCheck";
const routes: Record<Route, { method: "GET" | "POST" | "PATCH"; path: (a: readonly (string | number)[]) => string }> = {
  installationToken: { method: "POST", path: ([id]) => `/app/installations/${id}/access_tokens` }, pullRequest: { method: "GET", path: ([repo, pr]) => `/repositories/${repo}/pulls/${pr}` }, mainRef: { method: "GET", path: ([repo]) => `/repositories/${repo}/git/ref/heads/main` }, pullFiles: { method: "GET", path: ([repo, pr]) => `/repositories/${repo}/pulls/${pr}/files` }, openMainPulls: { method: "GET", path: ([repo]) => `/repositories/${repo}/pulls` }, appChecks: { method: "GET", path: ([repo, sha]) => `/repositories/${repo}/commits/${sha}/check-runs` }, createCheck: { method: "POST", path: ([repo]) => `/repositories/${repo}/check-runs` }, updateCheck: { method: "PATCH", path: ([repo, id]) => `/repositories/${repo}/check-runs/${id}` }
};
export function githubRoute(route: Route, args: readonly (string | number)[], query = ""): Request {
  const spec = routes[route]; if (!spec) throw new Error("github route rejected");
  const url = new URL(spec.path(args), githubApiOrigin); url.search = query;
  // Workerd rejects RequestInit.redirect="error". "manual" prevents following
  // and the response validation rejects every 3xx before body consumption.
  return new Request(url.toString(), { method: spec.method, redirect: "manual", headers: { Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" } });
}
