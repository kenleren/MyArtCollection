# AI Fake Broker Runbook

Status: fake-provider-only foundation for issue #116.

This repository now has an isolated broker scaffold in `backend/broker`. It is
server-side-only code and is not wired into the Flutter app, Firebase Hosting,
Firebase Functions, Secret Manager, or any provider SDK.

## Current behavior

- `handleResearchRequest` accepts a v1-style broker request envelope.
- The only provider implementation is `FakeResearchProvider`.
- There is no OpenAI SDK, no live provider host, no provider key lookup, and no
  deploy target.
- The validation order is:
  auth/App Check placeholders -> consent/version checks -> entitlement/credit
  placeholder -> breaker -> payload validation -> idempotency conflict check ->
  credit reserve placeholder -> fake provider -> output validation placeholder
  -> credit finalize placeholder.
- Idempotency is in-memory and local-test only. Same `request_id` with the same
  `payload_hash` replays the stored response. Same `request_id` with a changed
  `payload_hash` returns a fixed conflict shape before another provider call or
  credit reserve.
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
- durable entitlement, quota, credit, one-in-flight, and spend accounting,
- provider adapter review with `store=false`, hosted web search, source
  allowlists, and structured output validation,
- log redaction tests proving prompts, images, notes, source URLs, raw tokens,
  UIDs, filenames, and secrets cannot enter logs or telemetry,
- independent task review and redteam/privacy review.

Hard blocks remain: no deploy, no Blaze enablement, no provider/billing
mutation, no Secret Manager mutation, no real OpenAI/provider calls, no mobile
secrets, and no direct mobile provider path.
