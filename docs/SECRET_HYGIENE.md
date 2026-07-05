# Secret Hygiene

This repository treats Firebase credentials, Android release-signing material,
tester lists, and local debug output as non-source artifacts. They must stay
out of Git history and out of pull request logs.

## Firebase Credential Rules

- Prefer an out-of-repository service-account JSON path for automation:
  `GOOGLE_APPLICATION_CREDENTIALS=/path/outside/repo/service-account.json`.
- Local developer environment values may live in `.env.local`, which is
  ignored by Git. Keep `.env.local.example` as the tracked template and never
  paste real values into commits, issue comments, screenshots, or logs.
- The legacy local `/google/` directory remains ignored only as a compatibility
  boundary. Do not inspect it, validate it, move it, or commit anything from it.
- Do not commit service-account JSON, `google-services.json`,
  `GoogleService-Info.plist`, Firebase tokens, tester email lists, or
  `firebase-debug.log`.
- Do not paste credential values into issue comments, release notes, CI logs,
  screenshots, or scanner baselines.

## Android Release Signing Rules

- Keep Android release-signing inputs outside tracked source control. The
  supported Phase 1 contract is exactly one of:
  - ignored `android/key.properties`
  - `MY_ART_COLLECTION_ANDROID_RELEASE_*` Gradle properties
  - `MY_ART_COLLECTION_ANDROID_RELEASE_*` environment variables
  Do not mix sources inside one release build. If both Gradle properties and
  environment variables are present for the same key with different values, the
  Android release build fails closed.
- Do not commit, print, validate, move, screenshot, or paste keystores, upload
  keys, signing passwords, aliases, or secret-bearing property files.
- Do not expose secret file paths, `storeFile` values, full signing commands
  with inline secrets, or CI variable values in issue comments, docs, PR text,
  screenshots, or logs.
- Sanitized evidence may name the contract only at the level of:
  `android/key.properties`, `MY_ART_COLLECTION_ANDROID_RELEASE_*`, build type,
  artifact type (`APK` or `AAB`), branch, commit, version, and pass/fail
  outcome.
- Real signed-artifact verification remains a Phase 2 owner-run step until the
  upload-key strategy, secret storage owner, alias contract, and first signed
  build operator are explicitly decided.

## Secret Scan

Run the repository guardrail before pushing Firebase, release-signing, or
release-process changes:

```sh
scripts/secret_scan.sh
```

The wrapper first blocks tracked Firebase credential/config paths and tracked
Android signing paths such as `android/key.properties`, `*.keystore`, and
`*.jks`. It then blocks tracked signing credential assignments before running
Gitleaks with `.gitleaks.toml` and full redaction enabled. If Gitleaks is not
installed, the wrapper fails closed with install guidance instead of silently
skipping the scan.

The GitHub Actions `Secret Scan` workflow installs the pinned Gitleaks release,
verifies the release archive checksum, and runs the same wrapper against full
Git history.

## Rotation Gate

If a Firebase Admin service-account key was ever committed, placed under the
repository, shared outside the owner machine, or cannot be proven to have stayed
local-only, the owner must rotate/revoke that key in Firebase or Google Cloud
before using it for automation. Agents may record this gate and the owner's
decision, but must not delete, revoke, rotate, display, or validate Firebase
credentials.
