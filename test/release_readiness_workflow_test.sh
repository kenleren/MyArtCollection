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

expected_names=(
  'Test native attachment custody instrumentation contract'
  'Test native attachment custody contract (host)'
  'Test native attachment custody race (host)'
  'Test native attachment custody contract (ASan+UBSan)'
  'Test native attachment custody race (ASan+UBSan)'
  'Test native attachment custody contract (TSan)'
  'Test native attachment custody race (TSan)'
  'Test native attachment custody release symbols'
)
for name in "${expected_names[@]}"; do [[ "$(grep -Fxc "      - name: $name" "$workflow")" = 1 ]]; done
[[ "$(grep -Fxc '      - name: Require pinned native attachment custody compiler' "$workflow")" = 1 ]]
for command in \
  'CXX=g++-13 ATTACHMENT_CUSTODY_SUITE=contract ATTACHMENT_CUSTODY_SANITIZERS=none bash test/attachment_custody_native_test.sh' \
  'CXX=g++-13 ATTACHMENT_CUSTODY_SUITE=race ATTACHMENT_CUSTODY_SANITIZERS=none bash test/attachment_custody_native_test.sh' \
  'CXX=g++-13 ATTACHMENT_CUSTODY_SUITE=contract ATTACHMENT_CUSTODY_SANITIZERS=address,undefined bash test/attachment_custody_native_test.sh' \
  'CXX=g++-13 ATTACHMENT_CUSTODY_SUITE=race ATTACHMENT_CUSTODY_SANITIZERS=address,undefined bash test/attachment_custody_native_test.sh' \
  'CXX=g++-13 ATTACHMENT_CUSTODY_SUITE=contract ATTACHMENT_CUSTODY_SANITIZERS=thread bash test/attachment_custody_native_test.sh' \
  'CXX=g++-13 ATTACHMENT_CUSTODY_SUITE=race ATTACHMENT_CUSTODY_SANITIZERS=thread bash test/attachment_custody_native_test.sh'; do [[ "$(grep -Fxc "        run: $command" "$workflow")" = 1 ]]; done
if grep -F 'continue-on-error:' "$workflow"; then exit 1; fi

for step in 'Check Flutter formatting' 'Analyze Flutter project' 'Run serialized Flutter tests'; do
  [[ "$(grep -Fxc "      - name: $step" "$workflow")" = 1 ]]
done
for command in 'dart format --output=none --set-exit-if-changed lib test' 'flutter analyze' 'flutter test --concurrency=1'; do
  [[ "$(grep -Fxc "        run: $command" "$workflow")" = 1 ]]
done
if grep -F 'Check formatting, analysis, and tests' "$workflow"; then exit 1; fi

flutter_job="$(mktemp "${TMPDIR:-/tmp}/release-readiness-flutter-job.XXXXXX")"
trap 'rm -f "$flutter_job"' EXIT
[[ "$(grep -Fxc '  flutter-quality:' "$workflow")" = 1 ]]
awk 'BEGIN { in_job=0 } /^  flutter-quality:$/ { if (in_job) exit 1; in_job=1 } in_job && /^  [A-Za-z0-9_-]+:$/ && $0 != "  flutter-quality:" { exit } in_job { print } END { if (!in_job) exit 1 }' "$workflow" > "$flutter_job"
[[ -s "$flutter_job" ]]
for line in \
  '      - name: Fetch locked Flutter dependencies' \
  '        run: flutter pub get --enforce-lockfile' \
  '      - name: Check Flutter formatting' \
  '        run: dart format --output=none --set-exit-if-changed lib test' \
  '      - name: Analyze Flutter project' \
  '        run: flutter analyze' \
  '      - name: Run serialized Flutter tests' \
  '        run: flutter test --concurrency=1'; do [[ "$(grep -Fxc "$line" "$flutter_job")" = 1 ]]; done
[[ "$(grep -nF '      - name: Fetch locked Flutter dependencies' "$flutter_job" | cut -d: -f1)" -lt "$(grep -nF '      - name: Check Flutter formatting' "$flutter_job" | cut -d: -f1)" ]]
[[ "$(grep -nF '      - name: Check Flutter formatting' "$flutter_job" | cut -d: -f1)" -lt "$(grep -nF '      - name: Analyze Flutter project' "$flutter_job" | cut -d: -f1)" ]]
[[ "$(grep -nF '      - name: Analyze Flutter project' "$flutter_job" | cut -d: -f1)" -lt "$(grep -nF '      - name: Run serialized Flutter tests' "$flutter_job" | cut -d: -f1)" ]]
[[ "$(grep -Fxc '        run: flutter test --concurrency=1' "$flutter_job")" = 1 ]]
if grep -Eq '^[[:space:]]+(if:|continue-on-error:|strategy:|matrix:)|flutter (test|drive).*--(name|tags|exclude-tags|concurrency=[^1])|retry|rerun|for .* in' "$flutter_job"; then exit 1; fi

native="$repo_root/test/attachment_custody_native_test.sh"
for invalid in '' 'contract,contract' 'contract contract'; do
  result="$(ATTACHMENT_CUSTODY_SUITE="$invalid" CXX=clang++ bash "$native" 2>&1 || true)"
  [[ "$result" = CUSTODY_NATIVE_REJECTED ]]
done
for compiler in '/tmp/compiler' 'clang++ bad' $'clang++\nBAD' 'clang++=bad' 'clang++,bad' 'status=pass'; do
  result="$(ATTACHMENT_CUSTODY_SUITE=contract CXX="$compiler" bash "$native" 2>&1 || true)"
  [[ "$result" = CUSTODY_NATIVE_REJECTED ]]
done

for mode in none address,undefined thread; do
  result="$(CXX=clang++ ATTACHMENT_CUSTODY_SUITE=contract ATTACHMENT_CUSTODY_SANITIZERS="$mode" /bin/bash "$native" 2>&1)"
  [[ "$(printf '%s\n' "$result" | grep -Ec '^CUSTODY_NATIVE_RESULT suite=contract sanitizer=(none|address,undefined|thread) compiler=clangxx phase=cleanup class=cleanup exit=0 status=pass$')" = 1 ]]
done
