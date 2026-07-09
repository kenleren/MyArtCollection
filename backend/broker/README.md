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
- Durable broker protection and Firestore adapter: `src/durable_protection.ts`
- Fake provider: `src/fake_provider.ts`
- Disabled-by-default HTTP shell: `src/live_broker.ts`
- Firebase Functions export: `src/firebase.ts`

## Firebase Functions deploy surface

The repository root `firebase.json` declares this package as the Firebase
Functions source:

- source directory: `backend/broker`
- codebase: `broker`
- exported function target: `artResearchBroker`
- region: `us-central1`
- runtime: Node.js 22
- local predeploy check: `npm --prefix "$RESOURCE_DIR" run build`

There is intentionally no checked-in `.firebaserc`. Until the project target is
explicitly pinned by the deployment owner, every Firebase CLI command for this
broker must pass the project id:

```sh
firebase deploy --project my-art-collections --only functions:broker:artResearchBroker
```

Do not use `firebase deploy --dry-run` as no-deploy evidence for this broker.
Firebase CLI 15.22.4 documents that dry-run validation may still enable APIs on
the target project. Use the no-deploy preflight below instead.

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
The Firebase Functions export wires a concrete Firebase Admin/Firestore-backed
`DurableBrokerProtection` by default when the durable env gate is complete. It
still returns `503 research_broker_disabled` before OpenAI config lookup if
required durable env, Firebase Admin, App Check, or Firestore dependencies are
absent. The production wiring provides:

- Firebase Admin-backed Auth ID token verification with revocation checking,
- Firebase Admin-backed App Check token verification,
- server-side `quota_subject_v1_...` derivation using
  `BROKER_QUOTA_HMAC_SECRET`,
- Firestore-backed entitlement, breaker, credit, one-in-flight, and idempotency
  storage,
- and lazy OpenAI provider dependency creation only after those request gates
  pass.

Firestore deployment-owned documents are intentionally abstract and contain no
secret values:

- `brokerDurableControl/live` for breaker and optional quota cap overrides.
- `brokerDurableControl/globalUsage` for broker-wide exposed credit aggregate.
- `brokerDurableEntitlements/<uid-key>` with `entitled=true` for approved owner
  test users.
- `brokerDurableQuotaSubjects/<quota-subject-key>` for per-subject exposed
  credit and reserved in-flight aggregate.
- `brokerDurableIdempotency/<request-key>` for request id, payload hash,
  in-flight/completed state, and replay response.
- `brokerDurableLedger/<request-key>` for reserved/finalized/refunded credit
  records.

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
firebase use --json
firebase functions:list --project my-art-collections --json
node scripts/mobile_broker_bypass_guard.mjs
scripts/secret_scan.sh
git diff --check
```

`firebase use --json` is expected to report no active project until the
deployment owner intentionally selects one, so deploy and list commands must use
`--project my-art-collections`. `firebase functions:list --project
my-art-collections --json` is read-only and may fail before the Functions API is
enabled or before any function has been deployed. Treat that failure as a
readiness signal for #155, not as permission to enable APIs or deploy from this
task.

No local preflight may read `.env.local`, Firebase app config files,
service-account files, Secret Manager values, provider keys, tester lists,
keystores, signing files, billing secrets, or collector content.

## Hard boundaries

- No mobile OpenAI SDK or provider key.
- No `.env.local` reads.
- No Secret Manager mutation in this package.
- No deploy from this issue.
- No live OpenAI calls during implementation/tests.
- No direct OpenAI provider constructor in the package public API.
- No live provider fetch without broker-issued request authorization.
- No live shell provider calls until environment-specific Admin credentials,
  Firestore documents/rules/index posture, secret injection, and
  breaker/entitlement configuration are reviewed under #155.
- No deploy, API enablement, Blaze/billing mutation, project selection mutation,
  or secret provisioning from the no-deploy preflight for this package.

## Rollback and disable command shapes

The first rollback action must be the server-side breaker or route-deny control
approved under #155, not a same-window delete. If the approved response requires
disabling the deployed function, the command shape is:

```sh
firebase functions:delete artResearchBroker --region us-central1 --project my-art-collections
```

Use that command only during an approved rollback window. Keep evidence
sanitized: record commit SHA, project id, project number, region, function
target, command shape, result status, request ids, status codes, latency
buckets, and aggregate usage deltas only. Do not record prompts, private
artwork details, source URLs, raw UIDs, Firebase tokens, App Check tokens,
tester emails, secret names or values, local paths, stack traces with local
paths, provider request/response bodies, screenshots of consoles containing
credentials, or billing-account identifiers beyond the approved project id and
project number.

## Remaining gates before any owner live test

- environment-specific Firebase Admin Auth/App Check credentials,
- reviewed durable Firestore entitlement/credit/idempotency storage
  provisioning,
- App Check limited-use/replay behavior decision for the deployed HTTP path,
- exact Secret Manager/runtime secret binding for `BROKER_QUOTA_HMAC_SECRET`
  and the OpenAI provider key,
- exact #52 ZDR/data-handling approval for the rollout org/project,
- deployment-manager approval in #155,
- task review plus redteam/privacy review for this change,
- explicit owner approval for the exact live-test environment and secret setup.
