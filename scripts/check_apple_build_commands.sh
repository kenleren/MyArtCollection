#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: check_apple_build_commands.sh [--root REPOSITORY_ROOT]" >&2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -gt 0 ]]; then
  [[ "$#" -eq 2 && "$1" == "--root" && -d "$2" ]] || { usage; exit 2; }
  repo_root="$(cd "$2" && pwd)"
fi

raw_xcode_pattern='(^|[^[:alnum:]_])xcodebuild([^[:alnum:]_]|$)'
raw_flutter_pattern='(^|[^[:alnum:]_])flutter([[:space:]]+--[^[:space:]]+)*[[:space:]]+build[[:space:]]+ios([^[:alnum:]_]|$)'
test_override_pattern='--test-only-'"executable"
controlled_ci_marker='apple-build-guard: controlled-'"ci"

is_local_allowlist_path() {
  case "$1" in
    scripts/safe_apple_build.sh|scripts/check_apple_build_commands.sh|test/safe_apple_build_test.sh|test/apple_build_command_guard_test.sh)
      return 0
      ;;
  esac
  return 1
}

failed=0
while IFS= read -r -d '' path; do
  file="$repo_root/$path"
  if grep -nE "$controlled_ci_marker" "$file" >/dev/null 2>&1; then
    if ! is_local_allowlist_path "$path" && [[ "$path" != .github/workflows/*.yml && "$path" != .github/workflows/*.yaml ]]; then
      echo "Controlled-CI Apple build marker is only allowed in workflow files: $path" >&2
      failed=1
    fi
  fi

  while IFS=: read -r line_number line; do
    [[ -n "$line_number" ]] || continue
    if is_local_allowlist_path "$path"; then
      continue
    fi
    if [[ "$path" == .github/workflows/*.yml || "$path" == .github/workflows/*.yaml ]]; then
      if [[ "$line" != *"$controlled_ci_marker"* ]]; then
        echo "Unmarked raw Apple build command in workflow: $path:$line_number" >&2
        failed=1
      fi
    else
      echo "Raw Apple build command is not allowed: $path:$line_number" >&2
      failed=1
    fi
  done < <(grep -nE "$raw_xcode_pattern|$raw_flutter_pattern" "$file" || true)

  while IFS=: read -r line_number line; do
    [[ -n "$line_number" ]] || continue
    if ! is_local_allowlist_path "$path"; then
      echo "Test-only Apple build override is not allowed: $path:$line_number" >&2
      failed=1
    fi
  done < <(grep -nE -- "$test_override_pattern" "$file" || true)
done < <(git -C "$repo_root" ls-files -z)

[[ "$failed" -eq 0 ]] || exit 1
echo "Apple build command guard passed."
