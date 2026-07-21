import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { canonicalManifest, sha256 } from "../src/artifact.js";
const root = resolve(process.cwd());
const target = resolve(root, "evidence/artifact-manifest.v1.json");
const files = ["package.json", "package-lock.json", "wrangler.jsonc", "src/worker.ts", "src/sqlite_store.ts"];
const manifest = canonicalManifest(Object.fromEntries(files.map((f) => [f, sha256(readFileSync(resolve(root, f)))])), process.env.GIT_SHA ?? "synthetic");
if (process.argv[2] === "generate")
    writeFileSync(target, manifest);
else if (readFileSync(target, "utf8") !== manifest)
    throw new Error("artifact manifest drift");
