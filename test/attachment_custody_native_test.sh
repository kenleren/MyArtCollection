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
result() { printf 'CUSTODY_NATIVE_RESULT suite=%s sanitizer=%s compiler=%s phase=%s class=%s exit=%s status=%s\n' "$suite" "$sanitizer" "$compiler_token" "$1" "$2" "$3" "$4"; }
finish_failure() {
  phase=$1 class=$2 code=$3
  rm -f "$binary" "$output" || :
  result "$phase" "$class" "$code" fail
  exit "$code"
}

compiler_args=(-std=c++20 -Wall -Wextra -Werror -pthread)
if [[ "$sanitizer" == "address,undefined" ]]; then
  compiler_args+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
elif [[ "$sanitizer" == "thread" ]]; then
  compiler_args+=(-fsanitize=thread -fno-omit-frame-pointer)
fi

if "$compiler_path" \
  "${compiler_args[@]}" \
  "$repo_root/android/app/src/test/cpp/AttachmentCustodyHarness.cpp" \
  -o "$binary" >"$output" 2>&1; then :; else finish_failure compile runtime "$?"; fi
if "$binary" --suite "$suite" >>"$output" 2>&1; then :; else
  code=$?
  if [[ "$code" = 64 ]]; then finish_failure execute invalid "$code"; fi
  if [[ "$code" = 65 ]]; then finish_failure execute assertion "$code"; fi
  finish_failure execute runtime "$code"
fi
if rm -f "$binary" "$output"; then result cleanup cleanup 0 pass; else code=$?; result cleanup cleanup "$code" fail; exit "$code"; fi
