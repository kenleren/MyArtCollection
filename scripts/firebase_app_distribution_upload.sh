#!/usr/bin/env bash
set -euo pipefail

APK_PATH="${APK_PATH:-build/app/outputs/flutter-apk/app-debug.apk}"
FIREBASE_GROUPS="${FIREBASE_GROUPS:-internal-testers}"
RELEASE_NOTES_FILE="${RELEASE_NOTES_FILE:-}"

usage() {
  cat <<'USAGE'
Upload an Android APK to Firebase App Distribution.

Required environment:
  FIREBASE_APP_ID       Firebase Android app id, not the Android package id.

Optional environment:
  APK_PATH              Defaults to build/app/outputs/flutter-apk/app-debug.apk
  FIREBASE_GROUPS       Defaults to internal-testers
  RELEASE_NOTES_FILE    Path to release notes file

Authentication:
  Use `firebase login` locally or set GOOGLE_APPLICATION_CREDENTIALS to a
  service-account JSON path outside the repository.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ -z "${FIREBASE_APP_ID:-}" ]]; then
  echo "Missing FIREBASE_APP_ID. This is the Firebase Android app id." >&2
  usage >&2
  exit 2
fi

if [[ ! -f "$APK_PATH" ]]; then
  echo "APK not found at $APK_PATH. Run: flutter build apk --debug" >&2
  exit 3
fi

if ! command -v firebase >/dev/null 2>&1; then
  echo "Firebase CLI not found. Install with: npm install -g firebase-tools" >&2
  exit 4
fi

args=(
  appdistribution:distribute "$APK_PATH"
  --app "$FIREBASE_APP_ID"
  --groups "$FIREBASE_GROUPS"
)

if [[ -n "$RELEASE_NOTES_FILE" ]]; then
  if [[ ! -f "$RELEASE_NOTES_FILE" ]]; then
    echo "Release notes file not found at $RELEASE_NOTES_FILE." >&2
    exit 5
  fi
  args+=(--release-notes-file "$RELEASE_NOTES_FILE")
fi

firebase "${args[@]}"
