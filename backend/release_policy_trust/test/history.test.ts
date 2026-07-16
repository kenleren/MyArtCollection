import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";

const expected: Record<string, [number, string]> = {
  "current-tree.v1.jsonl": [720, "bd184efac39afd68666a3e8a117043e05b3b6bec4a496e2687c8fb2ee3f3a65f"],
  "current-protected.v1.jsonl": [51, "ac982e13bece1cbda5e3de180a927b884939637bb8ddb5423c8ec55c6566303f"],
  "history-commits.v1.jsonl": [310, "5438e697250e8f6aa3933dacd490523a076d759c89b0ca7a8d90a264c3a7a72e"],
  "history-occurrences.v1.jsonl": [122109, "bb65c6f27572208c8cd6a90bb7dc57df01fdef2a167e0ee9c2d91c39d17483d1"],
  "history-relations.v1.jsonl": [1921, "7bf0c467d5209dd2a2d4a7b2db18408ae1f7107e7b6d7f4c5c028116f821b061"],
  "history-only.v1.jsonl": [1201, "553fbbd0e2987939aa3682a99dc16eec02581c3f03b80f8953976d40a8614f48"],
  "history-blobs.v1.jsonl": [1878, "4452ac6df7e9a7d2daecb8fc00151468031b10fe4b06984207f999b2851176ba"],
};

test("frozen history evidence has exact byte serialization, counts, and digests", () => {
  const root = resolve(process.cwd(), "evidence/base");
  for (const [name, [count, digest]] of Object.entries(expected)) {
    const bytes = readFileSync(resolve(root, name));
    assert.equal(bytes.at(-1), 0x0a); assert.equal(bytes.includes(0x0d), false); assert.equal(bytes.subarray(0, 3).equals(Buffer.from([0xef, 0xbb, 0xbf])), false);
    assert.equal(bytes.toString("utf8").split("\n").length - 1, count);
    assert.equal(createHash("sha256").update(bytes).digest("hex"), digest);
  }
});
