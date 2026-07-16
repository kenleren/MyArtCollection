import { execFileSync } from "node:child_process";

function revParse(cwd: string, ref: string): string {
  return execFileSync("git", ["rev-parse", "--verify", `${ref}^{commit}`], {
    cwd,
    encoding: "utf8",
  }).trim();
}

export function verifyFrozenBaseAndCandidate(cwd: string, base: string, candidate: string): void {
  if (revParse(cwd, base) !== base) throw new Error("frozen base object is unavailable");
  if (revParse(cwd, "refs/remotes/origin/main") !== base) throw new Error("origin/main moved from frozen bootstrap base");
  if (revParse(cwd, candidate) !== candidate) throw new Error("candidate object is unavailable");
  const mergeBase = execFileSync("git", ["merge-base", base, candidate], { cwd, encoding: "utf8" }).trim();
  if (mergeBase !== base) throw new Error("candidate is not based on frozen main");
}
