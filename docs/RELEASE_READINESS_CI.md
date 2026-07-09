# Release Readiness CI

`.github/workflows/release-readiness.yml` is the single deterministic release
readiness workflow. It runs for every pull request, every push to `main`, and
manual dispatch. It has no path filters. Its stable aggregate check is named
`Release readiness`; the repository owner may configure that exact check as the
required branch-protection status after independent task and security review.

## Included checks

- actionlint, installed from actionlint 1.7.12 after checksum verification;
- Flutter 3.44.4 / Dart 3.12.2 formatting, analysis, and tests;
- a debug-only Android APK build with Temurin 17.0.19+10;
- broker and forms dependency installs, builds, tests, and broker audit policy;
- static-site validation;
- mobile broker-bypass guard and its negative fixtures; and
- a full-history, redacted Gitleaks scan plus repository secret-path guard.

The final `Release readiness` job always runs and fails unless each listed job
reports `success`. It is the only check name intended for required branch
protection; existing workflow job names are implementation evidence, not a
branch-protection contract.

## Reproducibility and cache boundary

All GitHub Actions are pinned to immutable commits. Flutter, Gitleaks, and
actionlint are downloaded at fixed versions and verified against checked-in
SHA-256 values. Node is pinned to 22.23.1 and Java to Temurin 17.0.19+10.

The only caches are dependency-download directories: `~/.pub-cache` and
`~/.npm`, keyed by their lockfiles. The workflow never caches the repository,
build outputs, Android Gradle workspace, `.env*`, Firebase configuration or
tokens, service accounts, signing files, keystores, or provisioning material.

## Debug package boundary

The Android evidence is exactly `flutter build apk --debug --no-pub`. The job
rejects protected Firebase, Crashlytics, Remote Config, provider, and release
signing environment variables before building. It supplies no Dart defines,
credentials, release signing, deploy action, artifact upload, Firebase CLI
command, or provider call.

## Broker audit exception

`scripts/check_broker_audit.mjs` is fail-closed. Until **2026-08-31**, it
accepts only moderate `GHSA-w5hq-g745-h8pq` in the current broker lock graph,
with `uuid@9.0.1`, through exactly these paths:

1. `firebase-admin > @google-cloud/firestore > google-gax > uuid`
2. `firebase-admin > @google-cloud/storage > gaxios > uuid`
3. `firebase-admin > @google-cloud/storage > teeny-request > uuid`

The related npm audit entries that lead into those paths (`firebase-functions`
and `retry-request`) are enumerated in the parser policy. A new advisory,
unknown dependency, changed UUID lock state, altered approved path, severity
other than moderate, malformed audit output, audit-command failure, or expiry
fails the workflow. The parser fixtures under `test/fixtures/broker-audit/`
cover the accepted case and those rejection modes.

This exception is a review reminder, not a risk acceptance for deployment.
Updating or removing it needs a separately reviewed lockfile and policy change.
