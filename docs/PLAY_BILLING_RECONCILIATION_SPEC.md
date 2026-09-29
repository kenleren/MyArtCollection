# Known-account reconciliation — disabled L3-A (#194)

The disabled L3-B1 [shared dispatch budget](PLAY_BILLING_DISPATCH_BUDGET_SPEC.md) now meters the injected processor through the same account/transport gate as foreground and events. It adds no reconciliation pump or production cadence.

This source slice adds atomic scheduling and an injected one-job integration.
It adds no Firebase export, runtime dispatcher, provider client, financial-list
transport, migration runner or public/mobile contract. Production construction
and polling remain closed. Independent payment/privacy output review is required.

## Schedule and authority

A newly prepared account creates `playBillingReconcileWork/{opaqueSubject}` and
its reciprocal root marker together. Work contains the lifecycle epoch/generation,
disclosure assertion, schedule revision, owner high-water, at most current and
candidate demands, bounded attempt timestamps, monotonic dispatch totals, and at
most one selected demand or completed response receipt. No raw UID, purchase
token, route or additional ciphertext is stored. Records are bounded to 8 KiB;
there is no TTL or reset path for these high-water records.

Existing custody staging, acknowledgement uncertainty, final publication,
consent changes and retirement update scheduling in the same transaction.
Account admission/owner bookkeeping alone does not reschedule a job. Existing
account authority/outbox and token/replay ownership remain authoritative. All
transaction proposals, including selected-pointer changes, update caller handles
only after a successful transaction return; callback retries cannot advance them.

A closed internal work union separates a real event owner from a reconciliation
owner. No RTDN event or Firebase UID is fabricated. Reconciliation request HMACs
have a separate domain and bind subject, epoch/generation, assertion, owner
nonce/generation and selected demand identity. Admission validates the durable
work record, current/candidate bindings and chain, index revision, disclosure and
account observation owner. The persisted authority source enum stays unchanged.

Selection uses an unresolved ACK token first. Otherwise a new unobserved due
candidate gets one observation, followed by an overdue current demand, followed
by candidate retry. A pending candidate cannot repeatedly starve current.
Ambiguous ACK never permits current to bypass its token. The only single-hop
switch is an already-closed canceled staged successor to its retained indexed
predecessor under the same job; it cannot bypass an ACK barrier.

An acknowledged current refresh uses fresh Play data but does not stage custody,
ACK again, promote a candidate or remove the candidate pointer. Contradictory
ACK evidence cannot use this branch. Candidate recovery keeps the existing
custody-before-ACK and linked-chain contracts.

## Completion and stale responses

Paid publication atomically closes account/token/replay ownership, updates
binding/index/authority/outbox, satisfies the selected demand and replaces the
working lease with a bounded completed-observation receipt. Inactive reconciliation
combines inactivity publication and operation close in that same transaction;
a non-current candidate may complete without changing authority publication.

Final validation is read-only and requires that exact receipt, current root/work
marker, epoch/assertion, disclosure, index, account observation, publication,
operation/replay and binding evidence. Paid also requires acknowledged current
custody and unexpired Play authority. A completed receipt grants no permission
to reserve calls, close attempts, retry, change scheduling or publish. New work,
semantic changes, revocation or retirement invalidate it. Processor cleanup after
terminal completion is a no-op.

These guarantees cover server commit and final-response validation. A response
already emitted and then delayed in transport cannot be retracted; the existing
mobile in-memory lease can outlive a newer server observation until refresh or
expiry. This slice adds no offline entitlement or downstream broker publication.

## Disabled policy and bounded source integration

No policy is configured by default. Synthetic tests inject an explicit validated
cadence (60 seconds or six hours in examples), 30-second retry and 15-minute
maximum retry. These are test values, not approved customer freshness or cost
limits. Claims use a 90-second lease, at most 12 starts per rolling day, safe
integer high-waters and fresh nonces on reclaim. Provider wrappers reserve durable
get/ACK/KMS totals before dispatch and impose per-job maxima of three GETs,
three custody calls and one ACK. Retry/reclaim preserves counters. A bounded
named-database due query returns at most ten rows; no automatic pump is exported.
Expired disclosure atomically blocks work. Exhausted daily attempts and temporary
account/token/ACK waits move the query due time to a finite next boundary while
retaining demand age and counters, so non-actionable heads do not starve later
accounts. Whole service execution and cleanup share the original absolute
invocation deadline; canceled cleanup does not wait behind held admission.
L3-B must add shared project quota reservations before any production use.

**Every inactive current result** (expired, revoked, on hold, paused or pending)
removes only its scheduling demand when no ACK barrier remains. The binding,
current pointer and encrypted custody remain. Candidate demand can still retry.
Explicit Restore, reacceptance or a new authoritative observation can recreate
current demand. This A slice therefore does not provide autonomous on-hold/paused
recovery coverage, and does not silently select indefinite post-expiry polling.
Those cadences and eligibility rules require an approved later policy. With an
ACK barrier still unresolved, its demand remains eligible for bounded recovery.

## Existing-state boundary

Only a genuinely new root with no orphan state initializes scheduling. A valid
old unmarked root returns existing v3 `recovery_required` for ordinary prepare,
verify, Restore and disclosure acceptance; no provider dispatch or implicit
initialization occurs. Missing/malformed/mismatched initialized work, partial
markers, orphan work or inconsistent core records return `unsafe_record` and
cannot reset counters. Legacy contracts are not converted by this slice.

Valid unmarked revoke/retire may still apply the existing non-paid authority
fence and atomically record a fixed exception in
`playBillingReconcileMigrationExceptions`. They leave work and marker absent and
cannot adopt old-generation custody. Initialized corruption cannot use this
exception path. An orphan exception without its root is unsafe historical state
and cannot be silently replaced by a new lifecycle. Retired accounts remain terminal; no identity deletion or new
account recreation feature is added.

Activation requires authoritative readback of the **exact named database and
core collections** proving empty/new state, or a separately implemented and
independently accepted migration with complete coverage evidence. A no-payments
attestation and an unpublished schema do not prove emptiness. There is no general
backfill runner, cursor, receipt ledger or coverage-counter machinery in L3-A.
Stop/drain incompatible old writers during the coordinated schema cutover.

## Remaining launch dependencies

Separate accepted work remains for common per-project quotas and a private
runtime pump, paginated void traversal and applied coverage, polling/retention/
deletion policy, provider provisioning and live operational evidence. Monthly
credits, broker entitlement application and offline access remain separate. No
retention duration, pricing, provider activation or public-launch claim is made.
