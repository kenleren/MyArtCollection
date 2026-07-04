#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel)"
cd "$repo_root"

forbidden_path_pattern='(^|/)(google-services\.json|GoogleService-Info\.plist|firebase-debug\.log|[^/]*service[_.-]?account[^/]*\.json|[^/]*firebase-adminsdk[^/]*\.json|[^/]*firebase[^/]*token[^/]*|[^/]*tester[^/]*(list|email)[^/]*|[^/]*(list|email)[^/]*tester[^/]*)$'
tracked_forbidden_paths="$(git ls-files | grep -Ei "$forbidden_path_pattern" || true)"

if [[ -n "$tracked_forbidden_paths" ]]; then
  {
    echo "Tracked Firebase credential, token, tester-list, or debug-log paths are not allowed."
    echo "Remove these paths from git and rotate/revoke any exposed credentials before retrying:"
    printf '%s\n' "$tracked_forbidden_paths"
  } >&2
  exit 10
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
