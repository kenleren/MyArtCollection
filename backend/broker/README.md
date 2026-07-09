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
before OpenAI config lookup because durable cross-instance entitlement, credit,
and idempotency protection is not implemented in this package.

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

The shell still uses placeholder Auth/App Check/entitlement/credit inputs from
request headers. That keeps the package testable and deployable as a reviewed
shell, but it is not deploy approval and not production auth.

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
- No live shell provider calls until durable cross-instance spend protection is
  implemented and reviewed.

## Remaining gates before any owner live test

- real Firebase Auth/App Check verification instead of header placeholders,
- reviewed durable entitlement/credit/idempotency storage, wired into the live
  shell before provider config lookup or provider execution is enabled,
- exact #52 ZDR/data-handling approval for the rollout org/project,
- deployment-manager approval in #155,
- task review plus redteam/privacy review for this change,
- explicit owner approval for the exact live-test environment and secret setup.
