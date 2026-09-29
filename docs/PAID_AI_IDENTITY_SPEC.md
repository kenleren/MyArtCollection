# Paid AI identity foundation (disabled L4-A)

This source-only contract supplies an injected billing-to-broker journey. It does
not enable a provider, create a callable/HTTP endpoint, publish billing events,
reserve a monthly credit, or authorize deployment. The production entrypoints do
not construct it. Local archive use remains account-optional; Google is required
only at the independent billing purchase/restore identity boundary.

## Identity and custody

The new dedicated entitlement routing key derives a shared pseudonymous route
from the fixed project and verified Firebase UID. The broker's separate private
account key derives an app-independent account subject. Canonical domains,
versions and matching protocol implementations are in each package's
`credit_identity_protocol.ts`; the cross-package test verifies their agreement.
Neither key reuses the existing billing fingerprint or app-scoped broker quota
key. App, install, month, plan and billing epoch do not enter account identity.

A shared route is not authentication or an accounting primary key. Billing must
first enroll it under its own freshly verified Google identity and accepted
billing disclosure. The broker cannot invert a route or create the billing
lifecycle. No new durable record contains UID, reversible UID encoding, email,
existing operator-entitlement document locator, token/fingerprint, Play account
route or order ID. UID remains in a freshly verified broker request only while
reading existing operator controls. Those existing v1 records are not migrated.

Broker App Check verification requires explicit `alreadyConsumed === false` from
`consume:true`. The locked Admin SDK normally returns a boolean. Tests of absent
or malformed injected adapter values enforce this contract; they do not establish
a live SDK exploit. Fresh/replayed synthetic tokens exercise the actual helper.

## Paired initialization and consent

Both databases have separate paired `control`/`initialization` records. Immutable
versions, cutover ID, key versions, revision and enrolled-account count must agree;
new reciprocal enrollment increments both once. There is no runtime initializer,
repair, TTL, key rotation, account transfer or zero-history adoption. Only pure
initial-record proposals are supplied for tests/review. Coherent loss of all
history cannot be detected by these markers alone.

Billing stores `playBillingBrokerBindings/{billingSubject}`,
`playBillingBrokerRoutes/{keyVersion_route}`, and an immutable optional root
`brokerBridge` marker atomically. A missing initialized side is unsafe. Binding
or reverse-route survivors beside an absent core root prevent ordinary lifecycle
creation. Ordinary core billing safety operations treat the known extension as
opaque, preserve it, and never read bridge controls. Malformed optional bridge
state cannot prevent core disclosure revocation or lifecycle retirement; it does
prevent bridge eligibility/projection. All original core invariants still apply.

Broker stores a stable account, reciprocal route and initialized authority
receiver atomically in `brokerCreditAccounts`, `brokerCreditRoutes`, and
`brokerCreditAuthority`. Explicit new bridge/research consent uses a revision CAS,
random assertion and bounded last-command receipt. Old acceptance cannot undo
newer withdrawal. Consent changes invalidate registration owners, retain authority
high-water and do not reset usage. Withdrawal can proceed without operator
admission or available bridge controls. A malformed optional snapshot is preserved
and blocked; missing/corrupt core reciprocal identity is not silently repaired.

The draft `paid-ai-bridge-consent-v1` processing purpose is linking a pseudonymous
subscription reference to paid online research and retaining its authority state.
It is not covered silently by prior research consent, and no mobile copy/UI or
production processing acceptance is delivered by this slice.

## Authority and registration

Billing projects the existing atomic authority/latest outbox into an exact bounded
4 KiB snapshot. It contains shared route/enrollment, epoch/generation/publication
revision, lifecycle/state/plan, original verification time and paid validity cap.
It excludes internal billing subject, token/fingerprint, product/order/Play route
and artwork. Paid validity ends at the earlier of Play expiry and billing consent
expiry. Nonterminal projection needs current matching billing consent; terminal
revoked/retired projections can remove authority without reacceptance. Digest is
canonical consistency evidence, not sender authentication.

The broker's injected transport must represent an authenticated service channel;
there is no production network implementation. Initial catch-up uses at most two
fresh challenge-bound reads per invocation, actual billing projection and actual
broker transactions. The first establishes a pending epoch/high-water, the second
may mark ready. Incoming complete snapshots never create an initial account.
Owner nonce, expected stage, generation, consent assertion/revision and current
admission policy fence each transition. A late first-read result/error cannot
regress or clean up an advanced second stage. Completion stores a bounded receipt
before removing the owner, so a committed response loss can retry without changing
verification time or counters.

Lower revisions are ignored, equal conflicting digests rejected, unfamiliar
routes/epochs/enrollments rejected. Generation G+1 is accepted only for terminal
retirement; paid G cannot return afterwards. Pending newer delivery defeats an
older final catch-up. Withdrawal/reaccept requires explicit fresh catch-up;
reacceptance alone never grants paid authority. A blocked completion receipt is
never usable merely because a row says ready.

Every invocation has a 50-second budget including identity and DB work. A remote
read has an immutable maximum 10-second child deadline. Nested calls cannot renew
it. Lost-response retries are separately authenticated invocations capped by the
unchanged original 90-second registration owner. Two reads is a per-invocation
bound, not a cumulative retry-cost claim. No real network adapter may activate
without separately reviewed durable admission/dispatch costs.

The admission-policy digest uses the canonical project/domain/policy ID plus
sorted approved apps and sorted broker-private owner subjects. Records never store
the raw UID allowlist. Membership changes need a new policy ID/coordinated control
update; no updater is included. Completed receipts bind the policy as well as
pending owners. Background apply can check policy/durable consent, but cannot
check the old per-UID operator entitlement without UID.

## Eligibility is not a spend permit

A fresh verified broker request rechecks current owner/app admission, operator
entitlement/breaker, current durable consent and ready authority transactionally.
After the transaction returns it also rechecks both sides of the time interval:
`verifiedAt <= now < min(verifiedAt + maxAge, validUntil, invocationExpiry)`.
An expired, canceled or clock-reversed result is unavailable. The returned frozen
primitive fence is read-only evidence; it has not reserved credits or authorized a
provider dispatch. Withdrawal after this transaction has already committed can
make that earlier fence stale. The monthly credit slice must reread consent,
operator controls and authority atomically at reservation and dispatch.

Production defaults are disabled/zero. Test defaults (60-second authority age,
20 account capacity) are synthetic; hard code ceilings are not production SLA or
capacity approval. No pricing, retention or allowances are approved here.

## Validation and remaining launch gates

`backend/bridge-test/credit_identity.test.mjs` is committed and runs after both
package builds. With a local Firestore emulator it uses genuine named billing and
default broker adapters, isolated demo projects, concurrent enrollment, actual
committed-response loss/retry, withdrawal during catch-up, terminal ordering and
core retirement with corrupt optional bridge state. Its emulator-only fixture supplies one deny-all rules configuration (the pinned
CLI skips rules when configured with multiple databases); explicit client tests
check default and named DB denial. Admin tests still use both genuine database
adapters. No production Firebase deployment configuration is modified.

L4-B still owns account-month reservations, original-month replay/refund/finalize,
upgrade allowance ceilings and v1 accounting cutover. Stable month ownership is
`(broker-account-v1, accountSubject, YYYY-MM UTC)`, with accepted no rollover and
no usage reset on upgrade. Financial-feed/order-aware reconciliation remains a
separate #194 launch dependency. Real transport/IAM/key provisioning, agreed
processing copy, retention/deletion/recovery, production capacity/freshness and
numeric pricing/credits, offline authority and Play-track validation remain gated.
Old strict-schema billing writers must be drained before any real enrollment.

## Disabled monthly accounting foundation

The separate [monthly credit contract](MONTHLY_AI_CREDITS_SPEC.md) connects the
actual broker to injected account-month reservation, dispatch and settlement.
It preserves v1 history and introduces an explicit global new-v1 cutover fence;
production activation and numeric/free/downgrade policy remain unapproved.
An L4-A eligibility response remains a read-only observation, not a spend permit.
