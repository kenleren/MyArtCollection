import { fail } from "./errors.js";

export type FileStatus = "added" | "modified" | "removed" | "renamed" | "copied";
export interface ChangedFile { path: string; previousPath?: string; status: FileStatus }
export interface PathPolicy { exact: readonly string[]; prefixes: readonly string[] }

export function validateRepositoryPath(path: string): string {
  if (path.length === 0 || path.startsWith("/") || path.includes("\\") || /[\u0000-\u001f\u007f]/.test(path)) {
    return fail("invalid_input", "malformed repository path");
  }
  if (path.normalize("NFC") !== path) fail("invalid_input", "repository path must be NFC");
  const segments = path.split("/");
  if (segments.some((segment) => segment === "" || segment === "." || segment === "..")) fail("invalid_input", "repository path has invalid segment");
  return path;
}

export function isProtected(path: string, policy: PathPolicy): boolean {
  return policy.exact.includes(path) || policy.prefixes.some((prefix) => path.startsWith(prefix));
}

export function evaluateChangedFiles(files: readonly ChangedFile[], policy: PathPolicy): { protectedPaths: string[] } {
  const exact = new Set<string>();
  const folded = new Map<string, string>();
  const protectedPaths = new Set<string>();
  for (const file of files) {
    if (!(["added", "modified", "removed", "renamed", "copied"] as string[]).includes(file.status)) fail("invalid_input", "unsupported file status");
    if ((file.status === "renamed" || file.status === "copied") !== (file.previousPath !== undefined)) fail("invalid_input", "prior path contract mismatch");
    const paths = file.previousPath === undefined ? [file.path] : [file.previousPath, file.path];
    if (file.previousPath === file.path) fail("invalid_input", "prior and current paths must differ");
    for (const candidate of paths) {
      const path = validateRepositoryPath(candidate);
      if (exact.has(path)) fail("invalid_input", "duplicate repository path");
      exact.add(path);
      const collisionKey = path.normalize("NFC").toLowerCase();
      const prior = folded.get(collisionKey);
      if (prior !== undefined && prior !== path) fail("invalid_input", "case or Unicode path collision");
      folded.set(collisionKey, path);
      if (isProtected(path, policy)) protectedPaths.add(path);
    }
  }
  return { protectedPaths: [...protectedPaths].sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b))) };
}
