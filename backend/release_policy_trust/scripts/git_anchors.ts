import { execFileSync } from "node:child_process";

function revParse(cwd: string, ref: string): string {
  return execFileSync("git", ["rev-parse", "--verify", `${ref}^{commit}`], {
    cwd,
    encoding: "utf8",
  }).trim();
}

function mergeBase(cwd: string, left: string, right: string): string {
  return execFileSync("git", ["merge-base", left, right], { cwd, encoding: "utf8" }).trim();
}

export interface AnchorContext {
  expectedMain: string;
  mode: "frozen-bootstrap-pr" | "post-merge-main";
}

export function verifyFrozenBaseAndCandidate(cwd: string, base: string, candidate: string, context: AnchorContext): void {
  if (revParse(cwd, base) !== base) throw new Error("frozen base object is unavailable");
  if (revParse(cwd, candidate) !== candidate) throw new Error("candidate object is unavailable");
  if (revParse(cwd, context.expectedMain) !== context.expectedMain) throw new Error("expected main object is unavailable");
  if (revParse(cwd, "refs/remotes/origin/main") !== context.expectedMain) throw new Error("origin/main differs from expected event main");

  if (context.mode === "frozen-bootstrap-pr") {
    if (mergeBase(cwd, base, context.expectedMain) !== base) throw new Error("pull request base is not descended from frozen main");
    if (mergeBase(cwd, context.expectedMain, candidate) !== context.expectedMain) throw new Error("candidate is not based on expected pull request main");
    return;
  }
  if (context.mode === "post-merge-main") {
    if (candidate !== context.expectedMain) throw new Error("post-merge candidate differs from expected main");
    if (mergeBase(cwd, base, candidate) !== base) throw new Error("post-merge main is not descended from frozen main");
    return;
  }
  throw new Error("unsupported anchor verification mode");
}
