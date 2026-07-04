# Firebase App Distribution

Firebase App Distribution is the beta delivery layer for Android tester APKs.
It does not change MyArtCollection's local-first artwork storage model and does
not imply Firebase Auth, Firestore, Storage, Analytics, or Crashlytics.

Telemetry guardrails for Crashlytics, Remote Config, Analytics, and Performance
Monitoring are documented in
[Firebase Telemetry Privacy Policy](FIREBASE_TELEMETRY_POLICY.md).

## Android App

- Android package id: `com.kenleren.my_art_collection`
- Debug APK path: `build/app/outputs/flutter-apk/app-debug.apk`
- Build command:

```sh
flutter build apk --debug
```

## One-Time Firebase Setup

1. Create or choose a Firebase project.
2. Add an Android app with package id `com.kenleren.my_art_collection`.
3. Copy the Firebase Android app id from Project settings. It usually starts
   with `1:` and is not the Android package id.
4. Create a tester group such as `internal-testers`.
5. Keep Firebase credentials outside the repository:
   - local use: `firebase login`
   - automation use: `GOOGLE_APPLICATION_CREDENTIALS=/path/outside/repo/service-account.json`

Do not commit `google-services.json`, service-account JSON, Firebase tokens, or
tester email lists.

## Upload

Install the Firebase CLI if needed:

```sh
npm install -g firebase-tools
```

Build and upload:

```sh
flutter build apk --debug
FIREBASE_APP_ID="1:example:android:example" \
FIREBASE_GROUPS="internal-testers" \
RELEASE_NOTES_FILE="release-notes/internal-testers.md" \
scripts/firebase_app_distribution_upload.sh
```

The script fails before upload when `FIREBASE_APP_ID` is missing, the APK is
missing, or the Firebase CLI is unavailable.

## Release Evidence

Record these on the linked Project issue for each real upload:

- branch and commit hash
- APK path and app version/build
- Firebase Android app id, redacted only if required by policy
- tester group
- release notes file or summary
- Firebase release id or console link
- install verification result from at least one tester/device

## Revoke / Rollback

For a bad beta build:

1. Disable or delete the affected release in Firebase App Distribution.
2. Upload the previous known-good APK with clear release notes.
3. Notify the tester group which build to install.
4. Record the revoked release id, replacement release id, and verification
   result on the linked Project issue.

## Current Gate

This repository can prepare and validate the APK and upload command safely.
A real Firebase upload still requires configured Firebase project access,
credentials outside the repository, and explicit release evidence.
