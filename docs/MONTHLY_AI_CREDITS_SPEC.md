# Monthly AI credits: disabled injected L4-B foundation

This source connects account-month accounting to the actual `handleResearchRequest`
flow using an injected provider. No production export, mobile path, provider
adapter, endpoint, deployment or allowance is enabled. Missing/false configuration
returns before dependency construction. Zero allowances and global caps deny
spending before provider preparation. Tests use synthetic 2/4/6 allowances only.

The accepted product decisions are UTC calendar months, no rollover and upgrades
raising that month's allowance without resetting usage. This implementation's
proposed downgrade rule preserves the highest eligible paid allowance seen during
that month while requiring current paid authority for each new spend. Free,
expired or revoked authority cannot spend that ceiling. Numeric allowances,
prices, paid downgrade/free policy and production activation remain unapproved.
The local archive remains account-optional.

## Actual identity and broker boundary

An internal `createMonthlyBrokerSession` authenticates a fresh App Check/Auth
request using `CreditIdentityService`. It snapshots the canonical request before
awaits and creates a request-bound v2 lifecycle. A prior `evaluate()` result is
never a spending permit. The identity service's same transactional eligibility
reader is used by evaluate and by monthly admission.

Reservation and dispatch each read current identity/reciprocal consent/authority,
operator entitlement, admission policy, accounting controls and breaker in the
same default-database transaction as accounting. Dispatch follows awaited provider
configuration/construction/authorization, then performs its new authority read.
Original verification age, paid validity, lease, invocation deadline and rollback
lower bounds are checked again after the final transaction result and immediately
before invocation. Consent changes that overlap the transaction contend/retry;
this does not promise atomic revocation after its completed read or undo an
already dispatched provider call.

The v2 discriminated dispatch hook replaces the old mark/provider block. Unknown
intent or an unexpected hook failure returns a fixed unknown outcome; it cannot
enter v1's generic dispatch-persistence refund catch. The actual captured request
is invoked once, without an await between final validation and consumption.
A future live adapter awaiting credentials or headers inside `research()` still
needs its separately reviewed physical-fetch fence. This source does not claim
that future network boundary is implemented.

## Durable ownership and counters

The broker-private account subject is independent of app, install, billing plan
and month. The request fingerprint HMAC binds project, account and request UUID;
a second approved app sees the same accounting and replay. A changed canonical
payload hash conflicts. No new accounting row contains raw UID, reversible UID
locator, artwork input, Play token/order ID or routing key. The bounded terminal
research result follows the existing broker outcome contract.

Strict v2 records live in `brokerMonthlyControl`, `brokerMonthlyAccounts`,
`brokerMonthlyMonths`, `brokerMonthlyGlobalMonths`, `brokerMonthlyRequests`,
`brokerMonthlyLedger` and `brokerMonthlyReplayShards`. They never relabel v1
history. Exact parsers, canonical digests and numeric/document limits are defined
in `monthly_credit_protocol.ts`.

- Paired global controls retain global lifetime totals and every initialized
  global-month head. Account roots retain month heads and 16 replay-shard heads.
- The L4-A account's opaque `monthly` marker mirrors the monthly root revision
  and digest. Its revision is separate from identity/consent/registration
  revisions. Consent acceptance/withdrawal preserves even a malformed marker
  without reading accounting; malformed accounting still blocks spending.
- Original request month is selected from server UTC. If awaited admission reads
  cross into another month before the final callback check, the new reservation
  aborts with no writes. An already reserved request may dispatch on its short
  original lease across midnight. Replay and late settlement always use that
  original month. A commit after a valid callback is not made atomic with wall
  clock; delayed result checks can reject a response without undoing its commit.
- Each month stores a monotonic allowance ceiling and reservation/dispatch starts,
  finalized/refunded counts, reserved and exposed credits. Exposure equals starts
  minus refunds; reserved equals starts minus finalized minus refunds. Upgrades
  raise the ceiling, never reset counters. Global/account/month totals update
  together in the same transaction.
- A single durable account in-flight pointer binds fingerprint, original month,
  ordinal, owner nonce, lease and phase. Requests across apps/months contend on
  it. Unknown dispatched work retains pointer and exposure. Terminal persistence
  alone does not release it; completed settlement does.
- Append-only bounded replay shards retain original month/ordinal/hash, detecting
  disappearance of both request and ledger when the receipt survives. Missing
  initialized heads, rows or reciprocal markers fail closed; no runtime reset.

Engineering ceilings are 1,000 starts per account-month, 240 represented months,
16 shards of at most 2,048 receipts per account, 256 KiB encoded documents and
safe-integer bounded policy caps. These are source limits, not retention approval,
a customer capacity promise or an erasure strategy. No TTL/compactor is added.
Coherent removal/rollback of all mutually witnessing records cannot be detected
by these markers; no whole-database recovery guarantee is made.

## Explicit v1 cutover

The internal new-state procedure derives legacy references from the same
`FirestoreDurableBrokerStore` namespace used by v1. Defaults are
`brokerDurableControl/live` and `brokerDurableControl/globalUsage`. The actual
adapter's bound prefix must match the requested prefix before work starts.

A strict `monthlyCutover` witness on the existing required live control is written
atomically with the monthly control/initialization pair. The procedure checks
empty v1 accounting with bounded queries and never deletes or migrates history.
It is not called by normal acquisition and has no network/export entrypoint.
Nonempty legacy history requires a separately accepted migration.

The new-v1-acquisition branch reads the same live control and both monthly
records. Original live control plus absent monthly pair keeps pre-cutover v1
behavior. Matching three-way cutover rejects all NEW v1 requests; missing,
partial or mismatched witnesses reject as unsafe. Both monthly controls
disappearing cannot reopen v1 while the independent live witness survives.
Existing v1 replay and settlement remain available. Contention with the existing
live-control/global-usage transaction makes a concurrent v1 reservation either
win before cutover (which then rejects nonempty state), or retry and see the
cutover fence. Old binaries ignoring this fence remain an activation blocker.

Because v2 is paid-only, global cutover stops NEW free/research requests too.
This is an explicit unapproved activation consequence; the source does not
silently continue a free tier. Continuing free AI needs a separately selected
policy/path. Production requires authoritative database evidence and reviewed
cutover, not merely a no-payments attestation or a supplied evidence hash.

## Intent, outcomes and bounded cleanup

Admission has an original maximum 50-second budget. Reservation lease is capped
by that budget, authority age and paid validity. Dispatch intent consumes
irreversible dispatch-start capacity before the provider call. A missing commit
response never proves the intent failed, and no invocation repeats a fetch.
Exact in-process ownership proving a ticket was never consumed can attempt a
no-dispatch refund; unavailable/ambiguous cleanup leaves exposure intact.

Known normalized provider timeout/rate-limited outcomes retain the existing
customer-credit refund policy after durable terminal persistence. Success,
refusal, failure and invalid output finalize. Refund never restores dispatch-start
capacity. A process/result disappearing after intent stays unknown, reserved and
exposed; time alone does not authorize refund or redrive.

Known terminal/no-dispatch cleanup has a separate absolute 20-second budget,
shared by terminal persistence, settlement and at most one read-only confirmation
total across both operations. It binds the exact immutable request/owner/month and
cannot call a provider. Current consent/paid eligibility/operator denial or an
admission breaker cannot strand structurally valid cleanup. Missing/corrupt
accounting still blocks it safely. A fresh authenticated replay can settle an
already durable terminal result with a fresh bounded cleanup attempt, without
renewing dispatch authority. Different terminal outcomes cannot overwrite each
other; a lost settlement result cannot decrement counters twice.

A retained process may submit a late known provider result through that cleanup
path. Waiting on the provider is bounded by the original invocation; late cleanup
is best effort, not a durable worker or eventual-settlement guarantee. Total
outage/process loss, unresolved unknown exposure, retention/erasure and operational
recovery remain separate launch requirements.

## Validation and remaining gates

Focused tests use the actual token verifier/identity registration and actual
broker orchestration. The cross-package harness uses actual Play billing
verification/projection, broker recipient and monthly store, with synthetic
providers. Local named/default Firestore tests exercise real transactions,
cutover races, last credit, withdrawal, replay loss and cleanup response loss.
They are not live Play, AI-provider, deployed IAM or mobile acceptance.

Independent payment/privacy review and exact source/evidence acceptance are
required. Customer policy, private bridge delivery, physical provider dispatch
metering/fences, operational recovery and the remaining financial-feed billing
reconciliation requirements are still separate gates. No public-beta or whole
billing completion follows from this disabled source slice.
