import { execFileSync } from "node:child_process";

const trustSourceExact = new Set([
  ".github/CODEOWNERS",
  ".github/workflows/release-readiness.yml",
  ".gitleaksignore",
  "docs/RELEASE_POLICY_TRUST.md",
  "docs/RELEASE_READINESS_CI.md",
]);

export function isTrustSourcePath(path: string): boolean {
  return path.startsWith("backend/release_policy_trust/") || path.startsWith("backend/release_policy_workers_free/") || trustSourceExact.has(path);
}

export function changedPaths(cwd: string, from: string, to: string): string[] {
  const output = execFileSync(
    "git",
    ["diff", "--no-renames", "--name-only", "-z", from, to, "--"],
    { cwd, maxBuffer: 1024 * 1024 * 512 },
  );
  return new TextDecoder("utf-8", { fatal: true })
    .decode(output)
    .split("\0")
    .filter(Boolean);
}

export function trustSourceChanged(cwd: string, from: string, to: string): boolean {
  return changedPaths(cwd, from, to).some(isTrustSourcePath);
}
