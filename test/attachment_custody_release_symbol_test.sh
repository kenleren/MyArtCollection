#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
object="$(mktemp "${TMPDIR:-/tmp}/attachment-custody-release.XXXXXX.o")"
trap 'rm -f "$object"' EXIT

"${CXX:-c++}" \
  -std=c++20 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -c "$repo_root/android/app/src/main/cpp/AttachmentCustody.cpp" \
  -o "$object"

for artifact in "$object" "$@"; do
  if strings "$artifact" | grep -Eq \
      'AttachmentCustodyTestNative|test_crash_at|test_fail_at|test_at_boundary|test_reset_hooks'; then
    echo "attachment custody test hook leaked into release artifact: $artifact" >&2
    exit 1
  fi
done
