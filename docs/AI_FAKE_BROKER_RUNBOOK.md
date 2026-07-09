# AI Broker Runbook

Status: fake-tested implementation; no deploy or live-provider approval
Issues: #115, #154, #157, #177, #187

## Safety Boundary

This runbook covers repository checks and the fail-closed broker contract only.
Do not deploy Functions, enable APIs or billing, select/mutate Firebase
projects, inspect secrets, provision provider credentials, call a live
provider, or use collector content from this workflow. Issue #155 owns those
actions and approvals.

The approved Firebase project is `my-art-collections`. Older two-project broker
guidance is obsolete.

## Request Path

The HTTP path executes in this order:

1. method and JSON media type;
2. warm-instance kill-switch recheck;
3. durable dependency availability and JSON decoding;
4. revoked/project-bound anonymous Auth verification;
5. limited-use App Check verification with `consume: true`, reading decoded
   claims from Firebase Admin's `response.token`;
6. owner UID allowlist;
7. current approved consent;
8. durable entitlement and breaker reads;
9. `canonical-payload-v1` recomputation and hash equality;
10. durable replay/conflict/unsafe-state check;
11. atomic request-plus-one-credit reservation;
12. provider config, construction, and request authorization;
13. transactional lease-aware `dispatch_started` compare-and-set;
14. provider fetch, output validation, terminal persistence, and settlement.

Provider config, construction, authorization, and fetch counters must remain
zero for rejections through reservation. Fetch must remain zero when dispatch
persistence fails.

## Durable Records

Firestore collection shapes remain deployment-owned, but every record consumed
by the request path is versioned:

- `brokerDurableControl/live`: `broker-control-v1`
- `brokerDurableControl/globalUsage`: `broker-credit-global-v1`
- `brokerDurableEntitlements/<uid-key>`: `broker-entitlement-v1`
- `brokerDurableQuotaSubjects/<quota-key>`: `broker-credit-subject-v1`
- `brokerDurableIdempotency/<request-key>`:
  `broker-request-lifecycle-v1`
- `brokerDurableLedger/<request-key>`: `broker-credit-ledger-v1`

Do not seed or repair these records from this task. Unversioned, malformed,
unknown, or orphaned records return a safe unavailable error and do not permit
provider work. Same-version record fields are exact; request/ledger identity,
state, cost, terminal outcome, settlement intent, and refund reason must agree.
No automatic legacy migration exists.

`reservation_lease_expires_at` is 60 seconds. At the exact boundary, a
pre-dispatch `reserved` request terminalizes and then refunds. A
`dispatch_started` request is ambiguous forever from the request path and must
never be auto-refunded or redriven.

`retention_expires_at` is a 24-hour cleanup signal only. It does not change
execution behavior. Cleanup must not delete an active, ambiguous, or pending
settlement record.

## Provider Outcomes

- Config, construction, authorization, and dispatch-persistence failures:
  terminalize and refund; no fetch for any of them.
- Rate limit: terminalize, refund, default Retry-After 30 seconds, clamp 5-300.
- Timeout: persist terminal timeout first, then refund.
- Refusal, generic post-dispatch failure, and invalid output: terminalize and
  finalize spend.
- Success: persist normalized result and finalize spend.

If refund/finalize fails after terminal persistence, return the durable outcome
and leave a pending settlement. A later replay retries settlement idempotently
without provider work. If terminal persistence fails after dispatch, leave
`dispatch_started`; do not refund, delete, or redrive.

The provider fetch and response body share a deadline capped at 55 seconds,
below the Function's 60-second timeout. A deadline abort maps to terminal
timeout and refund; replay must return that stored timeout without another
provider call.

## Public Errors

All failures use `broker-error-v1`. Fixtures are authoritative:

- `backend/broker/fixtures/broker-error-v1.json`
- `backend/broker/fixtures/canonical-payload-v1.json`

Do not add ad hoc HTTP bodies. Error output must not contain provider names,
stage traces, project/token claims, configuration names, prompts, hints, image
bytes, source URLs, stack traces, or local paths.
Never reflect a request ID until it passes UUID validation.

## Local Checks

From the repository root:

```sh
npm --prefix backend/broker test
node scripts/mobile_broker_bypass_guard.mjs
node --test test/mobile_broker_bypass_guard_fixture_test.mjs
flutter test test/mobile_broker_bypass_guard_test.dart
scripts/secret_scan.sh
git diff --check
```

These checks require no provider credentials and must not read `.env.local`,
Firebase app config, service-account files, tester lists, signing material,
keystores, billing data, or collector content.

The broker tests cover:

- RFC 8785 canonical vectors and exact SHA-256 agreement;
- exhaustive error fixture/source agreement;
- Auth-before-App-Check order, revocation flag, project checks, consumption,
  replay, and app allowlist behavior;
- split entitlement and credit errors;
- exact gate/provider ordering and zero-provider prechecks;
- atomic Firestore reservation under concurrency;
- completed replay, hash conflict, one-in-flight, and no double dispatch;
- all provider settlement outcomes;
- authorization, dispatch, terminal, refund, and finalize fault injection;
- 60-second lease boundary and independent retention behavior;
- exact-boundary dispatch races and cross-instance no-double-dispatch;
- malformed/unversioned/unknown durable state, request/ledger orphans, and
  mismatched replay/refund bindings;
- provider abort deadline with terminal timeout/refund persistence;
- malformed request-ID non-reflection;
- direct provider bypass rejection and minimized OpenAI request construction.

## Disabled And Rollback Posture

The Function stays disabled unless all three route gates are exactly enabled:

- `BROKER_HTTP_ENABLED=true`
- `BROKER_PROVIDER_MODE=openai`
- `BROKER_OPENAI_LIVE_TEST_ENABLED=true`

Additional runtime configuration, durable records, server-only secrets,
allowlists, budget controls, ZDR/data rights approval, redteam review, and
deployment-manager approval are still required. Presence of environment
variable names in code is not proof that safe values or bindings exist.

For an approved deployed incident, use the reviewed server breaker or route
deny first. The destructive Function delete command remains a deployment-owner
last resort and is intentionally not executed by repository checks.

Evidence may record commit SHA, project ID, region, function target, fixed
reason codes, coarse status/latency, and aggregate credit changes. It must not
record private artwork details, prompts, source URLs, raw UIDs or tokens,
provider bodies, tester identities, credentials, secret values, or account
identifiers.

## Review Handoff

Implementation stops at `For Review`. Independent task review and
redteam/security review are mandatory. #155 remains the sole path to deployment
or a deliberately capped synthetic live test.
