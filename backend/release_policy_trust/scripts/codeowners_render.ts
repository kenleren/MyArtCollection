import { byteCompare, loadPolicy } from "./shared.js";

export function renderCodeowners(): string {
  const policy = loadPolicy();
  const selectors = [
    ...policy.selectors.baseline_prefixes,
    ...policy.selectors.baseline_exact,
    ...policy.selectors.final_prefix_additions,
    ...policy.selectors.final_exact_additions,
  ].map((selector) => `/${selector} @kenleren`).sort(byteCompare);
  return `# Generated from backend/release_policy_trust/policy/release-policy.v1.json.\n# Release-readiness trust boundary; repository-owner review is required.\n${selectors.join("\n")}\n`;
}

export function verifyCodeowners(actual: string): void {
  if (actual !== renderCodeowners()) throw new Error("CODEOWNERS diverges from canonical release policy selectors");
}
