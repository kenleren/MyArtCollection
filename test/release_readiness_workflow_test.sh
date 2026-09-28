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

flutter_job="$(mktemp "${TMPDIR:-/tmp}/release-readiness-flutter-job.XXXXXX")"
canonical_flutter_job="$(mktemp "${TMPDIR:-/tmp}/release-readiness-canonical-flutter-job.XXXXXX")"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/release-readiness-flutter-fixture.XXXXXX")"
trap 'rm -f "$flutter_job" "$canonical_flutter_job"; rm -rf "$fixture_dir"' EXIT
[[ "$(grep -Fxc '  flutter-quality:' "$workflow")" = 1 ]]
# Keep internal blank lines, but exclude the separator before the next job.
awk '
  /^  flutter-quality:$/ { in_job=1 }
  in_job && /^  [A-Za-z0-9_-]+:$/ && $0 != "  flutter-quality:" { exit }
  in_job {
    if (NF == 0) { separator=separator $0 ORS; next }
    printf "%s%s\n", separator, $0
    separator=""
  }
  END { if (!in_job) exit 1 }
' "$workflow" > "$flutter_job"
[[ -s "$flutter_job" ]]
cat > "$canonical_flutter_job" <<'EOF'
  flutter-quality:
    name: Flutter quality
    runs-on: ubuntu-24.04
    steps:
      - name: Check out repository
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0
        with:
          persist-credentials: false
      - name: Restore Dart dependency cache
        uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9
        with:
          path: ~/.pub-cache
          key: pub-${{ runner.os }}-${{ hashFiles('pubspec.lock') }}
          restore-keys: pub-${{ runner.os }}-
      - name: Install checksum-verified Flutter
        shell: bash
        run: |
          set -euo pipefail
          archive="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
          curl -fsSLO "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${archive}"
          printf '%s  %s\n' "$FLUTTER_LINUX_X64_SHA256" "$archive" | sha256sum -c -
          tar -xJf "$archive" -C "$RUNNER_TEMP"
          echo "$RUNNER_TEMP/flutter/bin" >> "$GITHUB_PATH"
      - name: Install PDF text extraction for report assertions
        shell: bash
        run: |
          set -euo pipefail
          evidence="$RUNNER_TEMP/poppler-apt-evidence"
          archives="$evidence/archives"
          mkdir -p "$archives/partial"
          sudo apt-get update
          apt-get --simulate install --no-install-recommends poppler-utils \
            > "$evidence/simulation.txt"
          awk '
            /^Inst / {
              package_name=$2
              version=""
              architecture=$NF
              gsub(/[\[\])]/, "", architecture)
              for (i=3; i<=NF; i++) {
                if ($i ~ /^\(/) {
                  version=$i
                  gsub(/^\(/, "", version)
                  break
                }
              }
              if (version == "" || architecture == "") exit 1
              print package_name "\t" version "\t" architecture
            }
          ' "$evidence/simulation.txt" | LC_ALL=C sort -u > "$evidence/expected.tsv"
          sudo apt-get -o "Dir::Cache::archives=$archives" install \
            --yes --download-only --no-install-recommends poppler-utils
          : > "$evidence/actual.tsv"
          while IFS= read -r -d '' archive; do
            package_name="$(dpkg-deb -f "$archive" Package)"
            version="$(dpkg-deb -f "$archive" Version)"
            architecture="$(dpkg-deb -f "$archive" Architecture)"
            digest="$(sha256sum "$archive" | cut -d ' ' -f 1)"
            printf '%s\t%s\t%s\t%s\n' \
              "$package_name" "$version" "$architecture" "$digest" \
              >> "$evidence/actual.tsv"
          done < <(find "$archives" -maxdepth 1 -type f -name '*.deb' -print0)
          cut -f 1-3 "$evidence/actual.tsv" | LC_ALL=C sort -u \
            > "$evidence/actual-coordinates.tsv"
          diff -u "$evidence/expected.tsv" "$evidence/actual-coordinates.tsv"
          awk -F '\t' 'NF != 4 || $4 !~ /^[0-9a-f]{64}$/ { exit 1 }' \
            "$evidence/actual.tsv"
          sha256sum \
            "$evidence/simulation.txt" \
            "$evidence/expected.tsv" \
            "$evidence/actual.tsv" \
            "$evidence/actual-coordinates.tsv" \
            > "$evidence/runtime-evidence.sha256"
          test "$(wc -l < "$evidence/runtime-evidence.sha256")" -eq 4
          sudo apt-get -o "Dir::Cache::archives=$archives" install \
            --yes --no-download --no-install-recommends poppler-utils
          pdftotext -v
      - name: Map checksum-verified Flutter test fonts
        shell: bash
        run: |
          set -euo pipefail
          roboto="$RUNNER_TEMP/flutter/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf"
          test -f "$roboto"
          sudo install -d /opt/homebrew/share /System/Library/Fonts
          sudo ln -s "$RUNNER_TEMP/flutter" /opt/homebrew/share/flutter
          sudo ln -s "$roboto" /System/Library/Fonts/SFNS.ttf
      - name: Fetch locked Flutter dependencies
        run: flutter pub get --enforce-lockfile
      - name: Check Flutter formatting
        run: dart format --output=none --set-exit-if-changed lib test
      - name: Analyze Flutter project
        run: flutter analyze
      - name: Run serialized Flutter tests
        run: flutter test --concurrency=1
EOF

validate_flutter_job() {
  cmp -s "$canonical_flutter_job" "$1"
}
validate_flutter_job "$flutter_job"

literal_replace_once() {
  local input=$1 output=$2 target=$3 replacement=$4 line found=0
  : > "$output"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$target" ]]; then
      printf '%s\n' "$replacement" >> "$output"
      found=$((found + 1))
    else
      printf '%s\n' "$line" >> "$output"
    fi
  done < "$input"
  [[ "$found" = 1 ]]
}
generated=0 applied=0 validator_reached=0 rejected=0
mutations=(
  runner '    runs-on: ubuntu-24.04' '    runs-on: ubuntu-22.04'
  checkout_pin '        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0' '        uses: actions/checkout@broken'
  credential '          persist-credentials: false' '          persist-credentials: true'
  cache_pin '        uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9' '        uses: actions/cache@broken'
  cache_path '          path: ~/.pub-cache' '          path: ~/.bad-cache'
  cache_key "          key: pub-\${{ runner.os }}-\${{ hashFiles('pubspec.lock') }}" '          key: pub-altered'
  cache_restore_key "          restore-keys: pub-\${{ runner.os }}-" '          restore-keys: pub-altered'
  flutter_name '      - name: Install checksum-verified Flutter' '      - name: Install Flutter'
  flutter_url "          curl -fsSLO \"https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/\${archive}\"" "          curl -fsSLO \"https://example.invalid/flutter/\${archive}\""
  flutter_checksum "          printf '%s  %s\\n' \"\$FLUTTER_LINUX_X64_SHA256\" \"\$archive\" | sha256sum -c -" "          printf '%s  %s\\n' \"\$FLUTTER_LINUX_X64_SHA256\" \"\$archive\""
  pdf_name '      - name: Install PDF text extraction for report assertions' '      - name: Install PDF tools'
  pdf_command '          pdftotext -v' '          pdftotext --version'
  font_name '      - name: Map checksum-verified Flutter test fonts' '      - name: Map fonts'
  font_target "          sudo ln -s \"\$roboto\" /System/Library/Fonts/SFNS.ttf" "          sudo ln -s \"\$roboto\" /System/Library/Fonts/Roboto-Regular.ttf"
  fetch '        run: flutter pub get --enforce-lockfile' '        run: flutter pub get'
  format '        run: dart format --output=none --set-exit-if-changed lib test' '        run: dart format lib test'
  analysis '        run: flutter analyze' '        run: flutter analyze --no-fatal-infos'
  test_concurrency '        run: flutter test --concurrency=1' '        run: flutter test --concurrency=2'
)
[[ "${#mutations[@]}" = 54 ]]
for ((index=0; index < ${#mutations[@]}; index += 3)); do
  name=${mutations[index]}
  target=${mutations[index + 1]}
  replacement=${mutations[index + 2]}
  [[ -n "$name" && -n "$target" && -n "$replacement" ]]
  for ((prior=0; prior < index; prior += 3)); do
    [[ "$name" != "${mutations[prior]}" ]]
    [[ "$target" != "${mutations[prior + 1]}" ]]
  done
  candidate="$fixture_dir/$name.yml"
  reverse="$fixture_dir/$name.reverse.yml"
  [[ -s "$flutter_job" && "$(grep -Fxc "$target" "$flutter_job")" = 1 ]]
  literal_replace_once "$flutter_job" "$candidate" "$target" "$replacement"
  [[ -f "$candidate" && -s "$candidate" ]]
  ! cmp -s "$flutter_job" "$candidate"
  generated=$((generated + 1))
  [[ "$(grep -Fxc "$target" "$candidate")" = 0 && "$(grep -Fxc "$replacement" "$candidate")" = 1 ]]
  applied=$((applied + 1))
  literal_replace_once "$candidate" "$reverse" "$replacement" "$target"
  cmp -s "$flutter_job" "$reverse"
  validator_reached=$((validator_reached + 1))
  if validate_flutter_job "$candidate"; then exit 1; fi
  rejected=$((rejected + 1))
done
[[ "$generated" = 18 && "$generated" = "$applied" && "$generated" = "$validator_reached" && "$generated" = "$rejected" ]]

native="$repo_root/test/attachment_custody_native_test.sh"
for invalid in '' 'contract,contract' 'contract contract'; do
  result="$(ATTACHMENT_CUSTODY_SUITE="$invalid" CXX=clang++ bash "$native" 2>&1 || true)"
  [[ "$result" = CUSTODY_NATIVE_REJECTED ]]
done
for compiler in '/tmp/compiler' 'clang++ bad' $'clang++\nBAD' 'clang++=bad' 'clang++,bad' 'status=pass'; do
  result="$(ATTACHMENT_CUSTODY_SUITE=contract CXX="$compiler" bash "$native" 2>&1 || true)"
  [[ "$result" = CUSTODY_NATIVE_REJECTED ]]
done

# Runtime coverage belongs to the six pinned-compiler Android custody steps.
# This gate checks workflow structure and rejection before compiler execution.
printf '%s\n' 'Release workflow contract passed.'
