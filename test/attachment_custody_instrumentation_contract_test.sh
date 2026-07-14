#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harness="$repo_root/android/app/src/androidTest/kotlin/app/archivale/AttachmentCustodyInstrumentationTest.kt"
old_harness_fixture="$(mktemp "${TMPDIR:-/tmp}/attachment-custody-old-harness.XXXXXX")"
trap 'rm -f "$old_harness_fixture"' EXIT

extract_intermediate_race() {
  awk '
    /^    private fun runIntermediateRace\(/ { in_race = 1 }
    in_race && /^    private fun call\(/ { exit }
    in_race { print }
  ' "$1"
}

validate_intermediate_race() {
  local source="$1"
  local race
  race="$(extract_intermediate_race "$source")"

  [[ -n "$race" ]] || {
    echo "Android custody harness is missing runIntermediateRace." >&2
    return 1
  }
  grep -Fq 'val outsidePayload = File(outside, "payload.pdf").apply {' <<<"$race" || {
    echo "Intermediate race must name the exact redirected outside payload." >&2
    return 1
  }
  grep -Fq 'val expectedOutsidePayload = fingerprint(outsidePayload)' <<<"$race" || {
    echo "Intermediate race must fingerprint the exact redirected outside payload." >&2
    return 1
  }
  [[ "$(grep -Fc 'expectedOutsidePayload,' <<<"$race")" -eq 2 ]] || {
    echo "Intermediate race must check the expected outside payload fingerprint per attempt and post-join." >&2
    return 1
  }
  [[ "$(grep -Fc 'outsidePayload,' <<<"$race")" -eq 2 ]] || {
    echo "Intermediate race must check the exact outside payload path per attempt and post-join." >&2
    return 1
  }
  if grep -Fqi 'sentinel' <<<"$race"; then
    echo "Intermediate race must not use an unrelated sentinel in place of the redirected payload." >&2
    return 1
  fi
  grep -Fq 'check(file.exists()) { "$message: exact target does not exist" }' "$source" || {
    echo "Outside-target fingerprint checks must explicitly require path existence." >&2
    return 1
  }
  grep -Fq 'requireEquals(expected, fingerprint(file), message)' "$source" || {
    echo "Outside-target checks must compare identity, bytes, and SHA-256 through Fingerprint." >&2
    return 1
  }
}

cat >"$old_harness_fixture" <<'EOF'
    private fun runIntermediateRace(
        parent: File,
        sentinel: File,
        expected: Fingerprint,
        iteration: Int,
    ) {
        val outside = File(parent, "outside-directory-$iteration").apply { mkdirs() }
        File(outside, "payload.pdf").writeText("outside-replacement-$iteration")
        repeat(RACE_ATTEMPTS) {
            requireEquals(expected, fingerprint(sentinel), "changed sentinel")
        }
        requireEquals(expected, fingerprint(sentinel), "changed sentinel after join")
    }

    private fun call(
EOF

if validate_intermediate_race "$old_harness_fixture" >/dev/null 2>&1; then
  echo "Android custody harness guard accepted the old unrelated-sentinel false-pass pattern." >&2
  exit 1
fi

validate_intermediate_race "$harness"
echo "Android custody instrumentation exact-payload contract passed."
