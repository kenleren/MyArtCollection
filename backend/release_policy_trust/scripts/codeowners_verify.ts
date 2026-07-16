import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { byteCompare, loadPolicy, repoRoot } from "./shared.js";

const policy = loadPolicy();
const selectors = [
  ...policy.selectors.baseline_prefixes,
  ...policy.selectors.baseline_exact,
  ...policy.selectors.final_prefix_additions,
  ...policy.selectors.final_exact_additions,
].map((selector) => `/${selector} @kenleren`).sort(byteCompare);
const expected = `# Generated from backend/release_policy_trust/policy/release-policy.v1.json.\n# Release-readiness trust boundary; repository-owner review is required.\n${selectors.join("\n")}\n`;
const actual = readFileSync(resolve(repoRoot, ".github/CODEOWNERS"), "utf8");
if (actual !== expected) throw new Error("CODEOWNERS diverges from canonical release policy selectors");
