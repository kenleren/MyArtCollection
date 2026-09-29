# Disabled Play event processing: L2 Stage B

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
One-time, void and refund-review notifications have explicit blocked,
non-granting categories. Pending-refund credentials, order IDs, routes and full
payloads are never retained. Full void/refund handling remains a launch dependency.
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
