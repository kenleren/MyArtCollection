# AI Broker Runbook

Status: local fake-provider foundation plus disabled-by-default OpenAI live
shell for issues #116, #117, #118, #119, #120, #133, and #154.

This repository now has an isolated broker scaffold in `backend/broker`. It is
still not approved for deploy or live provider traffic by default.

## Current behavior

- `handleResearchRequest` accepts a v1-style broker request envelope.
- `handleFakeBrokerAdapterRequest` is a local server-side
  HTTP/callable-style adapter around the broker core. It accepts parsed JSON
  plus explicit local auth/app identity placeholders and returns a stable
  envelope:
  - success: `{ ok: true, status: 200, body: BrokerResponse }`,
  - error: `{ ok: false, status, body: { request_id?, status, provider, error } }`.
- `handleBrokerAdapterRequest` is now the generic server-side adapter used by
  both fake and live-shell wiring.
- `FakeResearchProvider` remains the default provider in local tests.
- The OpenAI provider adapter is service-private implementation code behind the
  same provider interface. It is not exported from the package public API, and
  it refuses to call `fetch` unless the broker core issued request-specific
  authorization after the pre-provider gates passed. It uses a
  dependency-injected `fetch`, builds a Responses API request with
  `store=false`, hosted `web_search`, `tool_choice="required"`, and strict
  `text.format` JSON Schema output, then validates returned source URLs against
  the broker allowlist and OpenAI web-search citations before the broker
  accepts the result.
- A Firebase Functions 2nd gen shell now exists in `backend/broker/src/firebase.ts`
  with a pure HTTP handler in `backend/broker/src/live_broker.ts`.
- The auth input is a strict local DTO stub. It requires verified App Check and
  Auth booleans, a non-empty anonymous-auth placeholder UID, a non-empty app ID,
  matching placeholder project IDs, and a pre-derived
  `quota_subject_v1_...` value. This is not Firebase Auth, not App Check token
  verification, and not a production quota subject derivation.
- The validation order is:
  auth/App Check/quota-subject placeholders -> consent/version checks ->
  payload receipt checks -> entitlement/credit placeholder -> breaker -> payload
  validation -> idempotency conflict/in-flight check -> credit reserve
  placeholder -> fake provider -> output validation placeholder -> credit
  finalize placeholder.
- Missing auth or missing quota subject rejects at the auth stage before
  consent, payload validation, ledger, or provider work.
- The live shell returns `503 research_broker_disabled` before any provider
  credential lookup or provider call unless all explicit live-test gates are
  present:
  - `BROKER_HTTP_ENABLED=true`
  - `BROKER_PROVIDER_MODE=openai`
  - `BROKER_OPENAI_LIVE_TEST_ENABLED=true`
  - `BROKER_OWNER_UID_ALLOWLIST=<comma-separated owner UIDs>`
  - `OPENAI_ALLOWED_DOMAINS=<comma-separated professional-source domains>`
  - `OPENAI_API_KEY` or `ARCHIVALE_OPENAI_API_KEY`
- Even with those env gates present, the default live configuration currently
  fails closed with durable protection unavailable before OpenAI config lookup.
  It must stay that way until reviewed cross-instance entitlement, credit,
  idempotency, and one-in-flight storage replaces the in-memory placeholders.
- The live shell still fails closed even when enabled unless the request UID is
  in `BROKER_OWNER_UID_ALLOWLIST`.
- The live HTTP handler re-checks the env kill switch on every request. A warm
  instance must return `503 research_broker_disabled` before dependency/config
  work when `BROKER_HTTP_ENABLED`, `BROKER_PROVIDER_MODE`, or
  `BROKER_OPENAI_LIVE_TEST_ENABLED` changes to a disabled value.
- The adapter performs the first local identity check before entering the broker
  core. Missing App Check/Auth placeholders or missing quota subject therefore
  produce fixed auth envelopes without broker trace entries, ledger records, or
  provider calls.
- Adapter error statuses are deterministic and intentionally coarse:
  unauthorized/missing quota subject -> `401`, identity/consent/entitlement
  failures -> `403`, malformed payloads -> `400`, idempotency conflict -> `409`,
  quota cap failures -> `429`, breaker open -> `503`, and provider/output
  failures -> `502`.
- Adapter error bodies use fixed messages and stable codes. They must not echo
  raw request payload, raw notes, provider key/env names, local env file names,
  stack traces, or the broker's server-only order trace.
- The live OpenAI path reads provider credentials only from runtime env/secret
  injection names. It does not read `.env.local`, mobile Firebase config files,
  service-account files, or any repo-local secret file.
- Idempotency is in-memory and local-test only. For the same `quota_subject`
  and `request_id`, the same `payload_hash` replays the stored response,
  including when a matching request is already in flight. Same quota subject and
  `request_id` with a changed `payload_hash` returns a fixed conflict shape
  before another provider call or credit reserve.
- The placeholder credit ledger is deterministic and in-memory. Ledger records
  use these states:
  - `rejected-before-reserve`: quota reservation was denied before any provider
    call.
  - `reserved`: a one-credit local reservation exists for the fake request.
  - `finalized`: the reservation counted as spent.
  - `refunded`: the reservation was released and does not count as spent.
- The local cost contract is one placeholder credit per broker request. Provider
  output validation failures finalize the reservation and count against the
  subject and broker monthly cap placeholders because fake provider work already
  happened. Fake provider exceptions refund the reservation and do not count as
  spent. Consent, malformed payload, idempotency conflict, entitlement, breaker,
  and cap failures happen before provider work.
- The cap placeholders fail closed before provider calls. Defaults are three
  exposed credits per quota subject and 100 exposed credits broker-wide for the
  in-memory month bucket. Exposure includes both `reserved` in-flight credits
  and `finalized` spent credits so concurrent distinct requests cannot exceed a
  cap before provider work completes. `refunded` and `rejected-before-reserve`
  records do not count as exposed. These are test contracts only, not durable
  quota or billing controls.
- The current live shell keeps the placeholder auth/entitlement/credit inputs in
  HTTP headers for owner-test scaffolding only. This is deliberately not the
  final production trust boundary.
- The mobile bypass guard scans root Flutter dependency manifests plus `lib/`,
  `android/`, and `ios/` source, dependency, and native config manifests for
  direct provider SDKs, provider hosts, provider key/env names, Firebase AI
  Logic direct-client usage, and direct provider network clients. Mobile code
  may only target the Archivale broker endpoint in a future client slice.
- Issue #119 adds a disabled Flutter broker client boundary that can serialize
  an approved local research request into the fake adapter envelope shape only
  when tests explicitly inject a fake endpoint. The production app dependency
  path still defaults to the existing local fixture client; this slice does not
  add an HTTP client, live endpoint URL, provider SDK, provider credential, or
  deployed backend call.
- In a future gated deployment, mobile may call only the Archivale broker
  endpoint. That future path still requires the live gates below and must remain
  behind the existing Remote Config and explicit-consent controls.

## Local checks

Run the broker tests:

```sh
cd backend/broker
npm test
```

Run dependency vulnerability checks from the broker package:

```sh
cd backend/broker
npm audit
```

Run the mobile bypass guard directly:

```sh
node scripts/mobile_broker_bypass_guard.mjs
```

Run the negative fixture coverage for dependency and native config manifests:

```sh
node --test test/mobile_broker_bypass_guard_fixture_test.mjs
```

Run the Flutter wrapper test for the guard:

```sh
flutter test test/mobile_broker_bypass_guard_test.dart
```

These checks require no provider secret values. They must not read local env
files, service-account files, signing files, keystores, or Firebase app
configuration files.

Broker tests now cover:

- adapter success and failure envelopes,
- auth and quota-subject pre-broker rejection,
- consent/version/hash gates,
- entitlement/credit-denied and breaker-open gates before any provider call or
  credit reserve/finalize work,
- idempotency and one-in-flight behavior,
- no provider/ledger reserve for pre-provider rejects,
- output-validation spend semantics,
- no package-public direct OpenAI provider constructor and no direct provider
  `fetch` without broker-issued request authorization,
- OpenAI Responses request shape with `store=false`, hosted `web_search`,
  strict schema output, and no banned local fields,
- citation/allowlist rejection for bad provider output,
- disabled live-shell gate behavior before OpenAI config lookup,
- default live-shell durable-protection fail-closed behavior before OpenAI
  config lookup,
- warm-instance kill-switch re-checks before dependency/config/provider work,
- and response redaction for raw notes, provider env names, and trace internals.

## Remaining live gates

This broker shell is still not deploy or live-test approval. Before any real
owner live test or rollout, the project still needs:

- accepted #52 ZDR approval for the exact OpenAI org/project used by rollout,
- deployment-manager approval for Blaze/backend deployment and rollback in #155,
- Secret Manager or equivalent server-only secret custody,
- real Auth/App Check verification against the broker Firebase project,
- server-derived quota subjects using a one-way key, not client input,
- durable entitlement, quota, credit, one-in-flight, and spend accounting,
  with tests proving duplicate request IDs cannot double-spend across instances
  or restarts,
- production-safe error mapping and content-free operational logging on the
  deployed boundary,
- log redaction tests proving prompts, images, notes, source URLs, raw tokens,
  UIDs, filenames, and secrets cannot enter logs or telemetry,
- repository branch protection or a ruleset that requires the mobile broker
  bypass guard workflow before integration; this is a release/admin follow-up
  because repository settings cannot be safely proven or changed from this code
  branch,
- independent task review and redteam/privacy review.

Hard blocks remain: no deploy, no Blaze enablement, no provider/billing
mutation, no Secret Manager mutation, no real OpenAI/provider calls, no mobile
secrets, and no direct mobile provider path.
