#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$repo_root/.github/workflows/release-readiness.yml"
image='rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667'

grep -F 'name: Run digest-pinned actionlint' "$workflow"
grep -F "$image" "$workflow"
grep -F -- '--read-only --cap-drop=ALL --network none' "$workflow"
grep -F -- '-v "$GITHUB_WORKSPACE:/repo:ro" -w /repo' "$workflow"
grep -F "PATH=/usr/bin:/bin /usr/local/bin/actionlint -color" "$workflow"
if grep -F 'releases/download/v1.7.12' "$workflow"; then
  echo "Workflow lint must not depend on the repeatedly unavailable release asset." >&2
  exit 1
fi
for step in \
  'Test native attachment custody instrumentation contract' \
  'Require pinned native attachment custody compiler' \
  'Test native attachment custody contract (host)' \
  'Test native attachment custody race (host)' \
  'Test native attachment custody contract (ASan+UBSan)' \
  'Test native attachment custody race (ASan+UBSan)' \
  'Test native attachment custody contract (TSan)' \
  'Test native attachment custody race (TSan)' \
  'Test native attachment custody release symbols'; do grep -F "name: $step" "$workflow"; done
grep -F 'command -v g++-13' "$workflow"
if grep -F 'Test native attachment custody crash and race contracts' "$workflow"; then exit 1; fi
