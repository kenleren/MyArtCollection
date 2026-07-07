#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel)"
cd "$repo_root"

forbidden_path_pattern='(^|/)(android/key\.properties|google-services\.json|GoogleService-Info\.plist|firebase-debug\.log|[^/]*service[_.-]?account[^/]*\.json|[^/]*firebase-adminsdk[^/]*\.json|[^/]*firebase[^/]*token[^/]*|[^/]*tester[^/]*(list|email)[^/]*|[^/]*(list|email)[^/]*tester[^/]*|[^/]*\.(keystore|jks)(\.[^/]*)?)$'
tracked_forbidden_paths="$(git ls-files | grep -Ei "$forbidden_path_pattern" || true)"

if [[ -n "$tracked_forbidden_paths" ]]; then
  {
    echo "Tracked Firebase or Android release-signing secret paths are not allowed."
    echo "Remove these paths from git and rotate/revoke any exposed credentials before retrying:"
    printf '%s\n' "$tracked_forbidden_paths"
  } >&2
  exit 10
fi

signing_content_pattern='(^|[[:space:]"'"'"'])((storePassword|keyPassword|storeFile|keyAlias)[[:space:]]*[:=][[:space:]]*["'"'"']?[^[:space:]#"'"'"'$][^#]*|(MY_ART_COLLECTION_ANDROID_RELEASE_(STORE_FILE|STORE_PASSWORD|KEY_ALIAS|KEY_PASSWORD))[[:space:]]*=[[:space:]]*["'"'"']?[^[:space:]#"'"'"'$][^#]*)'
tracked_signing_content="$(
  git grep -nIE "$signing_content_pattern" -- \
    '*.properties' \
    '*.gradle' \
    '*.gradle.kts' \
    '*.sh' \
    '*.md' \
    '.env' \
    '.env.*' \
    '*.yaml' \
    '*.yml' \
    ':(exclude).gitleaks.toml' \
    ':(exclude)scripts/secret_scan.sh' \
    ':(exclude)android/app/build.gradle.kts' || true
)"

if [[ -n "$tracked_signing_content" ]]; then
  {
    echo "Tracked Android release-signing credential content is not allowed."
    echo "Keep signing values only in ignored android/key.properties or approved external secret stores:"
    printf '%s\n' "$tracked_signing_content"
  } >&2
  exit 11
fi

if ! command -v gitleaks >/dev/null 2>&1; then
  cat >&2 <<'USAGE'
gitleaks is required for the repository secret scan and was not found on PATH.

Install one of the official distributions, then retry:
  macOS/Homebrew: brew install gitleaks
  Docker:         docker pull ghcr.io/gitleaks/gitleaks:latest
  Releases:       https://github.com/gitleaks/gitleaks/releases

CI installs the pinned Gitleaks version before running this wrapper.
USAGE
  exit 127
fi

gitleaks git \
  --config "$repo_root/.gitleaks.toml" \
  --redact=100 \
  --no-banner \
  --no-color \
  --verbose \
  "$repo_root"
