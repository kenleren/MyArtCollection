import { fail } from "./errors.js";

export type FileStatus = "added" | "modified" | "removed" | "renamed" | "copied";
export interface ChangedFile { path: string; previousPath?: string; status: FileStatus }
export interface PathPolicy { exact: readonly string[]; prefixes: readonly string[] }

// ECMAScript's Unicode casing plus the three Unicode 15.1 full-fold exceptions
// to upper-then-lower yields the default full case fold. Node is version-pinned;
// Cherokee folds to uppercase, dotless i remains dotless, and capital sharp-s
// expands to "ss". NFC is applied only to make the collision key stable.
export function fullUnicodeCaseFold(value: string): string {
  let output = "";
  for (const character of value) {
    const code = character.codePointAt(0)!;
    if (code === 0x0131) output += character;
    else if (code === 0x1e9e) output += "ss";
    else if ((code >= 0x13a0 && code <= 0x13f5)) output += character;
    else if (code >= 0x13f8 && code <= 0x13fd) output += String.fromCodePoint(code - 8);
    else if (code >= 0xab70 && code <= 0xabbf) output += String.fromCodePoint(code - 0x97d0);
    else output += character.toUpperCase().toLowerCase();
  }
  return output.normalize("NFC");
}

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
      const collisionKey = fullUnicodeCaseFold(path);
      const prior = folded.get(collisionKey);
      if (prior !== undefined && prior !== path) fail("invalid_input", "case or Unicode path collision");
      folded.set(collisionKey, path);
      if (isProtected(path, policy)) protectedPaths.add(path);
    }
  }
  return { protectedPaths: [...protectedPaths].sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b))) };
}
