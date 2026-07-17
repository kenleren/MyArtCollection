import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import { renderCodeowners, verifyCodeowners } from "../scripts/codeowners_render.js";

test("CODEOWNERS is deterministically rendered from the canonical selectors", () => {
  const rendered = renderCodeowners();
  assert.match(rendered, /^\/\.gitleaksignore @kenleren$/m);
  assert.equal(rendered, readFileSync(resolve(process.cwd(), "../../.github/CODEOWNERS"), "utf8"));
  assert.doesNotThrow(() => verifyCodeowners(rendered));
});

test("CODEOWNERS guard rejects omitted and spoofed generated ownership", () => {
  const rendered = renderCodeowners();
  assert.throws(() => verifyCodeowners(rendered.replace("/.gitleaksignore @kenleren\n", "")), /diverges/);
  assert.throws(() => verifyCodeowners(rendered.replace("/.gitleaksignore @kenleren", "/.gitleaksignore @other-owner")), /diverges/);
});
