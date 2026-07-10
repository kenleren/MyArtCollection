# AI Broker Auth And Quota Spec

Status: implemented research contract; deployment and live-provider use remain
gated
Issues: #50, #157, #177, #187, #190

## Decision

Archivale uses the owner-approved Firebase project `my-art-collections` for
distribution, anonymous Auth, App Check, the broker Function, and broker-owned
durable control records. Earlier proposals for a separate paid-broker Firebase
project are obsolete. A token from any other project is a wrong-project token.

This decision does not authorize a Functions deploy, provider traffic, account
or billing mutation, secret access, or collector-content testing. Issue #155 is
the only deployment and live-test gate.

## Identity Contract

Every provider-bound research request requires both:

- a Firebase anonymous Auth ID token for `my-art-collections`, verified with
  revocation checking, exact audience, exact issuer, and non-empty UID;
- a fresh limited-use App Check token for `my-art-collections`, verified with
  `consume: true`, exact project ID and number audiences, exact issuer, and an
  approved Firebase app ID.

Firebase Admin returns App Check metadata at the response root and decoded
claims under `response.token`. Project audiences and issuer are validated from
`response.token`; root `appId` must match `response.token.sub` and, when
present, `response.token.app_id`.

Auth verification, including revocation and project checks, happens before App
Check consumption. A consumed token is rejected as replay. App Check attests
the app instance; it never substitutes for Auth identity or entitlement.

The broker derives its quota subject on the server with an HMAC over the
project, app ID, and Auth UID. Raw UIDs and raw tokens are not quota keys and
must not enter broker logs, telemetry, error bodies, or fixtures.

## Billing Identity And Consent Separation

The same `my-art-collections` anonymous Auth facility may also be used by the
Play Billing verifier under `PLAY_BILLING_GATE_SPEC.md`, but the authorities are
separate:

- AI research identity may be created or reused only after explicit, current-
  version research consent.
- Billing identity may be created or reused only after the distinct billing-
  verification disclosure when the collector initiates purchase or restore.
- The displayed `billing-verification-disclosure-v1` acceptance must be
  recorded through the billing-owned `acceptPlayBillingDisclosure` callable as
  a current, purpose-bound server assertion before verification. Auth, App
  Check, a request field, UID existence, or this broker's research-consent
  record cannot substitute for that assertion.
- Billing-owned `revokePlayBillingDisclosure` revokes that assertion without
  altering research consent or calling Play.
- Accepting the billing disclosure never records or implies AI research
  consent, never enables `online_research_enabled`, and never authorizes
  collector content or a research request to leave the device.
- Accepting research consent never proves purchase or authorizes billing
  verification without the billing disclosure.
- Reuse of one anonymous UID does not merge these authorities. Each route must
  enforce its own disclosure/consent and purpose-specific gates.

The research broker has no Android Publisher permission and no access to the
named `archivale-play-billing` Firestore database. The billing verifier's
database-conditioned IAM excludes the broker/default databases, while the
broker runtime is excluded from the billing database. Billing database
Security Rules deny every mobile/web client read and write; server IAM, not
rules, controls runtime access.

`brokerDurableEntitlements` is a versioned research-broker control only: it
cannot represent, mint, cache, extend, restore, or override a Play payment
entitlement, durable billing delivery record, or mobile 15-minute lease. A paid
billing result also does not bypass broker owner allowlist, research consent,
entitlement, breaker, credit, payload, or provider gates.

Billing uses a distinct `play-billing` codebase, callables, runtime identity,
named Firestore database, database-scoped IAM, deny-all client rules,
collections, fingerprint domain, and rollback target in the same Firebase
project. Its verified delivery is durably committed before Play
acknowledgement, but no client lease exists until acknowledgement and final
storage are recoverable. Token-scoped serialization uses a server-issued
monotonic attempt generation and nonce distinct from request identity;
delivery, acknowledgement, finalization, and linked-predecessor writes require
the exact current owner and phase. Lease-protected duplicates make zero Play
calls, and acknowledged final state cannot regress to acknowledgement-unknown.
These owner/CAS rules and request ceilings are billing-only controls. A billing
outage or kill switch must fail paid plan access to Free without enabling
research or requiring the AI breaker to change. An AI breaker must stop
research without altering valid Play purchase state.

## Gate Order

The paid request path is ordered as follows:

1. HTTP method and content type.
2. Per-request server kill-switch check.
3. Durable broker configuration availability.
4. JSON decoding.
5. revoked/project-bound Firebase Auth verification.
6. limited-use App Check verification and consumption.
7. owner allowlist.
8. explicit consent and current consent-copy version.
9. server-side entitlement.
10. broker breaker.
11. request shape, image bounds, RFC 8785 canonical recomputation, and hash
    equality.
12. existing request replay/conflict/unsafe-state decision.
13. transactional one-credit reservation for new work.
14. provider configuration lookup.
15. provider construction.
16. broker request authorization.
17. durable `dispatch_started` persistence.
18. provider invocation/fetch.
19. output validation.
20. durable terminal outcome persistence.
21. idempotent refund or finalize settlement.

No provider configuration, construction, authorization, or fetch may happen
for a rejected gate through step 13. Failed `dispatch_started` persistence also
forbids provider invocation.

The owner allowlist and consent checks at steps 7 and 8 happen before any
durable entitlement or breaker read. A forbidden UID, missing consent, or stale
consent therefore causes zero durable access reads.

Entitlement and breaker are rechecked before replay. Credit availability is not
a pre-replay gate: a completed matching request is free to replay even when no
new credits remain.

## Durable Request Contract

Request records use `broker-request-lifecycle-v1` and these states:

| State | Meaning | Redrive rule |
| --- | --- | --- |
| `reserved` | Idempotency ownership and one credit were reserved atomically; provider dispatch has not started | Before the 60-second lease boundary, return in-flight. At or after the boundary, persist a terminal expiration and then refund. Never dispatch the same record. |
| `dispatch_started` | Provider invocation was authorized and dispatch intent was persisted | Never auto-refund or redrive. Before lease expiry return in-flight; afterward return outcome-unknown. |
| `terminal` | A replayable success or fixed failure was persisted | Replay the stored outcome and recover pending settlement idempotently. |

Required request fields include:

- `record_version`
- one-way `quota_subject`
- `request_id`
- recomputed `payload_hash`
- `state`
- `credit_cost=1`
- `reservation_lease_expires_at`
- `retention_expires_at`
- `settlement_state`
- `terminal_outcome` only for terminal records

`reservation_lease_expires_at` is a 60-second ownership lease.
`retention_expires_at` is a 24-hour cleanup signal only. Retention expiry never
changes replay, refund, finalization, or dispatch behavior. Cleanup must remove
the settled request and matching ledger safely; it must not reinterpret an
expired record as absent inside the request path.

The transition from `reserved` to `dispatch_started` is a Firestore transaction
that compares request identity, current `reserved` state, matching ledger, and
`reservation_lease_expires_at`. At or after the exact lease boundary it writes
a terminal expiration instead, then settlement refunds without provider fetch.

Malformed, unversioned, unknown-version, unknown-state, legacy, or orphaned
request/ledger/control records are unsafe. They fail closed and are never
treated as absent. Same-version records require exact fields and types. Request
and ledger key identity, credit cost, lifecycle state, settlement intent,
terminal request ID, and refund reason must agree before replay or settlement.
This task does not migrate legacy records automatically.

## Credit Contract

The idempotency record, `broker-credit-ledger-v1` reservation, subject
aggregate, and global aggregate are created in one Firestore transaction.
Exactly one credit is reserved for new work.

Versioned durable supporting records are:

- `broker-control-v1`
- `broker-entitlement-v1`
- `broker-credit-subject-v1`
- `broker-credit-global-v1`
- `broker-credit-ledger-v1`

An unversioned control, entitlement, aggregate, request, or ledger record fails
closed. Subject and broker credit caps include reserved plus finalized credits.
One in-flight reservation per quota subject is the default.

Terminal persistence always precedes settlement. Settlement state is one of
`pending_refund`, `refunded`, `pending_finalize`, or `finalized`. Refund and
finalize transactions are idempotent. A crash or injected fault after terminal
persistence leaves a replayable terminal result and a pending settlement that
the next replay can recover without another provider call.

## Provider Outcome Contract

| Outcome | Durable terminal result | Credit action | Redrive |
| --- | --- | --- | --- |
| configuration failure | temporarily unavailable | refund | no same-record redrive |
| construction failure | temporarily unavailable | refund | no same-record redrive |
| authorization failure | temporarily unavailable | refund | no same-record redrive |
| dispatch persistence failure | temporarily unavailable | refund after terminal persistence; fetch forbidden | no same-record redrive |
| rate limit | `rate_limited` | refund | replay stored failure |
| provider refusal | `upstream_refusal` | finalize | replay stored failure |
| timeout | `upstream_timeout` | refund only after terminal persistence | replay stored failure |
| generic post-dispatch failure | `upstream_failure` | finalize | replay stored failure |
| invalid output/source grounding | `upstream_invalid_output` | finalize | replay stored failure |
| success | normalized completed result | finalize | replay stored success |

Provider `Retry-After` values default to 30 seconds, round up to a whole second,
and clamp to 5 through 300 seconds.

Provider fetch and response-body parsing share an absolute abort deadline
captured at handler entry and capped at 55 seconds. Provider construction uses
only the remaining budget, keeping the deadline below the 60-second Function
timeout so the broker can persist a terminal timeout and complete or leave
recoverable pending refund settlement.

## Error And Logging Rules

All HTTP and broker failures use `broker-error-v1`. The exhaustive mapping is
checked in `backend/broker/fixtures/broker-error-v1.json`. Auth and wrong-project
details are collapsed to fixed public messages. `not_entitled` and
`credits_exhausted` remain distinct public outcomes.
An error envelope includes `request_id` only after UUID validation; malformed
or free-form values are never reflected.

Logs and evidence may contain fixed event/reason codes, request IDs, one-way
quota subjects, coarse timing, and aggregate credit counts. They must not
contain raw Auth/App Check tokens, raw UID, prompts, image bytes, hints, provider
bodies, source URLs, collector content, secret names or values, or local paths.

## Required Evidence

The fake-only test pack must prove:

- Auth revocation/project verification precedes App Check consumption;
- consumed, invalid, unapproved-app, and wrong-project tokens fail closed;
- every pre-reservation rejection produces zero provider config, construction,
  authorization, and fetch calls;
- canonical hash mismatch precedes idempotency and provider setup;
- completed replay is free and a changed hash conflicts;
- concurrent requests cannot double reserve or dispatch;
- owner allowlist and consent rejection cause zero durable access reads;
- lease-boundary and retention semantics are separate;
- dispatch compare-and-set rejects the exact lease boundary under races;
- provider timeout aborts before the Function timeout and is terminal before
  refund;
- ambiguous dispatch state never auto-refunds or redrives;
- malformed same-version aggregates, request/ledger orphans, mismatched replay
  bindings, and malformed refund state fail closed without partial settlement;
- malformed request IDs are not reflected in public errors;
- refund and finalize recover idempotently after faults.

Independent task review and redteam/security review are required before this
implementation can advance. Deployment review under #155 remains required
before any environment mutation or live request.
