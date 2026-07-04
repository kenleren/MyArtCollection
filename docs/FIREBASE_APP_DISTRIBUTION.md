# Firebase App Distribution

Firebase App Distribution is the beta delivery layer for Android tester APKs.
It does not change MyArtCollection's local-first artwork storage model and does
not imply Firebase Auth, Firestore, Storage, Analytics, Performance Monitoring,
or other Firebase data products. Crashlytics is allowed only for Android
internal beta crash triage when explicitly enabled as described below.

Telemetry guardrails for Crashlytics, Remote Config, Analytics, and Performance
Monitoring are documented in
[Firebase Telemetry Privacy Policy](FIREBASE_TELEMETRY_POLICY.md).

## Android App

- Android package id: `com.kenleren.my_art_collection`
- Debug APK path: `build/app/outputs/flutter-apk/app-debug.apk`
- Debug build command, with Crashlytics off:

```sh
flutter build apk --debug
```

- Internal beta build command, with Crashlytics on only for this release-style
  build:

```sh
MY_ART_COLLECTION_FIREBASE_ANDROID=true \
flutter build apk --release \
  --dart-define=MY_ART_COLLECTION_FIREBASE_ANDROID=true \
  --dart-define=MY_ART_COLLECTION_INTERNAL_BETA_CRASHLYTICS=true
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
6. Download the Android `google-services.json` and place it only at
   `android/app/google-services.json` on the local machine that performs the
   internal beta build.

Do not commit `google-services.json`, service-account JSON, Firebase tokens, or
tester email lists.

See [Secret Hygiene](SECRET_HYGIENE.md) for the repository guardrail, ignored
legacy `/google/` boundary, and Firebase service-account rotation gate.

The Android Gradle Firebase plugins are applied only when the Gradle environment
has `MY_ART_COLLECTION_FIREBASE_ANDROID=true`. Crashlytics runtime collection
also requires `--dart-define=MY_ART_COLLECTION_FIREBASE_ANDROID=true` and
`--dart-define=MY_ART_COLLECTION_INTERNAL_BETA_CRASHLYTICS=true`. That paired
opt-in path requires `android/app/google-services.json`. Debug/local builds do
not read or use that file and keep Crashlytics collection disabled by default.

## Crashlytics Internal Beta

Crashlytics collection is controlled by both platform defaults and runtime
configuration:

- `android/app/src/main/AndroidManifest.xml` sets
  `firebase_crashlytics_collection_enabled=false`.
- `lib/app/telemetry/crash_telemetry.dart` initializes Firebase and enables
  Crashlytics only on Android release builds with both
  `MY_ART_COLLECTION_FIREBASE_ANDROID=true` and
  `MY_ART_COLLECTION_INTERNAL_BETA_CRASHLYTICS=true` Dart defines.
- Flutter framework, platform dispatcher, and zone errors route only through the
  app-owned sanitized facade.
- The facade sends fixed categories only. It does not send artwork titles,
  artist names, filenames, file paths, notes, prompts, research queries, source
  URLs, tester emails, Firebase tokens, or custom Crashlytics logs/keys.

Human verification for #39 requires a local Android Firebase config, a device or
emulator run, and Firebase console access. Evidence must be sanitized:

- branch and commit hash
- Android build mode and Dart define used
- confirmation that debug/local collection stayed off by default
- confirmation that a deliberate internal beta crash appeared in Crashlytics
- Firebase console timestamp or issue id, without tester emails, credential
  paths, raw exception messages, filenames, artwork metadata, or screenshots
  containing private collection data

Do not claim real Crashlytics console evidence from repository checks alone.

To force exactly one internal beta setup crash for human verification, use both
Crashlytics build gates plus the one-off test-crash define:

```sh
MY_ART_COLLECTION_FIREBASE_ANDROID=true \
flutter run --release \
  --dart-define=MY_ART_COLLECTION_FIREBASE_ANDROID=true \
  --dart-define=MY_ART_COLLECTION_INTERNAL_BETA_CRASHLYTICS=true \
  --dart-define=MY_ART_COLLECTION_CRASHLYTICS_TEST_CRASH=true
```

Restart the app after the crash so Crashlytics can upload the report. Do not
ship or upload a build with `MY_ART_COLLECTION_CRASHLYTICS_TEST_CRASH=true`.

## Upload

Install the Firebase CLI if needed:

```sh
npm install -g firebase-tools
```

Build and upload:

```sh
MY_ART_COLLECTION_FIREBASE_ANDROID=true \
flutter build apk --release \
  --dart-define=MY_ART_COLLECTION_FIREBASE_ANDROID=true \
  --dart-define=MY_ART_COLLECTION_INTERNAL_BETA_CRASHLYTICS=true

FIREBASE_APP_ID="1:example:android:example" \
APK_PATH="build/app/outputs/flutter-apk/app-release.apk" \
FIREBASE_GROUPS="internal-testers" \
RELEASE_NOTES_FILE="release-notes/internal-testers.md" \
scripts/firebase_app_distribution_upload.sh
```

The script fails before upload when `FIREBASE_APP_ID` or `APK_PATH` is missing,
the APK is missing, or the Firebase CLI is unavailable. It does not default to a
debug APK; pass the exact artifact intended for the tester release.

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

To remove Crashlytics from an internal beta path:

1. Build without `MY_ART_COLLECTION_INTERNAL_BETA_CRASHLYTICS=true`.
2. Remove the local `android/app/google-services.json` when Firebase is not
   needed for the build.
3. Confirm `flutter build apk --debug`, `flutter analyze`, and `flutter test`
   still pass.
4. Record that Crashlytics collection is off by default and that no Firebase
   console evidence is expected from local/debug builds.

## Current Gate

This repository can prepare and validate the APK and upload command safely.
A real Firebase upload still requires configured Firebase project access,
credentials outside the repository, and explicit release evidence.
