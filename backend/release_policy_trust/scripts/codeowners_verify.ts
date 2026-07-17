import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { repoRoot } from "./shared.js";
import { verifyCodeowners } from "./codeowners_render.js";

const actual = readFileSync(resolve(repoRoot, ".github/CODEOWNERS"), "utf8");
verifyCodeowners(actual);
