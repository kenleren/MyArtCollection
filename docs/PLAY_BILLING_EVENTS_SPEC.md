# Disabled Play event processing: L2 Stage B and F1

The disabled L3-B1 [shared dispatch budget](PLAY_BILLING_DISPATCH_BUDGET_SPEC.md) now composes physical event/account costs with foreground and reconciliation limits. It preserves this event history and removes first-use control initialization. This source change does not activate the worker.

This source adds a bounded RTDN inbox and retry worker for the account authority
engine. It is disabled, unprovisioned and not public-launch acceptance. The mobile
v3 contract is unchanged. No reconciliation sweep, void scan, broker publisher,
credit policy, offline lease or account-deletion workflow is included.

## Delivery and custody

`receivePlayBillingEvent` is a managed Firebase Pub/Sub function, not a public
webhook. The exact topic, source, event type, runtime identity and required
provisioning readbacks are in
`backend/play_billing/fixtures/event-deployment-contract.json`. Source/type checks
are defense in depth; IAM must authenticate actual delivery. The pinned SDK sets
the runtime service account, **not** the separate Eventarc trigger principal.
Private invoker, trigger identity and Scheduler authentication remain mandatory
human provisioning/readback gates. Nothing here establishes deployed IAM.

The implementation calls only subscription GET and ACK. This is a code restriction,
not method-only provider IAM. Google requires the Play Console permissions
“View financial data, orders, and cancellation survey responses” and “Manage
orders and subscriptions” for Billing API access. Provision the minimum grants
for this app and explicitly review their broader authority; do not describe them
as GET/ACK-only permissions. [Google API setup](https://developers.google.com/android-publisher/getting_started).

Disabled ingress rejects with a fixed error so managed delivery may retry;
disabled pump is a no-op. Invalid configuration fails before Firebase, ADC, KMS or
Publisher construction. Every budget defaults to zero, and the source-controlled
approved event KMS version allowlist is empty. Enabling environment flags alone
cannot activate this source. A reviewed provisioning change must bind exact full
key versions; no key material is held in the fixture.

The SDK parses the CloudEvent before application code. Application checks at most
16 outer properties, 8 data/message properties, 256-byte IDs/source, 8 attributes
with 128-byte keys/512-byte values, canonical base64 at most 10,924 characters and
at most 8,192 decoded bytes before UTF-8/JSON parsing. The byte-bounded JSON then
has depth 8, 64 properties, arrays 16 and strings 4,096 UTF-8 bytes. `message.json`
is never used. Exactly one subtype and the app package/version are required.
Known subscription types request fresh verification; unknown integer types keep
an encrypted token in blocked work. Test notifications make no provider call.
One-time and refund-review notifications have explicit blocked,
non-granting categories. With the full-void opt-in absent, void notifications also
retain the original blocked v1 behavior. The disabled F1 extension below handles
only new, known-token full-subscription void work. Pending-refund credentials, order IDs, routes and full
payloads are never retained. Package-list and full refund coverage remain launch dependencies.
The [official RTDN reference](https://developer.android.com/google/play/billing/rtdn-reference)
is the notification schema, not entitlement authority.

An event ID is HMAC(topic + message ID); SHA-256 binds the decoded payload. A
transaction reserves an owner and one capacity slot before encrypting the token.
The slot is never refunded on uncertain encryption, blocked work or completion.
Equal durable duplicates return without another encryption. Conflicting digests
fail. A reserving record without ciphertext requires matching authenticated
redelivery after its lease expires: a pump cannot invent the missing token.
Partial loss of capacity/budget/marker, or loss of all controls while work exists,
fails instead of resetting counters. No TTL/decrement/cleanup is introduced.

The event envelope is `play-event-token-custody-v1`; AAD is ordered UTF-8 JSON
`[purpose, package, database, eventFingerprint, payloadDigest, tokenFingerprint,
exactFullCryptoKeyVersion]`. The full retained version is reconstructed on decrypt,
so relabelling same-key ciphertext fails. Event ciphertext cannot be used by app
Restore. Verified promotion freshly encrypts under the account's epoch-bound AAD.
Records have exact bounded fields and remain below 12 KiB; raw tokens are only
transient process memory. Fixed error classifications contain no provider payload.

## Work ownership and authoritative observations

`pumpPlayBillingEvents` selects at most 10 due ready/retry/expired-working rows,
runs at most two jobs together and has a 50-second total budget. Working records
use their 90-second lease expiry as the due time. Reclaim increments generation
and nonce, retaining dispatch totals and bounded attempt history. The old owner
cannot charge, bind, complete, grant or publish after reclaim. Retries use 30-second
exponential backoff capped at 15 minutes, with injected bounded 0–5 second jitter.
Six attempts/hour and twelve/day are ceilings; exhaustion blocks work. Duplicates
do not reopen it. There is no operator requeue/reset endpoint in this slice.

Known token custody provides a bounded account route. An unseen token uses one
reserved discovery GET and bounded direct/linked/expired-context lookups; all
available signals must agree. The job durably records opaque subject and exact
lifecycle epoch/generation before account admission and a second, authoritative
GET. No Firebase UID, email lookup or invented account is used. A superseded-token
event rechecks current account custody rather than revoking a newer chain.
Resolved work never adopts a new epoch. Root/disclosure/route and job-owner fences
apply before dispatch and on account transactions; retirement/revocation cannot
be overcome by delayed work.

Bindings gain exact `play-ownership-proof-v1` metadata: direct route, linked
binding or expired context. Proofs are established from the fresh admitted GET and
same-subject lifecycle records before delivery/ACK. Present conflicting identifiers
reject. Once established, a same-token proof permits an acknowledged response to
omit transient expired context; an older binding with no proof cannot use that
fallback. Stop/drain all old foreground/event writers before this schema cutover;
running old writers against richer bindings is unsupported.

For expired out-of-app resubscription, a competing current chain requires a fresh
GET that actually reports expiry. An in-process proof is tied to the admitted
attempt object, selected/current tokens, account observation generation, index
revision and a 15-second freshness bound. It is never serialized. The guarded
commit atomically clears an expired unrelated current when staging new custody.
Pending/ambiguous ACK continues to block unrelated token observations. Only
verified expired-context resubscription sends the exact ACK body
`externalAccountIds.obfuscatedAccountId`; ordinary ACK stays empty. After a lost
ACK response, retry freshly reads Play before deciding whether another ACK is
needed. [Publisher ACK contract](https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptions/acknowledge).

Atomic authority/snapshot/outbox behavior remains Stage A. A notification or a
404/410 never independently grants or revokes. An already final-validated/emitted
v3 response and its existing 15-minute memory lease cannot be retroactively
retracted by this worker; seven-day offline/client invalidation is separate work.

## Cost and transport limits

Each external call is reserved durably before dispatch, without refund after an
uncertain result. Background uses separate operator budgets, never foreground AI
credits or subject quotas. The disabled synthetic ceilings are 120 admissions and
120 GETs/15 minutes (at most 30 discovery), 60 KMS and 30 ACK, and 20,000 retained
work rows. Each job invocation allows at most three GET, three KMS and one ACK.
These are testable limits, **not approved production capacity, spend or retention**.

Publisher transport reads at most 64 KiB decompressed JSON, depth 12/properties
256/arrays 16/strings 4 KiB, and drains at most 4 KiB ACK response. It rejects
redirects and does not retry internally. Each call has a 10-second bound within
its caller's absolute deadline and cancellation signal, including auth, headers
and body. KMS uses the same parent cancellation fence. HTTP 401/403 opens a durable
circuit; Publisher 409/429/5xx/network errors use a later fresh retry. Provider
error text, bodies and headers are not persisted or surfaced.

## Remaining production decisions and evidence

Unit and named Firestore emulator tests exercise reservation/capacity loss,
reclaim, cross-token admission, purpose/version substitution, unseen/linked/expired
recovery, lost ACK, retirement, transport bounds and disabled SDK entrypoints.
They do not establish real IAM, Play field availability, KMS permissions or delivery.

Retention of unmatched/expired tokens, disclosure for encrypted unknown-event
custody, consent pause/deletion/support handling, approved cohort/spend/capacity,
alert/runbook ownership and pricing remain owner/privacy decisions. Finite source
caps do not authorize indefinite retention. A total DB/KMS outage before durable
custody can outlast managed delivery's retry window and lose the notification;
there is no lossless-total-outage claim. Production gates include private IAM and
key-version readback, real purchase/RTDN/ACK/late-resubscription evidence, outage and
rollback rehearsal, L3 reconciliation/void coverage, broker/credits/deletion and
approved offline access. This source does not close #194 or authorize paid launch.


## F1: order-aware full-subscription voids (disabled)

`PLAY_BILLING_FULL_VOID_ENABLED` accepts only absent/`disabled` (false) or
`enabled` (true); malformed values reject before dependency construction. The
existing event, custody, key allowlist and common-budget gates still apply. This
extension adds no function, schedule, provider endpoint, permission or budget
allocation. Source defaults and the deployment fixture remain disabled.

A new supported notification uses `play-event-work-v2`. The order is a nonempty,
canonical UTF-8 string of at most 1024 bytes without control characters. Positive
and zero int32 product/refund values are accepted for classification; only product
1/refund 1 is supported. Product 2 is explicitly one-time, quantity refund 2 is
unsupported, and unknown enum values are quarantined. Those dispositions retain
fingerprints and classification without token encryption or provider work.

Legacy recognition precedes new admission validation. The baseline parser still
computes message identity and raw payload hash under its original bounds. An
exact retained v1 duplicate (including old empty/control/long orders or negative
safe-integer enums) keeps its terminal record unchanged; expired reserving v1
work follows the original reclaim path. New v2 admission rejects those malformed
values. Flag-disabled new work preserves v1 behavior. This is compatibility, not
permission to enrich or promote old blocked voids.

Raw order IDs never persist. `financialOrderFingerprint` uses HMAC domain
`archivale-play-financial-order-v1` over `[package, orderId]`. Canonical semantic
SHA256 binds financial version, package, order/token fingerprints and enums.
Message-key replay protection separately retains the original payload hash.
`playBillingFinancialOrders` holds one immutable full-subscription order anchor
pointing reciprocally to its canonical event. Owner/alias/conflict/quarantine are
closed roles; same-order different-message duplicates are aliases, while changed
token or contradictory known product type is a conflict. Partial events remain
independent and do not suppress a later full event. Different renewal orders
sharing a token remain distinct.

Anchor and canonical event are created atomically with one existing event-capacity
slot; aliases/conflicts consume one ordinary message slot each, without new
custody or provider dispatch. Existing lifetime row bounds also bound anchor
count. The declared named-database index queries order fingerprint plus role
(owner/alias/conflict), limit one, before recreating any absent anchor. Missing
reciprocal state rejects; no counter reset, TTL, deletion or repair is introduced.
Coherent loss of an anchor and all its reciprocal history is not detectable from
a global row count alone. A reserving crash still requires original matching
message redelivery; another-message alias cannot invent or repair its ciphertext.

Only canonical supported owners enter the existing event pump. They decrypt the
existing purpose-separated event envelope, resolve an already bound token to its
account/epoch, and call the actual account Restore verifier **regardless of whether
the historical token is superseded**. No financial-token discovery GET occurs in
F1. Unknown tokens remain blocked/unresolved, not confirmed non-subscription or
verified financial coverage. Current index, chain and ACK barriers select the
actual purchase to verify. An old renewal's void can correctly finish with current
paid authority; neither notification metadata nor historical token expiry writes
entitlement or AI-credit accounting.

All physical KMS/GET/ACK calls use the existing event source, immutable dispatch
tickets, common and legacy ledgers and original deadlines. Reciprocal financial
ownership is reread before metered actions and account work. No new ledger version,
initializer or cost pool exists. Consent, retirement, index, epoch, account-wide
observation and deferred-auth fences remain authoritative. Safety-only disclosure
revoke/retire do not read optional financial records.

A canonical owner is completed if and only if it has a valid
`play-financial-verification-v1` receipt. Generic event `finish(completed)` rejects
these owners. Only `finishFinancialObservation` can atomically record completion:
it rereads the current root/disclosure/index/authority/outbox, exact event owner
and anchor, and requires the matching background operation's completed authority.
Its fixed receipt records opaque subject/epoch, request fingerprint, observation
and publication revisions, snapshot digest, verification time and paid or explicit
inactive outcome. It is not a continuing grant, order attribution or refund ledger.
Newer authority/withdrawal wins; a crash after authority commit before receipt may
require a later budgeted fresh verification. A post-commit response delay cannot
undo already committed database state.

Disabling the flag stops/reclassifies pending reserving/ready/retry/working owners
when encountered. Completed owners with receipts and terminal aliases/conflicts/
quarantines remain immutable exact duplicates. No automatic rearming follows a
flag change. Historical blocked v1 voids and new disabled pending rows require an
explicit coverage/recovery inventory before activation; no-payments attestation
is not database emptiness or permission to reset them.

F1 tests use synthetic auth/fetch behind actual runtime/transport/dispatch classes
and the named Firestore emulator. They establish source behavior, not live Play,
IAM, delivery, refund or operational acceptance. Package-list fixed-window paging,
RTDN/list convergence, unknown-product/token recovery, retention/deletion, approved
capacity/cadence and real provider/store evidence remain separate launch work.
Non-revoking refunds are not covered by the void-list API either. No refund,
ReviewRefund or sharing of usage evidence is implemented or authorized.
