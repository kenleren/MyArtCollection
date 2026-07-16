import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { argument, byteCompare, git, hashBytes, loadPolicy, repoRoot, validateOid } from "./shared.js";

interface TreeRow { blob_oid: string; mode: string; path: string }
interface Expected { count: number; sha256: string }

const EXPECTED: Record<string, Expected> = {
  "current-tree.v1.jsonl": { count: 720, sha256: "bd184efac39afd68666a3e8a117043e05b3b6bec4a496e2687c8fb2ee3f3a65f" },
  "current-protected.v1.jsonl": { count: 51, sha256: "ac982e13bece1cbda5e3de180a927b884939637bb8ddb5423c8ec55c6566303f" },
  "history-commits.v1.jsonl": { count: 310, sha256: "5438e697250e8f6aa3933dacd490523a076d759c89b0ca7a8d90a264c3a7a72e" },
  "history-occurrences.v1.jsonl": { count: 122109, sha256: "bb65c6f27572208c8cd6a90bb7dc57df01fdef2a167e0ee9c2d91c39d17483d1" },
  "history-relations.v1.jsonl": { count: 1921, sha256: "7bf0c467d5209dd2a2d4a7b2db18408ae1f7107e7b6d7f4c5c028116f821b061" },
  "history-only.v1.jsonl": { count: 1201, sha256: "553fbbd0e2987939aa3682a99dc16eec02581c3f03b80f8953976d40a8614f48" },
  "history-blobs.v1.jsonl": { count: 1878, sha256: "4452ac6df7e9a7d2daecb8fc00151468031b10fe4b06984207f999b2851176ba" },
};

function decodePath(bytes: Buffer): string {
  let path: string;
  try { path = new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
  catch { throw new Error("tree path is not valid UTF-8"); }
  if (Buffer.compare(Buffer.from(path, "utf8"), bytes) !== 0 || path.normalize("NFC") !== path) throw new Error("tree path is not exact NFC UTF-8");
  return path;
}

function tree(commit: string): TreeRow[] {
  const output = git(["ls-tree", "-rz", "--full-tree", commit]) as Buffer;
  const chunks: Buffer[] = [];
  let start = 0;
  for (let index = 0; index < output.length; index += 1) {
    if (output[index] === 0) { chunks.push(output.subarray(start, index)); start = index + 1; }
  }
  if (start !== output.length) throw new Error("ls-tree output lacks final NUL");
  return chunks.map((chunk) => {
    const tab = chunk.indexOf(0x09);
    if (tab < 0) throw new Error("malformed ls-tree row");
    const metadata = chunk.subarray(0, tab).toString("ascii").split(" ");
    if (metadata.length !== 3 || metadata[1] !== "blob" || !["100644", "100755"].includes(metadata[0]!) || !/^[0-9a-f]{40}$/.test(metadata[2]!)) throw new Error("unsupported tree object");
    return { blob_oid: metadata[2]!, mode: metadata[0]!, path: decodePath(chunk.subarray(tab + 1)) };
  });
}

function jsonl(rows: readonly unknown[]): Buffer { return Buffer.from(rows.map((row) => JSON.stringify(row)).join("\n") + "\n", "utf8"); }
function write(path: string, rows: readonly unknown[]): void { writeFileSync(path, jsonl(rows)); }

function generate(tip: string, output: string): void {
  const policy = loadPolicy();
  if (tip !== policy.base_commit) throw new Error("history evidence tip is not the frozen base");
  const commitLines = (git(["rev-list", "--parents", tip], { encoding: "utf8" }) as string).trimEnd().split("\n");
  const commits = commitLines.map((line) => {
    const [commit_oid, ...parent_oids] = line.split(" ");
    if (!/^[0-9a-f]{40}$/.test(commit_oid!) || parent_oids.some((oid) => !/^[0-9a-f]{40}$/.test(oid))) throw new Error("malformed commit graph");
    return { commit_oid: commit_oid!, parent_oids };
  }).sort((a, b) => byteCompare(a.commit_oid, b.commit_oid));

  const occurrences: Array<TreeRow & { commit_oid: string }> = [];
  for (const commit of commits) for (const row of tree(commit.commit_oid)) occurrences.push({ blob_oid: row.blob_oid, commit_oid: commit.commit_oid, mode: row.mode, path: row.path });
  occurrences.sort((a, b) => byteCompare(a.commit_oid, b.commit_oid) || byteCompare(a.path, b.path) || byteCompare(a.mode, b.mode) || byteCompare(a.blob_oid, b.blob_oid));

  const current = tree(tip).sort((a, b) => byteCompare(a.path, b.path) || byteCompare(a.mode, b.mode) || byteCompare(a.blob_oid, b.blob_oid));
  const currentRelations = new Set(current.map((row) => `${row.path}\0${row.mode}\0${row.blob_oid}`));
  const relationMap = new Map<string, TreeRow>();
  for (const row of occurrences) relationMap.set(`${row.path}\0${row.mode}\0${row.blob_oid}`, { blob_oid: row.blob_oid, mode: row.mode, path: row.path });
  const relations = [...relationMap.values()].sort((a, b) => byteCompare(a.path, b.path) || byteCompare(a.mode, b.mode) || byteCompare(a.blob_oid, b.blob_oid)).map((row) => ({ blob_oid: row.blob_oid, history_only: !currentRelations.has(`${row.path}\0${row.mode}\0${row.blob_oid}`), mode: row.mode, path: row.path }));
  const historyOnly = relations.filter((row) => row.history_only);

  const blobOids = [...new Set(occurrences.map((row) => row.blob_oid))].sort(byteCompare);
  const batch = git(["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"], { encoding: "utf8", input: `${blobOids.join("\n")}\n` }) as string;
  const blobRows = batch.trimEnd().split("\n").map((line, index) => {
    const [blob_oid, type, sizeText] = line.split(" ");
    if (blob_oid !== blobOids[index] || type !== "blob" || !/^\d+$/.test(sizeText!)) throw new Error("batch object validation failed");
    const size = Number(sizeText);
    if (!Number.isSafeInteger(size) || size < 0) throw new Error("invalid blob size");
    return { blob_oid, size };
  });

  const protectedPath = (path: string): boolean => policy.selectors.baseline_exact.includes(path) || policy.selectors.baseline_prefixes.some((prefix) => path.startsWith(prefix));
  const currentRows = current.map((row) => ({ blob_oid: row.blob_oid, class: protectedPath(row.path) ? "protected-control" : "evaluated-input", mode: row.mode, path: row.path }));
  const protectedRows = currentRows.filter((row) => row.class === "protected-control");
  mkdirSync(output, { recursive: true });
  write(join(output, "current-tree.v1.jsonl"), currentRows);
  write(join(output, "current-protected.v1.jsonl"), protectedRows);
  write(join(output, "history-commits.v1.jsonl"), commits);
  write(join(output, "history-occurrences.v1.jsonl"), occurrences);
  write(join(output, "history-relations.v1.jsonl"), relations);
  write(join(output, "history-only.v1.jsonl"), historyOnly);
  write(join(output, "history-blobs.v1.jsonl"), blobRows);
}

function verifyDirectory(path: string): void {
  for (const [name, expected] of Object.entries(EXPECTED)) {
    const bytes = readFileSync(join(path, name));
    const lines = bytes.length === 0 ? 0 : bytes.toString("utf8").split("\n").length - 1;
    if (bytes[bytes.length - 1] !== 0x0a || bytes.includes(0x0d) || lines !== expected.count || hashBytes(bytes) !== expected.sha256) throw new Error(`${name} does not match frozen count/digest/LF contract`);
  }
}

const mode = process.argv[2];
const tip = validateOid(argument("--tip"));
if (mode === "generate") {
  const output = resolve(repoRoot, argument("--output"));
  generate(tip, output);
  verifyDirectory(output);
} else if (mode === "verify") {
  const input = resolve(repoRoot, argument("--input"));
  const temporary = join(tmpdir(), `release-policy-evidence-${process.pid}`);
  rmSync(temporary, { recursive: true, force: true });
  try {
    generate(tip, temporary);
    verifyDirectory(temporary);
    verifyDirectory(input);
    for (const name of Object.keys(EXPECTED)) if (Buffer.compare(readFileSync(join(input, name)), readFileSync(join(temporary, name))) !== 0) throw new Error(`${name} is not byte-reproducible`);
  } finally { rmSync(temporary, { recursive: true, force: true }); }
} else throw new Error("expected generate or verify mode");
