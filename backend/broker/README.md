# Archivale Research Broker

This package contains the repo-side artwork research broker scaffold. It now
supports:

- the existing fake-provider local broker core and adapter for deterministic
  tests,
- an OpenAI Responses API provider adapter behind the broker `ProviderClient`
  interface,
- and a Firebase Functions 2nd gen HTTP shell that stays fail-closed unless
  explicit owner live-test gates are present.

## Current exports

- Pure broker core: `src/broker.ts`
- Generic server-side adapter: `src/adapter.ts`
- Durable broker protection abstractions: `src/durable_protection.ts`
- Fake provider: `src/fake_provider.ts`
- Disabled-by-default HTTP shell: `src/live_broker.ts`
- Firebase Functions export: `src/firebase.ts`

The OpenAI provider adapter is service-private implementation code. The package
public API does not export its constructor, and the adapter refuses to fetch
unless the broker core has authorized the exact request object after auth,
consent, entitlement/credit, breaker, payload, idempotency, and credit-reserve
gates pass.

## Live shell gate

The Firebase/HTTP shell returns `503 research_broker_disabled` unless all of
these non-default settings are present:

- `BROKER_HTTP_ENABLED=true`
- `BROKER_PROVIDER_MODE=openai`
- `BROKER_OPENAI_LIVE_TEST_ENABLED=true`
- `BROKER_OWNER_UID_ALLOWLIST=<comma-separated owner UIDs>`
- `BROKER_FIREBASE_PROJECT_ID=<dedicated broker Firebase project ID>`
- `BROKER_FIREBASE_PROJECT_NUMBER=<dedicated broker Firebase project number>`
- `BROKER_APP_ID_ALLOWLIST=<comma-separated approved Firebase App Check app IDs>`
- `BROKER_DURABLE_STORE_CONFIGURED=true`
- `BROKER_QUOTA_HMAC_SECRET=<server-only HMAC secret from runtime secret injection>`
- `OPENAI_ALLOWED_DOMAINS=<comma-separated professional-source domains>`
- `OPENAI_API_KEY` or `ARCHIVALE_OPENAI_API_KEY`

Optional OpenAI env vars:

- `OPENAI_RESPONSES_MODEL` or `ARCHIVALE_OPENAI_RESPONSES_MODEL`
  - defaults to `gpt-5.4` by repo product decision
- `OPENAI_WEB_SEARCH_CONTEXT_SIZE` or
  `ARCHIVALE_OPENAI_WEB_SEARCH_CONTEXT_SIZE`
  - defaults to `medium`
- `OPENAI_WEB_SEARCH_EXTERNAL_ACCESS` or
  `ARCHIVALE_OPENAI_WEB_SEARCH_EXTERNAL_ACCESS`
  - defaults to `false`

The shell does not read `.env.local`, mobile config files, or service-account
files. It reads provider credentials only from runtime env/secret injection.
The default live configuration still returns `503 research_broker_disabled`
before OpenAI config lookup unless a deployment-owned `DurableBrokerProtection`
implementation is injected. The implementation must provide:

- Firebase Admin-backed Auth ID token verification with revocation checking,
- Firebase Admin-backed App Check token verification,
- server-side `quota_subject_v1_...` derivation using
  `BROKER_QUOTA_HMAC_SECRET`,
- durable entitlement, breaker, credit, one-in-flight, and idempotency storage,
- and lazy OpenAI provider dependency creation only after those request gates
  pass.

## Current live-test posture

The OpenAI adapter is wired for:

- Responses API
- `store=false`
- `reasoning.effort=high`
- hosted `web_search`
- strict `text.format` JSON Schema output
- `tool_choice="required"`
- allowlisted domains only
- response grounding against returned citations before broker acceptance

The live shell no longer trusts client-supplied quota-subject, entitlement,
credit, breaker, Auth, or App Check placeholder headers. It expects
`Authorization: Bearer <Firebase Auth ID token>` and `X-Firebase-AppCheck:
<App Check token>` at the HTTP boundary, then builds the broker identity
server-side through the durable protection abstraction. Tests use fake
Admin/store adapters only and do not require real Firebase projects, emulators,
service accounts, or secrets.

## Local checks

From this directory:

```sh
npm test
npm audit
```

From the repo root:

```sh
node scripts/mobile_broker_bypass_guard.mjs
scripts/secret_scan.sh
git diff --check
```

## Hard boundaries

- No mobile OpenAI SDK or provider key.
- No `.env.local` reads.
- No Secret Manager mutation in this package.
- No deploy from this issue.
- No live OpenAI calls during implementation/tests.
- No direct OpenAI provider constructor in the package public API.
- No live provider fetch without broker-issued request authorization.
- No live shell provider calls until an environment-specific Admin verifier,
  durable store, secret injection, and breaker/entitlement configuration are
  reviewed under #155.

## Remaining gates before any owner live test

- environment-specific Firebase Admin Auth/App Check verifier wiring,
- reviewed durable entitlement/credit/idempotency storage provisioning,
- App Check limited-use/replay behavior decision for the deployed HTTP path,
- exact Secret Manager/runtime secret binding for `BROKER_QUOTA_HMAC_SECRET`
  and the OpenAI provider key,
- exact #52 ZDR/data-handling approval for the rollout org/project,
- deployment-manager approval in #155,
- task review plus redteam/privacy review for this change,
- explicit owner approval for the exact live-test environment and secret setup.
