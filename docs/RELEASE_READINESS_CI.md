# Release Readiness CI

`.github/workflows/release-readiness.yml` is the single deterministic release
readiness workflow. It runs for every pull request, every push to `main`, and
manual dispatch. It has no path filters. Its stable aggregate check is named
`Release readiness`. Requiring that status is only one part of the owner-owned
ruleset handoff described below; this change does not mutate repository rules.

## Included checks

- actionlint 1.7.12, run from the maintainer-published OCI image pinned by
  immutable digest (`rhysd/actionlint@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667`);
- Flutter 3.44.4 / Dart 3.12.2 formatting, analysis, and tests;
- a debug-only Android APK build with Temurin 17.0.19+10 after protected-input,
  checksum-pinned Gradle wrapper, native attachment policy, and focused Android
  JVM boundary validation;
- broker and forms dependency installs, builds, tests, a clean forms audit, and
  the broker audit policy;
- the credential-free release-policy trust package build, synthetic
  conformance, frozen inventory/history, external-manifest, CODEOWNERS, audit,
  exact event-range anchors, final-summary digest verification, and
  reproducibility byte-regeneration gates; trust-source changes additionally
  require complete candidate-inventory byte regeneration while unrelated
  changes retain the anchored unchanged-source path;
- static-site validation with Python 3.12.13;
- mobile broker-bypass guard and its negative fixtures; and
- safe Apple build wrapper regressions and the tracked raw-command guard; and
- a full-history, redacted Gitleaks scan plus repository secret-path guard.

The final `Release readiness` job always runs and fails unless each listed job
reports `success`. It is the only check name intended for required branch
protection; existing workflow job names are implementation evidence, not a
branch-protection contract.

Flutter test files run with one worker because several existing suites mutate
process-global Flutter/database test state. Serial execution keeps the hosted
result deterministic while still running every test.
The Linux runner maps Roboto and Material Icons from the checksum-verified
Flutter SDK to the macOS-compatible paths used by the existing screenshot test
harness, keeping text metrics and lazy-list visibility consistent across hosts.

The release-policy trust job is source evidence only. It uses no App secret,
private key, installation token, provider, host, store, queue, live Check Run,
repository setting, or ruleset mutation. Its passing result does not mean the
dedicated external App is deployed or that its distinct check is required.
That operational boundary is documented in
[Release policy trust](RELEASE_POLICY_TRUST.md).

## Immutable Workers evidence candidate

The backend job checks out and validates one immutable candidate commit before
running package commands. Pull requests use the event's `pull_request.head.sha`;
push and manual-dispatch runs use their captured `github.sha`. The synthetic
pull-request merge, branch names, remote refs, and later ref resolution are not
candidate authority. The checked-out commit must equal that event-derived OID,
have exactly one fetched parent, and produce the immutable artifact anchor used
by SPDX generation, SPDX verification, and artifact verification. This prevents
the pull-request merge's first parent from silently replacing the reviewed
candidate. A push or manual event whose immutable commit is not a direct
candidate/evidence pair fails closed; post-merge evidence needs its own reviewed
contract.

## Reproducibility and cache boundary

All GitHub Actions are pinned to immutable commits. Checkout 7.0.0, cache
6.1.0, setup-node 6.4.0, setup-java 5.5.0, and setup-python 6 use their native
Node 24 runtimes. Flutter and Gitleaks are downloaded at fixed
versions and verified against checked-in SHA-256 values. Node is pinned to
22.23.1, Java to Temurin 17.0.19+10, and Python to 3.12.13 through immutable
action commits.

Gradle is pinned to 9.1.0. `distributionSha256Sum` verifies the official
`-all.zip` checksum
`b84e04fa845fecba48551f425957641074fcc00a88a84d2aae5808743b35fc85`.
Before any Gradle execution, `scripts/verify_gradle_wrapper.sh` also verifies
the tracked Gradle 9.1.0 wrapper JAR against Gradle's published checksum
`76805e32c009c0cf0dd5d206bddc9fb22ea42e84db904b764f3047de095493f3`.
It hashes the exact wrapper properties file so alternate or duplicate Java
properties cannot reroute the distribution. Negative tests prove a modified
JAR, distribution checksum, or whitespace-prefixed duplicate property fails.

The only caches are dependency-download directories: `~/.pub-cache` and npm's
`~/.npm/_cacache`, keyed by their lockfiles. npm `_logs` and every sibling of
`_cacache` remain outside the cache boundary. The workflow never caches the
repository, build outputs, Android Gradle workspace, `.env*`, Firebase
configuration or tokens, service accounts, signing files, keystores, or
provisioning material.
The full and peer-omitted broker audits use separate isolated temporary npm
caches so stale audit metadata cannot alter or couple their graph inputs; the
forms audit also uses an isolated temporary cache. No audit cache is persisted.
Every checkout uses
`persist-credentials: false`, and CI verifies that checkout leaves no local git
credential configuration without printing any credential value.

Before `poppler-utils` installation, CI records the apt metadata response,
simulates the no-recommends closure, downloads into an empty archive directory,
and compares exact package/version/architecture coordinates. It hashes every
`.deb` before using `--no-download` to install the already verified closure.
The simulation, expected closure, observed closure, and archive evidence are
themselves hashed before installation. Broker audit response files are likewise
hashed before the audit policy consumes them.
These runtime observations are evidence-only and never promote mutable apt
metadata or packages to a predeclared trusted input.

## Debug package boundary

The Android evidence is exactly `flutter build apk --debug --no-pub`. Before
dependency or build execution, `scripts/check_android_ci_inputs.sh` rejects the
actual Firebase, Crashlytics, Remote Config, Gradle/Dart-define, Firebase App
Distribution, Google credential, provider, and release-signing variable names.
It compares only exported variable names and never expands or prints a value. A
clean-environment negative test exercises every protected name. The job
supplies no Dart defines, credentials, release signing, deploy action, artifact
upload, Firebase CLI command, or provider call.

## Broker audit exception

`scripts/check_broker_audit.mjs` is fail-closed. Until **2026-08-31**, it
accepts only moderate `GHSA-w5hq-g745-h8pq` in the current eight-node broker
audit graph. The policy validates both npm's full report and a separately
fetched `--omit=peer` report. Both must use audit report version 2 with no
top-level error or unknown report fields. The peer-omitted report and all
eight core entries in the full report must match exact vulnerability names,
ranges, directness, `via`, `nodes`, `effects`, vulnerability counts, and the
advisory's source, trusted GitHub origin/path, CWE, CVSS, and affected range.
npm's aggregate dependency counters vary when peer dependencies are omitted;
the checker requires their exact npm v2 field set and nonnegative integer types
while deriving topology only from exact vulnerability objects and lock paths.
The peer-omitted report may also retain exactly one omitted moderate peer in
its aggregate counters (8 or 9 moderate/total); every other severity and any
larger count remains zero/fail-closed.
When npm removes the peer entry, peer-omitted fix metadata is exact. npm may
retarget remediation advice in the full peer-aware report only to the two
locked direct Firebase packages, and that advice must retain the exact npm v2
field set and value types.

npm may add only its known derived `firebase-functions > firebase-admin`
peer-metavulnerability entry to the full report. That entry must have the exact
field set, direct state, `via`, empty effects, and top-level node; its range and
fix recommendation must retain the npm v2 types. The full report must also add
exactly the matching `firebase-admin` reverse effect for `firebase-functions`.
npm may retain the same exact node and reverse effect under `--omit=peer`; no
other peer entry or effect is accepted. The lock binds both
directions to exact top-level `firebase-functions@7.2.5` and
`firebase-admin@13.10.0` installations. Any other peer package or peer graph
change fails.

The lock policy also checks exact registry URLs, integrity values, dependency
fields/ranges, concrete resolved paths, and a single top-level UUID
installation. The complete approved paths from `firebase-admin` to the locked
`uuid@9.0.1` are:

1. `firebase-admin > @google-cloud/firestore > google-gax > uuid`
2. `firebase-admin > @google-cloud/firestore > google-gax > retry-request > teeny-request > uuid`
3. `firebase-admin > @google-cloud/storage > gaxios > uuid`
4. `firebase-admin > @google-cloud/storage > retry-request > teeny-request > uuid`
5. `firebase-admin > @google-cloud/storage > teeny-request > uuid`

The forms package has no exception: any npm audit finding fails CI. Audit gates
and parser fixtures run before `npm ci` or package lifecycle/test scripts. For
the broker, a top-level npm error, untrusted or changed advisory, extra node or
effect, extra or rerouted audit/lock edge, nested or duplicate UUID install,
changed package range/version/integrity, severity change, malformed output,
audit-command failure, or expiry fails the workflow. Fixtures cover those
cases, exact pre/post-expiry dates, invalid calendar dates, and timestamp-shaped
clock input. The deterministic clock is available only through an exported test
helper; the production CLI has no clock override and rejects `--as-of`.

This exception is a review reminder, not a risk acceptance for deployment.
Updating or removing it needs a separately reviewed lockfile and policy change.

## Owner protection handoff

`/.github/CODEOWNERS` is generated from the canonical release-policy selectors
and assigns `@kenleren` to every protected release control, including the trust
package and its runbook. CODEOWNERS alone does not enforce review. After this PR
passes independent task and redteam review,
the repository owner must prepare and validate a ruleset for `main` that:

1. Requires the `Release readiness` status from the expected GitHub Actions app,
   or uses a trusted required workflow when that repository feature is
   available.
2. Requires CODEOWNERS approval for the scoped policy paths, dismisses stale
   approvals, and requires approval of the latest pushed revision.
3. Prevents deletion or weakening of the workflow/policy controls through the
   same PR that supplies the status, with no administrator or role bypass.
4. Keeps the full pull-request review and conversation-resolution requirements
   appropriate for `main`.

The owner verification is a no-op workflow/policy-change PR: even if it emits a
green check named `Release readiness`, repository controls must block merge
until the trusted workflow or required CODEOWNERS/latest-push review approves
the change. Ruleset, branch-protection, merge, and administrator changes remain
human-owned and are outside this implementation task.
