# Archivale Research Broker

Server-only research broker for the `my-art-collections` Firebase project. The
package is implemented and fake-tested but remains disabled by default. It is
not deploy or live-provider approval.

`my-art-collections` is also the sole project approved for the planned Play
Billing verifier, but billing is not part of this package. The verifier must use
the separate `play-billing` codebase, billing disclosure accept/revoke and
`verifyPlaySubscription` callables, runtime identity, Android Publisher IAM,
named `archivale-play-billing` Firestore database, database-conditioned IAM,
deny-all client rules, collections, and rollback target in
`docs/PLAY_BILLING_GATE_SPEC.md`.

## Modules

- `src/canonical_payload.ts`: RFC 8785 `canonical-payload-v1` bytes and digest
- `src/error_contract.ts`: exhaustive safe `broker-error-v1` mapping
- `src/request_lifecycle.ts`: in-memory lifecycle and fault-test implementation
- `src/durable_protection.ts`: Auth/App Check verification and Firestore
  lifecycle transaction
- `src/broker.ts`: gate, provider, terminal, and settlement orchestration
- `src/adapter.ts`: strict parsed-JSON adapter
- `src/live_broker.ts`: fail-closed HTTP shell with lazy provider setup
- `src/openai_provider.ts`: service-private provider adapter
- `fixtures/`: mobile/backend canonical and error contract fixtures

The package public API does not export the provider constructor. The provider
adapter also requires one-time broker authorization for the exact request
object before fetch.

## Contract Summary

The server verifies revoked/project-bound Auth before consuming a fresh
limited-use App Check token. Firebase Admin App Check claims are read from the
SDK response's decoded `token`; the root `appId` must match the token subject.
The owner UID allowlist and valid current consent run before any durable
entitlement or breaker read. Entitlement, breaker, payload shape, canonical
hash, replay, and atomic one-credit reservation all precede provider
configuration.

`canonical-payload-v1` uses RFC 8785 UTF-8 bytes and a 64-character lowercase
SHA-256 digest. `request_id` and `payload_hash` are excluded. Optional fields
are omitted, arrays retain order, Unicode is not normalized, and lone
surrogates are rejected.

Durable requests use `broker-request-lifecycle-v1` states:

- `reserved`
- `dispatch_started`
- `terminal`

The reservation lease is 60 seconds. The retention signal is 24 hours and does
not change execution behavior. Unversioned, malformed, unknown, or orphaned
durable records fail closed and are never treated as absent. Request and ledger
identity, state, settlement, cost, and terminal outcome must agree before
replay or settlement. The transactional dispatch compare-and-set rejects the
exact lease boundary before provider fetch.

Terminal persistence precedes refund/finalize. Pending settlement recovers
idempotently on replay. A `dispatch_started` request is never automatically
refunded or redriven.

All failures use `broker-error-v1`; see
`fixtures/broker-error-v1.json`. Rate-limit Retry-After defaults to 30 seconds
and clamps to 5-300 seconds. Only a validated UUID may be reflected as a public
request ID. Provider fetch and response parsing use an absolute abort deadline
captured at handler entry and capped at 55 seconds, leaving a margin before the
60-second Function timeout for durable terminal timeout persistence and refund.

## Firebase Surface

Root `firebase.json` declares:

- source: `backend/broker`
- codebase: `broker`
- function: `artResearchBroker`
- region: `us-central1`
- runtime: Node.js 22

There is intentionally no checked-in `.firebaserc`. Deployment examples must
always name `my-art-collections`, but no deploy command belongs in this task.

The shell remains disabled unless these route gates are set by the deployment
owner:

- `BROKER_HTTP_ENABLED=true`
- `BROKER_PROVIDER_MODE=openai`
- `BROKER_OPENAI_LIVE_TEST_ENABLED=true`

It also requires owner UID and app ID allowlists, exact project ID/number,
durable-store readiness, a server-only quota HMAC secret binding, approved
provider configuration, and rights-reviewed source domains. Do not inspect or
populate those values from repository work.

Versioned Firestore records expected by code are documented in
`docs/AI_BROKER_AUTH_AND_QUOTA_SPEC.md`. Provisioning and validation of real
records are #155 deployment-owner work.

Anonymous Auth is shared identity infrastructure, not shared consent or
authority. A UID created after the billing-verification disclosure does not
create AI research consent, and research consent cannot create the required
purpose-bound billing-disclosure assertion. This broker must still enforce the
owner allowlist, current research consent, broker entitlement, breaker,
credits, and payload gates.

The broker runtime must have no access to `archivale-play-billing` or any of its
disclosure, binding, replay, token-operation, or rate-limit collections. The
billing verifier must have no access to this broker's/default-database records.
Firestore client rules deny all billing-database access, while database-scoped
IAM enforces the server boundary. This package must not call Android Publisher
APIs or treat `brokerDurableEntitlements` as payment authority. A Play delivery
record or plan lease cannot be minted, cached, restored, or extended by broker
code.

## Local Checks

```sh
npm test
```

From the repository root:

```sh
node scripts/mobile_broker_bypass_guard.mjs
node --test test/mobile_broker_bypass_guard_fixture_test.mjs
flutter test test/mobile_broker_bypass_guard_test.dart
scripts/secret_scan.sh
git diff --check
```

Tests use injected providers, token verifiers, clocks, faults, and Firestore
fakes. They do not require Firebase emulators, service accounts, provider
traffic, credentials, collector content, or account mutation.

Demo-only emulator evidence must avoid Firebase `--debug` output and inherited
credential-bearing environment values. Use a clean environment with a temporary
home directory, explicit JDK 21, and no service-account, token, provider, or
signing variables:

```sh
mkdir -p /tmp/archivale-firebase-emulator-home
env -i \
  HOME=/tmp/archivale-firebase-emulator-home \
  PATH="/opt/homebrew/opt/openjdk@21/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  JAVA_HOME=/opt/homebrew/opt/openjdk@21 \
  npm --prefix backend/broker run test:emulator
```

## Hard Boundaries

- No provider key or SDK in mobile.
- No direct mobile provider call.
- No `.env.local`, service-account, Firebase app-config, tester-list, signing,
  billing, or credential inspection.
- No live provider call or collector-content test.
- No automatic durable-record migration.
- No deploy, API enablement, billing mutation, project selection, secret
  mutation, or account mutation.
- No Play purchase verification, acknowledgement, purchase-token handling, or
  named billing-database access from this research package.
- No billing request/attempt-owner reuse: the separate billing implementation
  owns its server generation/nonce, leased phases, acknowledgement CAS, and
  monotonic final state; broker request identity has no authority there.
- AI and billing rollback remain independent inside `my-art-collections`;
  project-wide billing disablement is a human-owned cross-service last resort.
- Independent task review and redteam/security review are required.
- #155 remains the only deployment and capped live-test gate.
