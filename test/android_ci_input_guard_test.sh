#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$repo_root/scripts/check_android_ci_inputs.sh"
clean_environment=(env -i PATH="$PATH" HOME="${HOME:-/tmp}" CI=true)

"${clean_environment[@]}" bash "$guard" >/dev/null

protected_inputs=()
while IFS= read -r name; do
  protected_inputs+=("$name")
done < <(bash "$guard" --list)
for required in \
  MY_ART_COLLECTION_FIREBASE_ANDROID \
  MY_ART_COLLECTION_BROKER_CLIENT \
  MY_ART_COLLECTION_INTERNAL_BETA_CRASHLYTICS \
  MY_ART_COLLECTION_REMOTE_CONFIG \
  GOOGLE_APPLICATION_CREDENTIALS \
  OPENAI_API_KEY \
  ARCHIVALE_OPENAI_API_KEY \
  ANTHROPIC_API_KEY \
  GOOGLE_API_KEY \
  GEMINI_API_KEY \
  MY_ART_COLLECTION_ANDROID_RELEASE_STORE_FILE \
  MY_ART_COLLECTION_ANDROID_RELEASE_STORE_PASSWORD \
  MY_ART_COLLECTION_ANDROID_RELEASE_KEY_ALIAS \
  MY_ART_COLLECTION_ANDROID_RELEASE_KEY_PASSWORD; do
  printf '%s\n' "${protected_inputs[@]}" | grep -Fxq "$required"
done

for name in "${protected_inputs[@]}"; do
  if "${clean_environment[@]}" "$name=fixture-value" bash "$guard" >/dev/null 2>&1; then
    echo "Android protected-input preflight accepted $name" >&2
    exit 1
  fi
done

echo "Android protected-input negative tests passed for ${#protected_inputs[@]} inputs."
