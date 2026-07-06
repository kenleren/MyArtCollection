# AI Fake Broker Runbook

Status: fake-provider-only local contract for issues #116, #117, #118, and
#119.

This repository now has an isolated broker scaffold in `backend/broker`. It is
not wired into Firebase Hosting, Firebase Functions, Secret Manager, or any
provider SDK.

## Current behavior

- `handleResearchRequest` accepts a v1-style broker request envelope.
- `handleFakeBrokerAdapterRequest` is a local server-side
  HTTP/callable-style adapter around the broker core. It accepts parsed JSON
  plus explicit local auth/app identity placeholders and returns a stable
  envelope:
  - success: `{ ok: true, status: 200, body: BrokerResponse }`,
  - error: `{ ok: false, status, body: { request_id?, status, provider, error } }`.
- The only provider implementation is `FakeResearchProvider`.
- There is no OpenAI SDK, no live provider host, no provider key lookup, and no
  deploy target.
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
- The adapter performs the first local identity check before entering the broker
  core. Missing App Check/Auth placeholders or missing quota subject therefore
  produce fixed auth envelopes without broker trace entries, ledger records, or
  provider calls.
- Adapter error statuses are deterministic and intentionally coarse:
  unauthorized/missing quota subject -> `401`, identity/consent/entitlement
  failures -> `403`, malformed payloads -> `400`, idempotency conflict -> `409`,
  quota cap failures -> `429`, breaker open -> `503`, and fake provider/output
  failures -> `502`.
- Adapter error bodies use fixed messages and stable codes. They must not echo
  raw request payload, raw notes, provider key/env names, local env file names,
  stack traces, or the broker's server-only order trace.
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
- The mobile bypass guard scans `lib/`, `android/`, and `ios/` for direct
  provider SDKs, provider hosts, provider key/env names, Firebase AI Logic
  direct-client usage, and direct provider network clients. Mobile code may only
  target the Archivale broker endpoint in a future client slice.
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

Run the fake broker tests:

```sh
cd backend/broker
npm test
```

Run the mobile bypass guard directly:

```sh
node scripts/mobile_broker_bypass_guard.mjs
```

Run the Flutter wrapper test for the guard:

```sh
flutter test test/mobile_broker_bypass_guard_test.dart
```

These checks require no provider secret values. They must not read local env
files, service-account files, signing files, keystores, or Firebase app
configuration files.

For issue #118, the broker tests cover the adapter success envelope, auth and
quota-subject pre-broker rejection, unsupported MIME, stale consent, bad
payload hash, idempotency conflict, cap exceeded, no provider/ledger reserve for
pre-provider rejects, and response redaction for raw notes, provider env names,
and trace internals.

## Remaining live gates

The fake broker does not approve live provider usage. Before any real provider
path exists, the project still needs:

- accepted #52 ZDR approval for the exact OpenAI org/project used by rollout,
- deployment-manager approval for Blaze/backend deployment and rollback,
- Secret Manager or equivalent server-only secret custody,
- real Auth/App Check verification against the broker Firebase project,
- real Firebase Functions or HTTPS hosting for the broker adapter,
- server-derived quota subjects using a one-way key, not client input,
- durable entitlement, quota, credit, one-in-flight, and spend accounting,
- production-safe error mapping and content-free operational logging on the
  deployed boundary,
- provider adapter review with `store=false`, hosted web search, source
  allowlists, and structured output validation,
- log redaction tests proving prompts, images, notes, source URLs, raw tokens,
  UIDs, filenames, and secrets cannot enter logs or telemetry,
- independent task review and redteam/privacy review.

Hard blocks remain: no deploy, no Blaze enablement, no provider/billing
mutation, no Secret Manager mutation, no real OpenAI/provider calls, no mobile
secrets, and no direct mobile provider path.
