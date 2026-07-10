#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repo_root/scripts/verify_gradle_wrapper.sh"
temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

mkdir -p "$temporary_root/android/gradle/wrapper"
cp "$repo_root/android/gradle/wrapper/gradle-wrapper.properties" "$temporary_root/android/gradle/wrapper/"
cp "$repo_root/android/gradle/wrapper/gradle-wrapper.jar" "$temporary_root/android/gradle/wrapper/"

bash "$validator" "$temporary_root" >/dev/null

printf 'x' >> "$temporary_root/android/gradle/wrapper/gradle-wrapper.jar"
if bash "$validator" "$temporary_root" >/dev/null 2>&1; then
  echo "Gradle wrapper validator accepted a modified JAR" >&2
  exit 1
fi
cp "$repo_root/android/gradle/wrapper/gradle-wrapper.jar" "$temporary_root/android/gradle/wrapper/gradle-wrapper.jar"

sed -i.bak 's/^distributionSha256Sum=.*/distributionSha256Sum=0000000000000000000000000000000000000000000000000000000000000000/' \
  "$temporary_root/android/gradle/wrapper/gradle-wrapper.properties"
if bash "$validator" "$temporary_root" >/dev/null 2>&1; then
  echo "Gradle wrapper validator accepted a changed distribution checksum" >&2
  exit 1
fi
cp "$repo_root/android/gradle/wrapper/gradle-wrapper.properties" \
  "$temporary_root/android/gradle/wrapper/gradle-wrapper.properties"

printf ' distributionUrl=https\\://attacker.invalid/gradle.zip\n' >> \
  "$temporary_root/android/gradle/wrapper/gradle-wrapper.properties"
if bash "$validator" "$temporary_root" >/dev/null 2>&1; then
  echo "Gradle wrapper validator accepted a whitespace-prefixed duplicate property" >&2
  exit 1
fi

echo "Gradle wrapper negative validation tests passed."
