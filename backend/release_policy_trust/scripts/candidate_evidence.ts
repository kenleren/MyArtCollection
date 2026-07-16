import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { isProtected } from "../src/paths.js";
import { argument, git, loadPolicy, repoRoot, validateOid } from "./shared.js";

const candidateArgument = argument("--candidate");
const outputPath = resolve(repoRoot, argument("--output"));
const command = candidateArgument === "INDEX"
  ? ["ls-files", "--stage", "-z"]
  : ["ls-tree", "-rz", "--full-tree", validateOid(candidateArgument)];
const output = git(command) as Buffer;
const policy = loadPolicy();
const finalPolicy = { exact: [...policy.selectors.baseline_exact, ...policy.selectors.final_exact_additions], prefixes: [...policy.selectors.baseline_prefixes, ...policy.selectors.final_prefix_additions] };
const rows: string[] = [];
let start = 0;
for (let index = 0; index < output.length; index += 1) if (output[index] === 0) {
  const chunk = output.subarray(start, index); start = index + 1;
  const tab = chunk.indexOf(0x09);
  const metadata = chunk.subarray(0, tab).toString("ascii").split(" ");
  const mode = metadata[0]!;
  const blobOid = candidateArgument === "INDEX" ? metadata[1]! : metadata[2]!;
  const path = new TextDecoder("utf-8", { fatal: true }).decode(chunk.subarray(tab + 1));
  if (path.startsWith("backend/release_policy_trust/evidence/review/")) continue;
  if (path.normalize("NFC") !== path || !["100644", "100755"].includes(mode) || !/^[0-9a-f]{40}$/.test(blobOid)) throw new Error("candidate inventory row is malformed");
  rows.push(JSON.stringify({ blob_oid: blobOid, class: isProtected(path, finalPolicy) ? "protected-control" : "evaluated-input", mode, path }));
}
mkdirSync(resolve(outputPath, ".."), { recursive: true });
writeFileSync(outputPath, `${rows.join("\n")}\n`);
