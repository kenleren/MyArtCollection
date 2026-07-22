import { sha256 } from "@archivale/release-policy-trust";
export const REPOSITORY_ID = 1288597824;
export const REPOSITORY_NAME = "kenleren/MyArtCollection";
export const MAX_WEBHOOK_BYTES = 26_214_400;
export const githubApiOrigin = "https://api.github.com";
export const GITHUB_API_VERSION = "2022-11-28";
export const POLICY_SHA256 = "a443af2eb86fa310ea8705826e70d1b178a4d8d231060440ed522d3069b9a80d";
export const EGRESS_MANIFEST_SHA256 = "0e1666e746a12f05885ddc7c13919fd8b03e6fed6af873b47c78050e358148f3";
export const SQLITE_COMPATIBILITY_SHA256 = "1d5246c2a0f056208b2652129023c8f99ce33a17a5156ce27d63c982681b9ff2";
export const FIXED_PERMISSIONS = Object.freeze({ checks: "write", contents: "read", metadata: "read", pull_requests: "read" });
export const FIXED_QUOTA = Object.freeze({ window_seconds: 86400, warning_units: 1000, hard_units: 10000 });
const keys = ["app_id", "contract_version", "egress_manifest_sha256", "github_api_origin", "github_api_version", "installation_id", "permissions", "policy_sha256", "quota", "repository_id", "repository_name"];
const positive = (value) => typeof value === "number" && Number.isSafeInteger(value) && value > 0;
const exactRecord = (value, expected) => value !== null && typeof value === "object" && !Array.isArray(value) && JSON.stringify(Object.keys(value).sort()) === JSON.stringify(Object.keys(expected).sort()) && Object.entries(expected).every(([key, wanted]) => value[key] === wanted);
function canonicalActivation(input) {
    const normalized = { contract_version: input.contractVersion, repository_id: input.repositoryId, repository_name: input.repositoryName, app_id: input.appId, installation_id: input.installationId, github_api_origin: input.githubApiOrigin, github_api_version: input.githubApiVersion, policy_sha256: input.policySha256, egress_manifest_sha256: input.egressManifestSha256, permissions: input.permissions, quota: input.quota };
    return `sha256:${sha256(JSON.stringify({ config: normalized, sqlite_compatibility_sha256: SQLITE_COMPATIBILITY_SHA256 }))}`;
}
export function parseRuntimeConfig(value) {
    let parsed;
    try {
        parsed = JSON.parse(value);
    }
    catch {
        throw new Error("runtime configuration is invalid");
    }
    if (parsed === null || Array.isArray(parsed) || typeof parsed !== "object" || JSON.stringify(Object.keys(parsed).sort()) !== JSON.stringify(keys))
        throw new Error("runtime configuration keys mismatch");
    const input = parsed;
    if (input.contract_version !== 1 || input.repository_id !== REPOSITORY_ID || input.repository_name !== REPOSITORY_NAME || input.github_api_origin !== githubApiOrigin || input.github_api_version !== GITHUB_API_VERSION || input.policy_sha256 !== POLICY_SHA256 || input.egress_manifest_sha256 !== EGRESS_MANIFEST_SHA256 || !positive(input.app_id) || !positive(input.installation_id) || !exactRecord(input.permissions, FIXED_PERMISSIONS) || !exactRecord(input.quota, FIXED_QUOTA))
        throw new Error("runtime identity is invalid");
    const base = { contractVersion: 1, repositoryId: REPOSITORY_ID, repositoryName: REPOSITORY_NAME, appId: input.app_id, installationId: input.installation_id, githubApiOrigin, githubApiVersion: GITHUB_API_VERSION, policySha256: POLICY_SHA256, egressManifestSha256: EGRESS_MANIFEST_SHA256, permissions: FIXED_PERMISSIONS, quota: FIXED_QUOTA };
    return Object.freeze({ ...base, activationDigest: canonicalActivation(base) });
}
export function repositoryObjectName(repositoryId) { if (repositoryId !== REPOSITORY_ID)
    throw new Error("repository outside frozen policy"); return `repository:${repositoryId}`; }
