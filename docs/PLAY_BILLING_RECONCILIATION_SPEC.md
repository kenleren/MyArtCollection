# Known-account reconciliation — disabled L3-A/B2 (#194)

The L3-B1 [shared dispatch budget](PLAY_BILLING_DISPATCH_BUDGET_SPEC.md) meters every reconciliation dispatch through the same account/transport gate as foreground and events. B2 adds a disabled scheduled adapter and bounded cohort reporting; it supplies no approved production polling policy or activation.

The A foundation supplies atomic scheduling and an injected one-job integration.
B2 composes that processor into a scheduler without changing account authority,
financial-list transports, migration or public/mobile contracts. Production polling
remains closed. Independent payment/privacy output review is required.

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
named-database due query returns at most ten rows. B2 now exports the disabled pump described below.
Expired disclosure atomically blocks work. Exhausted daily attempts and temporary
account/token/ACK waits move the query due time to a finite next boundary while
retaining demand age and counters, so non-actionable heads do not starve later
accounts. Whole service execution and cleanup share the original absolute
invocation deadline; canceled cleanup does not wait behind held admission.
B1 supplies shared project reservations; its separately approved cutover and allocations remain activation gates.

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


## B2 disabled scheduled adapter

`pumpPlayBillingReconciliation` is a scheduled SDK export with a 60-second function timeout, one instance/concurrent invocation, no managed retries and a source-only `every 1 minutes` UTC registration. These are disabled implementation/test settings, not production cadence or infrastructure approval. Scheduler authentication and service-scoped invoker IAM require separate provisioning/readback; the runtime account option and Scheduler headers do not prove caller identity. Deploying even a disabled schedule has infrastructure cost and is not authorized by source acceptance.

`PLAY_BILLING_RECONCILIATION_CONFIG` is absent by default. The exact enabled JSON is `{version:"play-billing-reconciliation-runtime-v1",enabled:true,policy:{activeMs,retryMs,maxRetryMs}}`; exact disabled JSON contains only version and enabled:false. Input is bounded to 1 KiB. The existing policy bounds are parser ceilings: activeMs 60,000–86,400,000; retryMs at least 15,000; maxRetryMs at least retryMs and at most 3,600,000. The retained 12-starts-per-day admission limit still constrains achievable cadence. No production values are supplied.

All three factories use `createReconciliationAwareBillingRuntime`, which parses the same optional policy before delegating to the actual shared factory. Missing/malformed optional policy never prevents foreground payments or fail-safe accept/prepare/revoke/retire. Safety-only construction still performs zero budget reads. Constructing a runtime does not change existing ready or policy-blocked records. Only existing semantic transactions reschedule; with no valid policy they preserve counters/history and follow existing blocked/policy-blocked/retired behavior. No background scan enrolls old policy-blocked/unmarked accounts or repairs unsafe markers.

The scheduled configuration gate runs before secrets, Admin, database or ADC construction. Disabled is a quiet no-op. Enabled requires exact project, existing routing/recovery/Publisher/account-custody flags, valid key syntax, and a valid common configuration with positive global/reconciliation GET/ACK/KMS dimensions. Missing/partial/corrupt/open durable controls fail closed before due selection. Key syntax is not provisioning approval. The scheduled factory needs account custody, not event ciphertext keys or a fabricated RTDN. An internal dependency-loading seam tests this actual factory with synthetic transports.

One absolute 50-second invocation starts before configuration/loading/control reads. Query/control operations remain bounded by ten seconds and the remaining invocation budget. Exactly one indexed query selects up to ten ready/retry/working rows ordered by dueAt and document ID. The projection returns only subject, due date and optional last-success date internally. Claims remain authoritative and re-read current root/work/consent/index/authority. Query metadata never grants work. A concurrent success newer than the query cutoff gives unknown advisory lag rather than invalidating an otherwise valid cohort.

Jobs run serially, each subject at most once, sharing the original deadline; no further job starts with less than five seconds remaining. There is no drain loop, cursor, global lock, independent provider budget or inline retry. Existing 90-second leases/new owner nonces support overlapping callbacks and crash reclaim. Expired consent blocks due work; temporary owner/cooldown waits and daily-budget exhaustion move dueAt to a future boundary. Budget denial can consume a genuine job admission and cause bounded retry, but refunds or resets no counter. Neither exhausted allocations nor corrupt records carry a fairness/freshness guarantee.

Classification is deadline-first, then `reason:unsafe_record` before any status count, then typed unsafe exceptions. Unsafe stops the batch. Any other thrown process error stops partial_failure without inspecting its message. Other returned statuses may continue under the existing per-job fences. Only none with expired/on_hold/paused/revoked counts as inactive; other none results have a separate count. Undefined, unavailable and best-effort cleanup prove neither integrity nor durable deferral. Scheduler rejects only fixed sanitized failure text, with retryCount zero; later wakes alone may reclaim durable work.

## Bounded cohort observability

At most one summary contains only fixed version/outcome, counts bounded to ten, and coarse timing buckets. Counts cover selected/started/not-started, unclaimed, paid, explicit inactive, other none, pending, unavailable, rejected and errors. Lag buckets describe only the query-time selected cohort; concurrent metadata can already be stale. No subject/token/fingerprint, request ID, product, key path, generation, nonce, raw error, response field or exact timestamp reaches logs. The underlying scheduler SDK logs exception messages, so all escaping messages are fixed locally.

Reporting is best-effort and bounded to min(250 ms, original remaining time), with the original cancellation signal. Rejected/late observer failures are absorbed; a held observer cannot extend work or launch retries. Reporting timeout alone does not change a successful batch; original invocation expiry takes precedence. A successful run means only its selected cohort was visited, including possible skips/failures. Empty selection proves only no matching initialized due rows at that instant.

Global freshness, blocked/policy-blocked population, migration-exception totals and complete enrollment coverage are **unmeasured**. There is no extra scan, count aggregation or health collection. Activation requires approved actual cadence/allocations/headroom/alerts and exact named-state coverage: verified new state or an independently accepted migration/enrollment procedure. No-payments attestation is not emptiness. Existing inactive-current polling limits, retention choices, total-outage gaps and emitted-response/mobile-lease limitations remain unchanged.

Validation uses actual construction/transport seams, strict config/SDK export checks, reason-first health tests, synthetic races, and named Firestore emulator queries. B2 emulator cohorts use explicit isolated demo projects with the same named database so they cannot select another worker's accounts or reset its singleton control history. One isolated factory/pump-versus-foreground test retains actual shared gates and durable last-unit accounting; simpler lifecycle/query tests deliberately use synthetic providers and do not claim metering proof.
