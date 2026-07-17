import { writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { repoRoot } from "./shared.js";
import { renderCodeowners } from "./codeowners_render.js";

writeFileSync(resolve(repoRoot, ".github/CODEOWNERS"), renderCodeowners(), "utf8");
