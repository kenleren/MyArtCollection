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

It also requires research admission and app ID allowlists, exact project ID/number,
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
admission policy, current research consent, broker entitlement, breaker,
credits, and payload gates.

The broker runtime must have no access to `archivale-play-billing` or any of its
disclosure, binding, replay, token-operation, or rate-limit collections. The
billing verifier must have no access to this broker's/default-database records.
Firestore client rules deny all billing-database access, while database-scoped
IAM enforces the server boundary. This package must not call Android Publisher
APIs or treat `brokerDurableEntitlements` as payment authority. A Play delivery
record or plan lease cannot be minted, cached, restored, or extended by broker
code.

### Bounded internal research

The live Firebase export binds only `OPENAI_API_KEY` and
`BROKER_QUOTA_HMAC_SECRET`, and names the dedicated
`archivale-research-broker@my-art-collections.iam.gserviceaccount.com` runtime.
It starts at zero instances, with one maximum instance and one concurrent
request. These source settings do not provision the account, secrets or IAM.
Provider lookup remains after consent, verified identity and credit reservation.

`BROKER_ADMISSION_MODE` defaults to `owner_only`, requiring the existing owner
UID allowlist and server entitlement. The explicit `verified_internal_app`
mode also requires `BROKER_INTERNAL_TEST_EXPIRES_AT` as a canonical UTC timestamp
with milliseconds. During that window, verified Auth and a fresh consumed App
Check token for the approved app can receive bounded test research access
without a subscription or a client-created entitlement. App Check verifies the
installation; it does not prove membership in a saved Play tester list.
The HTTP window and durable budget expiry must agree. Unknown modes, stale
windows, missing budget heads and mismatched expiries fail closed.

Every live Firebase mode requires the operator-owned document
`brokerDurableControl/providerBudget`:

```json
{
  "record_version": "broker-provider-budget-v1",
  "dispatchLimit": 30,
  "dispatchCount": 0,
  "expiresAt": "<approved canonical UTC expiry>"
}
```

Provision this head once under the reviewed release gate. Its limit is at most
30 dispatch attempts. Never delete, reset or auto-create it, including after
its expiry; normal request retention does not apply to this budget. New requests
check it before credit reservation. Dispatch intent consumes a slot atomically
with `dispatch_started` and rechecks the breaker and expiry. Failed, timed-out
or uncertain dispatches retain that charge even when collector credits refund.
Terminal replay uses no additional slot. The broker also checks expiry after
the dispatch transaction returns, before fetching. Anonymous UID churn cannot
reset the shared attempt budget.

Provider requests use `store=false`, `prompt_cache_retention=in_memory`, at most
8192 generated tokens (including reasoning), four built-in tool calls, the
existing 55-second absolute deadline and no redirect/retry. The attempt bound
is not a guaranteed USD ceiling; the separate USD 25 policy, billing controls,
alerts and operator review still apply. Exact project ZDR approval, source
rights, deny-all client access to broker records, database-scoped runtime IAM,
the deployed URL, mobile artifact and rollback/runtime evidence remain release
requirements. Nothing in this source slice enables provider traffic.

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
