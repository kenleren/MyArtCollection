import { execFileSync } from "node:child_process";
import { resolve } from "node:path";

const root = resolve(process.cwd());
execFileSync(process.execPath, ["--disable-warning=ExperimentalWarning", resolve(root, "scripts/sqlite_conformance.mjs"), "--restore-rehearsal"], { cwd: root, stdio: "inherit" });
