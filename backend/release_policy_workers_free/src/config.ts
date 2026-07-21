export const REPOSITORY_ID = 1288597824;
export const MAX_WEBHOOK_BYTES = 26_214_400;
export const githubApiOrigin = "https://api.github.com";
export interface RuntimeConfig { appId: number; installationId: number; repositoryId: typeof REPOSITORY_ID; githubApiOrigin: typeof githubApiOrigin }
export function parseRuntimeConfig(value: string): RuntimeConfig {
  let parsed: unknown; try { parsed = JSON.parse(value); } catch { throw new Error("runtime configuration is invalid"); }
  if (parsed === null || Array.isArray(parsed) || typeof parsed !== "object") throw new Error("runtime configuration is invalid");
  const input = parsed as Record<string, unknown>;
  if (Object.keys(input).sort().join(",") !== "app_id,github_api_origin,installation_id,repository_id") throw new Error("runtime configuration keys mismatch");
  const positive = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value > 0;
  if (input.repository_id !== REPOSITORY_ID || input.github_api_origin !== githubApiOrigin || !positive(input.app_id) || !positive(input.installation_id)) throw new Error("runtime identity is invalid");
  return Object.freeze({ repositoryId: REPOSITORY_ID, appId: input.app_id, installationId: input.installation_id, githubApiOrigin });
}
export function repositoryObjectName(repositoryId: number): string { if (repositoryId !== REPOSITORY_ID) throw new Error("repository outside frozen policy"); return `repository:${repositoryId}`; }
