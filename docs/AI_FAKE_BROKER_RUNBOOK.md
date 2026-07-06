# AI Fake Broker Runbook

Status: fake-provider-only local contract for issues #116 and #117.

This repository now has an isolated broker scaffold in `backend/broker`. It is
server-side-only code and is not wired into the Flutter app, Firebase Hosting,
Firebase Functions, Secret Manager, or any provider SDK.

## Current behavior

- `handleResearchRequest` accepts a v1-style broker request envelope.
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
  finalized credits per quota subject and 100 finalized credits broker-wide for
  the in-memory month bucket. These are test contracts only, not durable quota
  or billing controls.
- The mobile bypass guard scans `lib/`, `android/`, and `ios/` for direct
  provider SDKs, provider hosts, provider key/env names, Firebase AI Logic
  direct-client usage, and direct provider network clients. Mobile code may only
  target the Archivale broker endpoint in a future client slice.

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

## Remaining live gates

The fake broker does not approve live provider usage. Before any real provider
path exists, the project still needs:

- accepted #52 ZDR approval for the exact OpenAI org/project used by rollout,
- deployment-manager approval for Blaze/backend deployment and rollback,
- Secret Manager or equivalent server-only secret custody,
- real Auth/App Check verification against the broker Firebase project,
- server-derived quota subjects using a one-way key, not client input,
- durable entitlement, quota, credit, one-in-flight, and spend accounting,
- provider adapter review with `store=false`, hosted web search, source
  allowlists, and structured output validation,
- log redaction tests proving prompts, images, notes, source URLs, raw tokens,
  UIDs, filenames, and secrets cannot enter logs or telemetry,
- independent task review and redteam/privacy review.

Hard blocks remain: no deploy, no Blaze enablement, no provider/billing
mutation, no Secret Manager mutation, no real OpenAI/provider calls, no mobile
secrets, and no direct mobile provider path.
