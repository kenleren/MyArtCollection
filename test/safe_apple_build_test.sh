#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
wrapper="$repo_root/scripts/safe_apple_build.sh"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

test_home="$fixture_dir/test home"
test_tmp="$fixture_dir/test tmp"
developer_dir="$fixture_dir/developer"
mkdir -p "$test_home" "$test_tmp" "$developer_dir"

make_fake_tool() {
  local exit_code="$1"
  cat >"$fixture_dir/fake-tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output="$0.output"
{
  printf 'ARGV_BEGIN\n'
  printf '<%s>\n' "$@"
  printf 'ARGV_END\n'
  printf 'ENV_BEGIN\n'
  env | LC_ALL=C sort
  printf 'ENV_END\n'
} > "$output"
EOF
  printf 'exit %s\n' "$exit_code" >>"$fixture_dir/fake-tool"
  chmod +x "$fixture_dir/fake-tool"
}

assert_contains() {
  grep -Fqx "$1" "$2" || { echo "Expected line missing: $1" >&2; exit 1; }
}

assert_not_contains() {
  ! grep -Fq "$1" "$2" || { echo "Unexpected content found: $1" >&2; exit 1; }
}

run_direct() {
  make_fake_tool 0
  env \
    HOME="$test_home" \
    TMPDIR="$test_tmp" \
    DEVELOPER_DIR="$fixture_dir/inherited-developer" \
    MY_ART_COLLECTION_SAFE_APPLE_BUILD_TEST=1 \
    SYNTHETIC_CREDENTIAL_SENTINEL='synthetic credential value' \
    ARBITRARY_PARENT_SENTINEL='arbitrary parent value' \
    "$wrapper" --test-only-executable "$fixture_dir/fake-tool" "$@"
}

run_direct xcodebuild -- 'argument with spaces' -- --flag
direct_output="$fixture_dir/fake-tool.output"
assert_contains '<-quiet>' "$direct_output"
assert_contains '<argument with spaces>' "$direct_output"
assert_contains '<-->' "$direct_output"
assert_contains '<--flag>' "$direct_output"
assert_contains "HOME=$test_home" "$direct_output"
assert_contains "TMPDIR=$test_tmp" "$direct_output"
assert_contains 'LANG=C' "$direct_output"
assert_contains 'LC_ALL=C' "$direct_output"
assert_contains 'COCOAPODS_DISABLE_STATS=true' "$direct_output"
assert_contains 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' "$direct_output"
assert_not_contains 'DEVELOPER_DIR=' "$direct_output"
assert_not_contains 'SYNTHETIC_CREDENTIAL_SENTINEL' "$direct_output"
assert_not_contains 'synthetic credential value' "$direct_output"
assert_not_contains 'ARBITRARY_PARENT_SENTINEL' "$direct_output"
assert_not_contains 'arbitrary parent value' "$direct_output"
assert_not_contains 'MY_ART_COLLECTION_SAFE_APPLE_BUILD_TEST' "$direct_output"
assert_not_contains 'test-only-executable' "$direct_output"

verbose_output="$fixture_dir/verbose-output"
run_direct --developer-dir "$developer_dir" xcodebuild --verbose -- --target Runner
verbose_output="$fixture_dir/fake-tool.output"
assert_not_contains '<-quiet>' "$verbose_output"
assert_contains '<--target>' "$verbose_output"
assert_contains '<Runner>' "$verbose_output"
assert_contains "DEVELOPER_DIR=$developer_dir" "$verbose_output"

flutter_output="$fixture_dir/flutter-output"
make_fake_tool 0
env HOME="$test_home" TMPDIR="$test_tmp" MY_ART_COLLECTION_SAFE_APPLE_BUILD_TEST=1 \
  "$wrapper" --test-only-executable "$fixture_dir/fake-tool" \
  flutter-ios-simulator-debug --flutter-bin "$fixture_dir/fake-tool"
flutter_output="$fixture_dir/fake-tool.output"
assert_contains '<--suppress-analytics>' "$flutter_output"
assert_contains '<build>' "$flutter_output"
assert_contains '<ios>' "$flutter_output"
assert_contains '<--simulator>' "$flutter_output"
assert_contains '<--debug>' "$flutter_output"
assert_contains '<--no-codesign>' "$flutter_output"
assert_contains "PATH=$fixture_dir:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$flutter_output"

default_tmp_output="$fixture_dir/default-tmp-output"
make_fake_tool 0
env -u TMPDIR HOME="$test_home" MY_ART_COLLECTION_SAFE_APPLE_BUILD_TEST=1 \
  "$wrapper" --test-only-executable "$fixture_dir/fake-tool" xcodebuild --
default_tmp_output="$fixture_dir/fake-tool.output"
assert_contains 'TMPDIR=/tmp' "$default_tmp_output"

failure_output="$fixture_dir/failure-output"
make_fake_tool 73
set +e
env HOME="$test_home" TMPDIR="$test_tmp" MY_ART_COLLECTION_SAFE_APPLE_BUILD_TEST=1 \
  "$wrapper" --test-only-executable "$fixture_dir/fake-tool" xcodebuild -- >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 73 ]] || { echo "Child exit status was not preserved." >&2; exit 1; }

set +e
invalid_output="$(env HOME=relative-home MY_ART_COLLECTION_SAFE_APPLE_BUILD_TEST=1 \
  "$wrapper" --test-only-executable "$fixture_dir/fake-tool" xcodebuild -- 2>&1)"
status=$?
set -e
[[ "$status" -eq 2 ]] || { echo "Invalid HOME did not fail closed." >&2; exit 1; }
[[ "$invalid_output" == 'Safe Apple build configuration is invalid.' ]] || {
  echo "Invalid configuration emitted unexpected output." >&2
  exit 1
}

set +e
env HOME="$test_home" TMPDIR=relative-tmp MY_ART_COLLECTION_SAFE_APPLE_BUILD_TEST=1 \
  "$wrapper" --test-only-executable "$fixture_dir/fake-tool" xcodebuild -- >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || { echo "Invalid TMPDIR did not fail closed." >&2; exit 1; }

set +e
env HOME="$test_home" TMPDIR="$test_tmp" MY_ART_COLLECTION_SAFE_APPLE_BUILD_TEST=1 \
  "$wrapper" --developer-dir "$fixture_dir/missing-developer" \
  --test-only-executable "$fixture_dir/fake-tool" xcodebuild -- >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || { echo "Invalid developer directory did not fail closed." >&2; exit 1; }

set +e
env HOME="$test_home" TMPDIR="$test_tmp" \
  "$wrapper" --test-only-executable "$fixture_dir/fake-tool" xcodebuild -- >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || { echo "Test-only override worked without its explicit switch." >&2; exit 1; }

echo "Safe Apple build wrapper regression tests passed."
