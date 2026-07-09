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
- broker and forms dependency installs, builds, tests, a clean forms audit, and
  the broker audit policy;
- static-site validation with Python 3.12.13;
- mobile broker-bypass guard and its negative fixtures; and
- a full-history, redacted Gitleaks scan plus repository secret-path guard.

The final `Release readiness` job always runs and fails unless each listed job
reports `success`. It is the only check name intended for required branch
protection; existing workflow job names are implementation evidence, not a
branch-protection contract.

## Reproducibility and cache boundary

All GitHub Actions are pinned to immutable commits. Flutter, Gitleaks, and
actionlint are downloaded at fixed versions and verified against checked-in
SHA-256 values. Node is pinned to 22.23.1, Java to Temurin 17.0.19+10, and
Python to 3.12.13 through an immutable `actions/setup-python` commit.

The only caches are dependency-download directories: `~/.pub-cache` and
`~/.npm`, keyed by their lockfiles. The workflow never caches the repository,
build outputs, Android Gradle workspace, `.env*`, Firebase configuration or
tokens, service accounts, signing files, keystores, or provisioning material.
The broker audit uses an isolated temporary npm cache so stale audit metadata
cannot alter the graph input; that cache is not persisted.

## Debug package boundary

The Android evidence is exactly `flutter build apk --debug --no-pub`. The job
rejects protected Firebase, Crashlytics, Remote Config, provider, and release
signing environment variables before building. It supplies no Dart defines,
credentials, release signing, deploy action, artifact upload, Firebase CLI
command, or provider call.

## Broker audit exception

`scripts/check_broker_audit.mjs` is fail-closed. Until **2026-08-31**, it
accepts only moderate `GHSA-w5hq-g745-h8pq` in the current broker audit graph.
The policy compares every audit `via` edge and every vulnerable lock edge. The
complete approved paths from `firebase-admin` to the locked `uuid@9.0.1` are:

1. `firebase-admin > @google-cloud/firestore > google-gax > uuid`
2. `firebase-admin > @google-cloud/firestore > google-gax > retry-request > teeny-request > uuid`
3. `firebase-admin > @google-cloud/storage > gaxios > uuid`
4. `firebase-admin > @google-cloud/storage > retry-request > teeny-request > uuid`
5. `firebase-admin > @google-cloud/storage > teeny-request > uuid`

The forms package has no exception: any npm audit finding fails CI. For the
broker, a new advisory, extra or rerouted audit edge, changed UUID lock state,
extra or rerouted vulnerable lock edge, severity other than moderate, malformed
audit output, audit-command failure, or expiry fails the workflow. Parser
fixtures under `test/fixtures/broker-audit/` cover the accepted graph and each
negative mode, including an injected post-expiry date so expiry evidence is
deterministic.

The broker check canonicalizes one npm presentation detail: the result may
include only the exact `firebase-functions > firebase-admin` peer-
metavulnerability edge in addition to the eight-node path graph. npm emits that
derived edge inconsistently across bundled npm versions even when the lockfile
and advisory paths are unchanged. After removing that exact edge, the package
set and every remaining edge must match exactly; any variation fails.

This exception is a review reminder, not a risk acceptance for deployment.
Updating or removing it needs a separately reviewed lockfile and policy change.
