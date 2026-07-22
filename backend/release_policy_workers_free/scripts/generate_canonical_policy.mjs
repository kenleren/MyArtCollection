import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const source = new URL("../../release_policy_trust/policy/release-policy.v1.json", import.meta.url);
const target = new URL("../src/generated/canonical_policy_bytes.ts", import.meta.url);
const bytes = readFileSync(source);
const digest = createHash("sha256").update(bytes).digest("hex");
const values = [...bytes].join(", ");
writeFileSync(target, `// Generated from backend/release_policy_trust/policy/release-policy.v1.json; do not edit.\nexport const CANONICAL_POLICY_BYTES = new Uint8Array([${values}]);\nexport const CANONICAL_POLICY_SHA256 = \"${digest}\";\n`);
