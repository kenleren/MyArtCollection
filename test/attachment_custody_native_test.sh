#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$(mktemp "${TMPDIR:-/tmp}/attachment-custody-harness.XXXXXX")"
trap 'rm -f "$binary"' EXIT

sanitizer_flags=()
if [[ "${ATTACHMENT_CUSTODY_SANITIZERS:-}" == "address,undefined" ]]; then
  sanitizer_flags=(-fsanitize=address,undefined -fno-omit-frame-pointer)
elif [[ "${ATTACHMENT_CUSTODY_SANITIZERS:-}" == "thread" ]]; then
  sanitizer_flags=(-fsanitize=thread -fno-omit-frame-pointer)
fi

"${CXX:-c++}" \
  -std=c++20 \
  -Wall \
  -Wextra \
  -Werror \
  -pthread \
  "${sanitizer_flags[@]}" \
  "$repo_root/android/app/src/test/cpp/AttachmentCustodyHarness.cpp" \
  -o "$binary"
"$binary"
