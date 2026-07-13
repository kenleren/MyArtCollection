#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$(mktemp "${TMPDIR:-/tmp}/attachment-custody-harness.XXXXXX")"
trap 'rm -f "$binary"' EXIT

"${CXX:-c++}" \
  -std=c++20 \
  -Wall \
  -Wextra \
  -Werror \
  -pthread \
  "$repo_root/android/app/src/test/cpp/AttachmentCustodyHarness.cpp" \
  -o "$binary"
"$binary"
