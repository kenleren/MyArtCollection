import assert from "node:assert/strict";
import test from "node:test";
import { evaluateChangedFiles } from "../src/paths.js";

const policy = { exact: ["docs/RELEASE_POLICY_TRUST.md"], prefixes: [".github/", "backend/release_policy_trust/"] };

test("every protected operation evaluates current and prior names", () => {
  for (const status of ["added", "modified", "removed"] as const) assert.deepEqual(evaluateChangedFiles([{ path: ".github/file.yml", status }], policy).protectedPaths, [".github/file.yml"]);
  for (const status of ["renamed", "copied"] as const) assert.deepEqual(evaluateChangedFiles([{ path: "lib/new.dart", previousPath: ".github/old.yml", status }], policy).protectedPaths, [".github/old.yml"]);
  assert.deepEqual(evaluateChangedFiles([{ path: ".github/new.yml", previousPath: "lib/old.dart", status: "renamed" }], policy).protectedPaths, [".github/new.yml"]);
});

test("future gitleaksignore path is protected for every candidate operation", () => {
  const futurePathPolicy = { exact: [".gitleaksignore"], prefixes: [] };
  for (const status of ["added", "modified", "removed"] as const) {
    assert.deepEqual(evaluateChangedFiles([{ path: ".gitleaksignore", status }], futurePathPolicy).protectedPaths, [".gitleaksignore"]);
  }
  for (const status of ["renamed", "copied"] as const) {
    assert.deepEqual(evaluateChangedFiles([{ path: "lib/ordinary", previousPath: ".gitleaksignore", status }], futurePathPolicy).protectedPaths, [".gitleaksignore"]);
    assert.deepEqual(evaluateChangedFiles([{ path: ".gitleaksignore", previousPath: "lib/ordinary", status }], futurePathPolicy).protectedPaths, [".gitleaksignore"]);
  }
});

test("malformed, duplicate, case-fold, and Unicode-collision paths fail", () => {
  for (const path of ["", "/absolute", "a\\b", "a/../b", "a/./b", "a//b", "a\u0000b", "Cafe\u0301.md"]) assert.throws(() => evaluateChangedFiles([{ path, status: "modified" }], policy));
  assert.throws(() => evaluateChangedFiles([{ path: "A.md", status: "modified" }, { path: "a.md", status: "modified" }], policy), /collision/);
  assert.throws(() => evaluateChangedFiles([{ path: "Straße.md", status: "modified" }, { path: "STRASSE.md", status: "modified" }], policy), /collision/);
  assert.throws(() => evaluateChangedFiles([{ path: "\u13A0.md", status: "modified" }, { path: "\uAB70.md", status: "modified" }], policy), /collision/);
  assert.throws(() => evaluateChangedFiles([{ path: "a.md", status: "modified" }, { path: "a.md", status: "modified" }], policy), /duplicate/);
  assert.throws(() => evaluateChangedFiles([{ path: "x", previousPath: "x", status: "renamed" }], policy));
  assert.throws(() => evaluateChangedFiles([{ path: ".gitleaksignore", status: "modified" }, { path: ".GITLEAKSIGNORE", status: "modified" }], policy), /collision/);
});
