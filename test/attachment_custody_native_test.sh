#!/usr/bin/env bash
set -euo pipefail

suite="${ATTACHMENT_CUSTODY_SUITE:-}"
sanitizer="${ATTACHMENT_CUSTODY_SANITIZERS:-none}"
if [[ "$suite" != contract && "$suite" != race ]] || [[ "$sanitizer" != none && "$sanitizer" != address,undefined && "$sanitizer" != thread ]]; then
  echo "CUSTODY_NATIVE_REJECTED" >&2
  exit 1
fi
case "${CXX:-}" in
  g++-13) compiler_token=gxx13 ;;
  clang++) compiler_token=clangxx ;;
  *) echo "CUSTODY_NATIVE_REJECTED" >&2; exit 1 ;;
esac
compiler_path="$(command -v "$CXX" 2>/dev/null || true)"
if [[ -z "$compiler_path" || ! -f "$compiler_path" || ! -x "$compiler_path" ]]; then
  echo "CUSTODY_NATIVE_REJECTED" >&2
  exit 1
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$(mktemp "${TMPDIR:-/tmp}/attachment-custody-harness.XXXXXX")"
output="$(mktemp "${TMPDIR:-/tmp}/attachment-custody-output.XXXXXX")"
status=fail
trap 'rm -f "$binary" "$output"; echo "CUSTODY_NATIVE_RESULT suite=$suite sanitizer=$sanitizer compiler=$compiler_token status=$status"' EXIT

sanitizer_flags=()
if [[ "$sanitizer" == "address,undefined" ]]; then
  sanitizer_flags=(-fsanitize=address,undefined -fno-omit-frame-pointer)
elif [[ "$sanitizer" == "thread" ]]; then
  sanitizer_flags=(-fsanitize=thread -fno-omit-frame-pointer)
fi

"$compiler_path" \
  -std=c++20 \
  -Wall \
  -Wextra \
  -Werror \
  -pthread \
  "${sanitizer_flags[@]}" \
  "$repo_root/android/app/src/test/cpp/AttachmentCustodyHarness.cpp" \
  -o "$binary" >"$output" 2>&1
"$binary" --suite "$suite" >>"$output" 2>&1
status=pass
