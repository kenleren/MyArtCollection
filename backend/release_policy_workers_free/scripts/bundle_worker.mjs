import { build, version } from "esbuild";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { resolve } from "node:path";

const root = process.cwd();
const outdir = resolve(root, "../../.work/release-policy-workers-free/bundle");
mkdirSync(outdir, { recursive: true });
const outfile = resolve(outdir, "worker.mjs");
const metafile = resolve(outdir, "metafile.json");
await build({ entryPoints: [resolve(root, "src/worker.ts")], outfile, bundle: true, format: "esm", platform: "neutral", target: "es2022", conditions: ["workerd", "worker", "browser"], external: ["node:crypto"], metafile: true, write: true, logLevel: "silent" }).then((result) => writeFileSync(metafile, JSON.stringify(result.metafile, null, 2) + "\n"));
const output = readFileSync(outfile);
const imports = [...output.toString("utf8").matchAll(/(?:from\s+|import\s*)["']([^"']+)["']/g)].map((match) => match[1]).sort();
if (imports.some((value) => value !== "node:crypto") || /(?:process\.env|node:http|cloudflare:workers|require\(|import\()/u.test(output.toString("utf8"))) throw new Error("bundle import contract violated");
const manifest = { entrypoint: "src/worker.ts", imports, inputs: Object.keys(JSON.parse(readFileSync(metafile, "utf8")).inputs).sort(), output: "worker.mjs" };
writeFileSync(resolve(outdir, "import-manifest.v1.json"), JSON.stringify(manifest) + "\n");
writeFileSync(resolve(outdir, "bundle-evidence.v1.json"), JSON.stringify({ sha256: createHash("sha256").update(output).digest("hex"), bytes: output.byteLength, esbuild: version, miniflare: "4.20260714.0", compatibility_flags: ["nodejs_compat", "nodejs_compat_v2", "nodejs_compat_do_not_populate_process_env", "disallow_importable_env"] }) + "\n");
