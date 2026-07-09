# Archivale Research Broker

Server-only research broker for the `my-art-collections` Firebase project. The
package is implemented and fake-tested but remains disabled by default. It is
not deploy or live-provider approval.

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
limited-use App Check token. Consent, entitlement, breaker, payload shape,
canonical hash, replay, and atomic one-credit reservation all precede provider
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
durable records fail closed and are never treated as absent.

Terminal persistence precedes refund/finalize. Pending settlement recovers
idempotently on replay. A `dispatch_started` request is never automatically
refunded or redriven.

All failures use `broker-error-v1`; see
`fixtures/broker-error-v1.json`. Rate-limit Retry-After defaults to 30 seconds
and clamps to 5-300 seconds.

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

## Hard Boundaries

- No provider key or SDK in mobile.
- No direct mobile provider call.
- No `.env.local`, service-account, Firebase app-config, tester-list, signing,
  billing, or credential inspection.
- No live provider call or collector-content test.
- No automatic durable-record migration.
- No deploy, API enablement, billing mutation, project selection, secret
  mutation, or account mutation.
- Independent task review and redteam/security review are required.
- #155 remains the only deployment and capped live-test gate.
