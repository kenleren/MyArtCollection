#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$repo_root/scripts/check_apple_build_commands.sh"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

git -C "$fixture_root" init -q
git -C "$fixture_root" config user.email test@example.invalid
git -C "$fixture_root" config user.name 'Apple build guard test'
mkdir -p "$fixture_root/.github/workflows"

write_fixture() {
  local path="$1"
  local content="$2"
  mkdir -p "$(dirname "$fixture_root/$path")"
  printf '%s\n' "$content" > "$fixture_root/$path"
  git -C "$fixture_root" add "$path"
}

write_fixture safe.sh 'scripts/safe_apple_build.sh flutter-ios-simulator-debug --flutter-bin /tool'
"$guard" --root "$fixture_root"

write_fixture unsafe.sh 'xcodebuild -scheme Runner'
set +e
"$guard" --root "$fixture_root" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || { echo "Guard accepted a raw local xcodebuild command." >&2; exit 1; }
git -C "$fixture_root" rm -q -f unsafe.sh

write_fixture .github/workflows/controlled.yml 'run: flutter build ios --simulator # apple-build-guard: controlled-ci'
"$guard" --root "$fixture_root"

write_fixture .github/workflows/unmarked.yml 'run: flutter build ios --simulator'
set +e
"$guard" --root "$fixture_root" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || { echo "Guard accepted an unmarked workflow command." >&2; exit 1; }
git -C "$fixture_root" rm -q -f .github/workflows/unmarked.yml

write_fixture marker.md 'apple-build-guard: controlled-ci'
set +e
"$guard" --root "$fixture_root" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || { echo "Guard accepted a non-workflow controlled-CI marker." >&2; exit 1; }
git -C "$fixture_root" rm -q -f marker.md

write_fixture override.sh '--test-only-executable /tmp/fake-tool'
set +e
"$guard" --root "$fixture_root" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || { echo "Guard accepted an unconfined test-only override." >&2; exit 1; }

echo "Apple build command guard tests passed."
