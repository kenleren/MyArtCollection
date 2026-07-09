#!/usr/bin/env bash
set -euo pipefail

expected_distribution_url='distributionUrl=https\://services.gradle.org/distributions/gradle-9.1.0-all.zip'
expected_distribution_sha='distributionSha256Sum=b84e04fa845fecba48551f425957641074fcc00a88a84d2aae5808743b35fc85'
expected_properties_sha='17ed114d7d761f47611ec6d952f863576bd178a0c1b6fc5bed910495d0e0c9ad'
expected_wrapper_sha='76805e32c009c0cf0dd5d206bddc9fb22ea42e84db904b764f3047de095493f3'
repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

if [[ "$#" -gt 1 ]]; then
  echo "usage: verify_gradle_wrapper.sh [repository-root]" >&2
  exit 2
fi

properties="$repo_root/android/gradle/wrapper/gradle-wrapper.properties"
wrapper_jar="$repo_root/android/gradle/wrapper/gradle-wrapper.jar"
[[ -f "$properties" ]] || { echo "Gradle wrapper properties are missing" >&2; exit 1; }
[[ -f "$wrapper_jar" ]] || { echo "Gradle wrapper JAR is missing" >&2; exit 1; }

[[ "$(grep -c '^distributionUrl=' "$properties")" -eq 1 ]] || {
  echo "Gradle distribution URL must appear exactly once" >&2
  exit 1
}
grep -Fxq "$expected_distribution_url" "$properties" || {
  echo "Gradle distribution URL does not match the approved Gradle 9.1.0 archive" >&2
  exit 1
}
[[ "$(grep -c '^distributionSha256Sum=' "$properties")" -eq 1 ]] || {
  echo "Gradle distribution checksum must appear exactly once" >&2
  exit 1
}
grep -Fxq "$expected_distribution_sha" "$properties" || {
  echo "Gradle distribution checksum does not match the published Gradle 9.1.0 value" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

actual_properties_sha="$(sha256_file "$properties")"
[[ "$actual_properties_sha" == "$expected_properties_sha" ]] || {
  echo "Gradle wrapper properties differ from the exact approved file" >&2
  exit 1
}

actual_wrapper_sha="$(sha256_file "$wrapper_jar")"
[[ "$actual_wrapper_sha" == "$expected_wrapper_sha" ]] || {
  echo "Tracked Gradle wrapper JAR checksum does not match Gradle 9.1.0" >&2
  exit 1
}

echo "Gradle 9.1.0 distribution and wrapper JAR checksums passed."
