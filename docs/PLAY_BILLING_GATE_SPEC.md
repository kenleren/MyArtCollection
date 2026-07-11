# Play Billing Gate Spec

Status: review-ready documentation contract; implementation and deployment remain gated
Issue: #190
Date: 2026-07-10

## Scope And Authority

This is the canonical contract for Archivale's internal-track Android
subscription verification. It defines the boundary consumed by #191 (server),
#192 (mobile adapter and lease), and #193 (subscription UI). It does not
authorize implementation, Play or Firebase mutation, a purchase, credential
access, deployment, or public paid rollout.

Google Play is the payment-state authority. The server verifies current Play
state, durably commits the verified entitlement delivery, acknowledges that
delivery, and only then returns a short result. The mobile app holds that
result only as an in-memory lease. No client claim, local plan selection,
Firestore record by itself, AI broker entitlement, or cached purchase object
can prove current payment.

The initial contract is deliberately internal-track only. Issue #194 is a hard
gate before any closed, open, or production paid rollout.

## One-Project, Separate-Database Isolation

`my-art-collections` is the only approved Firebase/GCP project. Earlier
proposals that require another Firebase project for paid AI or Play Billing are
obsolete. Billing is isolated inside the shared project by all of these
boundaries:

| Surface | Billing-owned contract |
| --- | --- |
| Source directory | `backend/play_billing` |
| Functions codebase | `play-billing` |
| Callable functions | `acceptPlayBillingDisclosure`, `revokePlayBillingDisclosure`, and `verifyPlaySubscription`, v1 |
| Region/runtime | `us-central1`; Node.js 22; 60-second function timeout |
| Runtime identity | Dedicated billing-verifier service identity, distinct from the research broker identity |
| Firestore database | Named Standard/Native-mode database `archivale-play-billing` in `us-central1`, with delete protection enabled; never `(default)` |
| Durable collections | `playBillingDisclosureAssertions`, `playBillingPurchaseBindings`, `playBillingRequestReplays`, `playBillingTokenOperations`, `playBillingRateLimits` |
| Secret use | Server-only fingerprint key with an explicit version; never available to mobile or the research broker |
| IAM | Database-scoped verifier access plus Android Publisher read/acknowledge only |
| Client access | Deny all reads and writes through Firestore Security Rules, including authenticated anonymous clients |
| Rollback target | Billing callables/codebase, runtime IAM, and named-database rules/IAM; database deletion is not routine rollback |

The verifier receives `roles/datastore.user` only with an IAM condition whose
resource expression is exactly:

```text
resource.name ==
  "projects/my-art-collections/databases/archivale-play-billing"
```

The effective runtime policy must contain no unconditional, inherited, group,
or service-agent grant that gives the verifier access to `(default)` or another
database, and it must not receive `roles/datastore.owner`. The broker runtime
must have no grant to
`archivale-play-billing`; if it needs a project-level Firestore role, that role
must exclude the billing database with a reviewed database condition. Human
operator/deployment roles are separately governed and are not runtime
authority.

The billing database uses a database-targeted deny-all client ruleset:

```text
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /{document=**} {
      allow read, write: if false;
    }
  }
}
```

Server/Admin libraries bypass Security Rules and are controlled by IAM, so
both layers are mandatory. #191 must own the database ID constant, explicit
client construction for that named database, rules target, indexes/TTL target,
static/fake/emulator negative tests, and rollback fixtures. Deployment evidence
must prove anonymous and authenticated clients cannot read/write billing data,
the broker identity cannot access the billing database, and the verifier
identity cannot access broker, artwork, attachment, or other default-database
records.

The verifier must never read or write `brokerDurableEntitlements`, broker
credits, broker requests, artwork records, or attachment records. Conversely,
the research broker has no read/write authority over the billing database and
no payment authority.

Because the project is shared, project-wide billing disablement is not an
isolated billing or AI kill switch. It can disrupt Auth, App Check, App
Distribution, telemetry, billing verification, and the research broker. Use
function/codebase, database-scoped IAM, and provider-specific controls first;
any project-wide action remains an explicit human-owned last resort.

## Billing Disclosure Is A Separate Server Gate

When a collector initiates purchase or restore, the app must first show the
source-controlled `billing-verification-disclosure-v1` copy. Acceptance
authorizes the app to create or reuse anonymous Firebase Auth for
`my-art-collections` and obtain App Check only for subscription verification
and entitlement refresh.

That disclosure:

- does not create, imply, or satisfy AI research consent;
- does not enable `online_research_enabled` or authorize a broker request;
- does not authorize artwork images, metadata, notes, documents, or research
  hints to leave the device;
- does not turn the anonymous UID into a Google Play or Archivale account; and
- is required independently of whether the same anonymous identity is later
  reused after separate, current-version research consent.

Auth and App Check do not prove acceptance. After the collector affirmatively
accepts the displayed copy, the official app calls
`acceptPlayBillingDisclosure` with exactly:

```json
{
  "requestId": "canonical-lowercase-uuid",
  "disclosureVersion": "billing-verification-disclosure-v1",
  "purpose": "play_subscription_verification",
  "accepted": true
}
```

The callable accepts only literal `accepted=true`, verifies project-bound
revoked Auth, consumes a fresh approved-app App Check token, derives the account
subject, and creates the server-owned `billing-disclosure-assertion-v1` record.
It makes no Android Publisher call and accepts no purchase token. Firestore
clients cannot create this record.

The assertion is keyed by account subject and contains only contract version,
account subject, exact disclosure version, exact purpose, accepted/status
timestamps, `status=accepted`, and
`retentionExpiresAt=acceptedAt+365 days`. Use does not extend expiry. A new
disclosure version requires a new affirmative acceptance. Revocation/account
deletion changes status to `revoked` before deletion and sets cleanup no later
than 30 days; a revoked record is never accepted. Broader durable-account
deletion remains #194 work.

`revokePlayBillingDisclosure` accepts only canonical `requestId`, current
`disclosureVersion`, and exact purpose through verified Auth/consumed App Check.
It atomically changes the current subject's assertion to `status=revoked` and
sets cleanup no later than 30 days. It makes zero Play calls. A missing record
is an idempotent no-op; an account/purpose/version mismatch fails closed.

Every `verifyPlaySubscription` request declares
`billing-verification-disclosure-v1`. Before any Android Publisher call, the
server recomputes the account subject and requires the current, unexpired,
accepted, purpose-matching assertion. Missing, stale, expired, revoked,
research-only, wrong-purpose, malformed, or unknown-version assertions return
Free with `disclosure_required` and zero Play calls. Acceptance is never
inferred from UID existence, research consent, App Check, a purchase, a prior
lease, or a request field alone.

## Fixed Product Contract

The implementation must use this source-controlled allowlist. An empty,
runtime-configured, wildcard, or unconfirmed allowlist fails to Free.

| Archivale plan | Package | Product ID | Base plan ID | Allowed offer ID | Planned price | Active artworks | AI credits |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Starter | `app.archivale` | `archivale_starter_monthly` | `monthly` | absent | USD 2.99/month | 50 | 10/month |
| Collector | `app.archivale` | `archivale_collector_monthly` | `monthly` | absent | USD 4.99/month | 200 | 50/month |
| Archive | `app.archivale` | `archivale_archive_monthly` | `monthly` | absent | USD 9.99/month | Unlimited | 200/month |

The response `planId` values are exactly `starter`, `collector`, and `archive`
for those rows.

Only auto-renewing subscriptions are accepted. Prepaid plans, add-ons,
discounted offers, unknown products, another base plan, or a present `offerId`
are outside this v1 contract and fail to Free. Planned prices are not verified
from the client request and are not returned as trusted server data; the human
Play Console owner must make the configured products match this table before a
test purchase.

Free remains USD 0, with 5 active artworks and 1 AI credit per month. Active
artwork caps limit only creation of new active artworks. Every plan and every
downgrade preserves view, edit, report, and export access to existing records.
AI credits never gate manual cataloging or existing-record access.

## Callable V1 Contract

`verifyPlaySubscription` accepts only this JSON body:

| Field | Rule |
| --- | --- |
| `requestId` | Required canonical lowercase UUID; used for replay and client-generation fencing |
| `billingDisclosureVersion` | Must equal `billing-verification-disclosure-v1`; the durable server assertion remains authoritative |
| `productId` | Required string but untrusted; it must match the queried successor product, not necessarily a canceled-pending predecessor |
| `purchaseToken` | Required non-empty Play purchase token; request-memory only |

Firebase Auth and App Check arrive only through verified callable context. The
body must not accept a UID, App Check token, Auth token, package override,
account binding, plan, price, entitlement, expiry, acknowledgement state,
linked token, account subject, token fingerprint, or client generation.
Unknown or malformed fields fail to Free before a Play call.

The app sends the Auth-derived account binding to Google Play when it launches
the billing flow:

```text
base64urlNoPad(
  SHA-256(UTF8("archivale-play-account-v1\n" + auth.uid))
)
```

The output is the 43-character, unpadded base64url SHA-256 digest. #192 passes
that exact value through `setObfuscatedAccountId`. #191 recomputes it from the
verified Auth UID and requires exact, case-sensitive equality with
`externalAccountIdentifiers.obfuscatedExternalAccountId` from the independently
queried purchase. Missing or unequal values fail to Free.

The server derives three non-reversible storage identifiers with a server-only
HMAC key:

```text
tokenFingerprint = hexLower(
  HMAC-SHA-256(key, UTF8("archivale-play-token-v1\n" + purchaseToken))
)

accountSubject = hexLower(
  HMAC-SHA-256(key, UTF8("archivale-play-subject-v1\n" + auth.uid))
)

requestFingerprint = hexLower(
  HMAC-SHA-256(
    key,
    UTF8("archivale-play-request-v1\n" + auth.uid + "\n" + requestId)
  )
)
```

All billing records store `contractVersion=play-billing-v1` and `keyVersion`.
The purchase-token fingerprint is globally unique and may bind to only one
account subject. A fingerprint already bound to another subject, product, or
incompatible lifecycle fails to Free. Raw UID, `obfuscatedAccountId`, and raw
purchase token are never storage keys.

The internal MVP permits exactly one active fingerprint key version. An
unknown version or attempted live key change fails to Free. Rotation needs a
separately reviewed disable/migration/rollback procedure; `keyVersion` is not
permission to silently create a second identity for an existing token or UID.

## Replay, Token Serialization, And Call Bounds

### Request Replay

After the disclosure gate and before the first Play call, one transaction
atomically creates or reclaims both the request-replay record and token
operation. It stores request/token fingerprints, `outcomeCode=in_flight`, a
90-second lease, timestamps, and a server-issued attempt owner:

```text
attemptOwner = (
  requestFingerprint,
  attemptGeneration,
  attemptNonce
)
```

`attemptGeneration` is a server-owned unsigned integer that starts at 1 and
must increase by exactly 1 whenever that token operation is safely reclaimed.
Acquisition uses the greatest retained generation across the token operation,
request replay, and purchase binding as its high-water mark. TTL cleanup may
remove that mark only after every callable attempt is incapable of executing;
unknown, partial, decreasing, or conflicting generation state fails to Free.
`attemptNonce` is a fresh, server-generated 128-bit CSPRNG value for that
generation. It is compared as opaque bytes and is never accepted from the
client. The request fingerprint is a replay/correlation key, not an attempt
owner by itself. A deterministic fake nonce source is allowed only in #191
tests.

Ownership is conferred only on the invocation whose acquisition transaction
creates or reclaims that generation and nonce. Reading an existing owner from
Firestore never transfers ownership, and a later invocation must not hydrate
stored owner fields into its callable-attempt context. It can only return the
bounded non-owner result or win a permitted reclaim transaction that mints the
next owner.

`in_flight`, `delivery_committed`, and `ack_in_progress` are nonterminal and
remain protected by the original 90-second ownership lease. `verified_owner`
is represented as `in_flight` until delivery commits and has the same
protection. Reuse has these outcomes:

- same request/token fingerprint in any lease-protected nonterminal phase
  before the exact lease boundary: return Free with `in_flight` and make zero
  Play get or acknowledgement calls;
- any request for the same token while another attempt owns a lease-protected
  nonterminal phase before that boundary: return Free with `in_flight` and
  make zero Play get or acknowledgement calls;
- same request/token at or after the 90-second boundary, or after a terminal
  outcome: transactionally reclaim both records, advance the token's attempt
  generation, mint a new nonce, and repeat current Play verification; the
  prior result is not payment evidence;
- `ack_unknown` before its exact 15-second cooldown boundary: return Free with
  `verification_pending` and make zero Play get or acknowledgement calls; at
  or after the boundary, reclaim by advancing the generation and nonce before
  re-verification;
- same request fingerprint with a different token fingerprint: return Free
  with `replay_conflict` and make no Play call; and
- malformed, unknown-version, missing-field, or partial replay record: return
  Free with `unsafe_record` and do not overwrite it.

Valid outcomes are `in_flight`, `delivery_committed`, `ack_in_progress`,
`ack_unknown`, `paid`, and `free`. `ack_unknown` is a retired-owner,
cooldown-protected nonterminal outcome; it is never an active acknowledgement
owner. A crash may leave a recoverable nonterminal outcome. Replay records
never cache a client paid lease or replace current Play verification.

### Subject Ceiling And Token Single-Flight

Before a Play call, a transaction in `archivale-play-billing` must enforce:

- no more than 6 `purchases.subscriptionsv2.get` starts per account subject in
  a rolling 15-minute window;
- no more than one in-flight verification per token fingerprint;
- at least 15 seconds between Play `get` starts for the same token fingerprint;
- no more than 3 acknowledgement starts per token fingerprint in a rolling
  15-minute window; and
- at most one acknowledgement call in a single callable attempt, with no
  automatic same-request retry after timeout, 409, 5xx, or another error.

The pre-Play token operation is a 90-second `lookup_in_flight` single-flight
lease keyed by token fingerprint and owned by the exact server-issued attempt
owner. It contains no account ownership and grants no entitlement. Distinct or
identical request IDs for the same token observe `in_flight` and make zero Play
or acknowledgement calls while the owner remains live. An expired owner may be
replaced only by the atomic generation-advancing transaction above, subject to
the cooldown and subject ceiling.

Only after Play returns and the package, returned product, account binding,
state/expiry, and token uniqueness are verified may a transaction compare the
exact current owner and `lookup_in_flight` phase, upgrade the operation to
`verified_owner`, and bind the account subject. Every later owner-controlled
transaction must compare the owner tuple in request replay and token operation,
the expected source phase, and the delivery owner when one exists. A
wrong-account, malformed, ineligible, stale-owner, or unverified token can
never capture durable token ownership or a purchase binding. It may consume
only the bounded preflight attempt. Unknown or partial operation/rate records
fail to Free.

For the canceled-pending predecessor branch, the successor operation is closed
as `canceled_pending_read_only` before acquiring a separately serialized
predecessor operation. Both Play lookups count against the same subject ceiling.
This avoids holding two token locks and the canceled successor never becomes a
verified owner.

Each Android Publisher call has a 10-second absolute deadline and the complete
Play-call portion of one callable has a 45-second absolute deadline. No library
or transport layer may add implicit retries. The 90-second token lease outlives
the 60-second function timeout, so a replacement owner cannot overlap a still-
running original function.

## Canonical Verification Order

For every purchase, restore, or refresh, #191 must perform these steps in order:

1. Validate callable shape, size, fixed disclosure version, and `requestId`.
2. Verify revoked/project-bound anonymous Auth.
3. Verify and consume a fresh approved-app, project-bound App Check token.
4. Recompute account subject and require the accepted current-purpose billing-
   disclosure assertion. Rejection makes zero Play calls.
5. Enforce the per-subject ceiling; derive account binding, token fingerprint,
   and request fingerprint; acquire request replay and token single-flight.
6. Call `purchases.subscriptionsv2.get` with fixed
   `packageName=app.archivale` and the raw request purchase token.
7. Require exactly one returned line item, an allowlisted returned product, and
   exact equality between request `productId` and that returned successor
   product.
8. If the returned state is
   `SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED`, branch immediately to the
   canceled-pending procedure. Do not run ordinary successor eligibility,
   expiry, account-binding, delivery, binding, or acknowledgement steps.
9. For every other state, require auto-renewing
   `offerDetails.basePlanId=monthly`, absent `offerDetails.offerId`, exact
   account binding, unique/same-subject token binding, parseable future expiry,
   and `ACTIVE`, `IN_GRACE_PERIOD`, or `CANCELED` eligibility.
10. Upgrade the token operation to verified ownership and durably commit the
    verified entitlement delivery before acknowledgement.
11. If Play reports acknowledgement pending, atomically CAS
    `delivery_committed` to `ack_in_progress` for the exact current attempt
    owner and increment the acknowledgement-start counter. Only that successful
    transaction permits the one allowed `purchases.subscriptions.acknowledge`
    call. If already acknowledged, use the owner-CAS no-call recovery path.
    Unknown acknowledgement fails to Free.
12. In one final transaction, persist acknowledged delivery, finish request and
    token-operation state, and atomically supersede a linked predecessor when
    applicable.
13. Re-read/confirm the committed final state in the transaction result and
    return the bounded lease. Any missing commit or failure returns Free.

`purchases.subscriptionsv2.get` is the source of truth on every verification or
refresh. A client `Purchase`, prior server response, replay record, token
operation, or stored binding never replaces that call.

## Crash-Safe Delivery And Acknowledgement

Google's order is verify, grant/update entitlement storage, then acknowledge
delivery. Archivale implements that order without exposing an unacknowledged
client lease.

### Durable Delivery Commit

After every ordinary eligibility check succeeds and while the request owns the
verified token operation, one transaction must create or update the purchase
binding with:

- exact token fingerprint, account subject, plan/product/base-plan/offer,
  normalized state, Play expiry, and verification time;
- `deliveryState=committed`;
- `ackState=pending` when Play reports pending, or `ackState=play_acknowledged`
  when Play already reports acknowledgement;
- `bindingState=verified_delivery_committed`;
- the exact current `attemptGeneration` and `attemptNonce` as the staged
  delivery owner;
- linked predecessor fingerprint as a staged candidate when present; and
- request/operation state `delivery_committed`.

The transaction must CAS the current owner and expected `verified_owner` phase
in both replay and token-operation records. A duplicate or stale attempt cannot
reuse the same request fingerprint to commit delivery. `delivery_committed`
does not release or transfer ownership; it remains lease-protected through the
acknowledgement decision.

This is the durable grant/update of entitlement ownership required before
Archivale tells Play that delivery occurred. It is recoverable server state,
but it is not sufficient by itself for a paid response, offline access, or an
AI entitlement. Before this transaction commits, no acknowledgement call is
allowed. A storage failure therefore leaves Play unacknowledged, returns Free,
and preserves Play's refund safeguard; retry starts with current verification.

An existing `ackState=acknowledged` binding is absorbing and must not be
restaged as pending, `play_acknowledged`, or unknown. A fresh eligible Play read
for that same finalized binding uses the current attempt owner to finish the
request/token operation while preserving acknowledged delivery. A missing or
only staged binding still follows delivery commit and no-call finalization when
Play already reports acknowledged.

For a linked successor, the durable commit may stage the successor binding and
predecessor fingerprint, but it must not edit, tombstone, or supersede the
predecessor yet.

### Exact Acknowledgement Call

For a delivery-committed eligible purchase with
`ACKNOWLEDGEMENT_STATE_PENDING`, call
`purchases.subscriptions.acknowledge` with exactly:

```text
packageName = app.archivale
subscriptionId = the independently verified product ID
token = the raw purchase token held in request memory
body = {}
```

Immediately before the call, one transaction must CAS the current attempt
owner and `delivery_committed` phase in the replay, token-operation, and
delivery-binding records, increment the token acknowledgement-start counter,
and move all three to `ack_in_progress`. Failure to commit that transition
makes zero acknowledgement calls. The owner cannot be inferred from request
fingerprint equality, and no second invocation may share or resume an
`ack_in_progress` owner.

Account-binding equality is a precondition, not an acknowledgement argument.
Do not send `externalAccountIds`, developer payload, UID, or another body field.
`ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED` is a successful no-call recovery path. The
verifier never acknowledges pending, unknown, ineligible, mismatched, expired,
revoked, or voided state.

### Finalization And Recovery

After acknowledgement succeeds, or current Play state says it was already
complete, one transaction must require the same verified token-operation owner
and delivery-committed binding, then set:

- `ackState=acknowledged` and acknowledgement-confirmed timestamp;
- `bindingState=acknowledged_delivery`;
- request outcome `paid` and token operation terminal/cooldown state; and
- for a linked successor only, successor/predecessor pointers plus predecessor
  `bindingState=superseded` atomically.

Only the successful result of this final transaction can produce a lease. If
acknowledgement succeeds but final storage or response delivery fails, the
durable delivery-committed binding remains. A retry re-runs
`purchases.subscriptionsv2.get`; when Play reports acknowledged, it completes
the final transaction without another acknowledgement call. If the final
transaction committed but the response was lost, retry verifies Play and the
binding again and can return a new capped lease.

Timeout, 409, 5xx, or another ambiguous acknowledgement result sets
`ackState=unknown` and request outcome `ack_unknown` without changing the
predecessor or returning a lease. It releases the operation into the 15-second
cooldown. That transaction must CAS the exact current owner and
`ack_in_progress` phase plus non-acknowledged binding state across replay, token
operation, and delivery binding; on success it retires that owner. No
same-request acknowledgement retry occurs.
The next bounded request can reclaim only after the exact cooldown boundary,
must advance the generation and nonce, and then re-verifies Play: acknowledged
state finalizes without a call; pending state may make one new acknowledgement
attempt if the token attempt ceiling allows it; ineligible state invalidates
the staged binding and returns Free.

Finalization after an acknowledgement call requires `ack_in_progress`; no-call
finalization after a fresh Play read reports acknowledged requires
`delivery_committed` for the current owner. The final transaction CASes that
owner and source phase across replay, token operation, and delivery binding.
For a linked successor it also CASes the unchanged staged predecessor relation
and predecessor binding version before superseding the predecessor in the same
transaction. The first successful `ackState=acknowledged`,
`bindingState=acknowledged_delivery`, `outcomeCode=paid` commit is monotonic:
no stale owner, timeout handler, recovery, or later eligibility invalidation
may change acknowledgement state back to pending or unknown. Later current
Play verification may still deny a client lease or update lifecycle
eligibility, but it preserves the acknowledged-delivery fact.

Competing finalization and `ack_unknown` transactions for one owner are
mutually exclusive because each requires the same owner and
`ack_in_progress` source phase. Whichever commits first changes the phase; the
other transaction must re-read, fail its CAS, and make no write. A stale owner
CAS failure always returns Free and must not call Play or edit a request,
operation, delivery binding, successor, or predecessor.

A definitive acknowledgement or later Play failure likewise returns Free while
retaining enough sanitized delivery state to retry or invalidate safely. The
client presents verification-pending state and retries on the next purchase
event, foreground, restore, or gated action, subject to ceilings. No raw token
is retained for unattended repair; if the collector never returns, Play's
unacknowledged-purchase safeguard remains. RTDN/background reconciliation is
still deferred to #194.

While verification is pending, #192/#193 must not prompt a duplicate purchase
for that product or claim payment failed. They expose bounded retry/restore and
obtain the current token again from Play's purchase query/stream, never from
app-owned persistence. Existing-record view/edit/report/export stays available
throughout recovery.

At every crash boundary:

| Last durable point | Required retry behavior |
| --- | --- |
| Before verified delivery commit | No acknowledgement occurred; re-verify and restage |
| Delivery committed, acknowledgement not started | Same/other request makes zero calls until owner lease expires; reclaim advances generation, then re-verifies Play |
| Acknowledgement call in progress | Same/other request makes zero calls until owner lease expires; stale result cannot pass owner-and-phase CAS |
| Acknowledgement result unknown | Make zero calls during cooldown; reclaim advances generation, then re-verifies Play and acknowledges only if still pending |
| Acknowledgement succeeded, final transaction missing | Re-verify; observe acknowledged; finalize without another acknowledgement call |
| Final transaction committed, response lost | Re-verify current Play/binding state; return a newly bounded lease |
| Any state becomes ineligible/mismatched | Invalidate staged state, preserve predecessor, return Free |

No path acknowledges an unverified or uncommitted delivery, returns a lease
from an unacknowledged/unknown record, or requires deleting a valid predecessor
to recover.

## Linked Successor Contract

For an ordinary eligible successor with `linkedPurchaseToken`:

1. Keep the raw linked token in request memory and derive its fingerprint.
2. Fully verify the successor, including request/returned product equality,
   base plan/offer, account binding, token uniqueness, state, and expiry.
3. Require any existing predecessor binding to belong to the same account and
   not already be superseded by a different successor.
4. Durably commit the successor delivery and staged predecessor fingerprint;
   predecessor reads and state remain unchanged.
5. Acknowledge or recover already-acknowledged state as specified above.
6. Only in the final acknowledged-delivery transaction, bind the successor and
   mark/tombstone the predecessor as superseded. That transaction must CAS the
   current successor attempt owner, delivery phase, staged predecessor
   relation, and predecessor binding version.

After that final transaction, the predecessor cannot issue another lease. Raw
linked tokens are never persisted or followed as substitute entitlement. An
acknowledgement/storage failure returns Free for the successor, preserves its
recoverable delivery stage when committed, and leaves predecessor access and
records unchanged.

## Canceled-Pending Predecessor Contract

`SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED` never grants access from the
canceled pending successor itself. The branch occurs immediately after the
successor request/returned-product check and before ordinary successor
eligibility, expiry, account binding, delivery, binding, or acknowledgement.

The procedure is:

1. Require `linkedPurchaseToken`; otherwise return Free.
2. Close the successor token operation as read-only. Never acknowledge, bind,
   deliver, supersede, or tombstone the canceled successor. The close
   transaction must CAS the successor's exact current attempt owner and phase.
3. Keep the raw linked token in request memory, derive its fingerprint, and
   acquire the independently serialized predecessor operation.
4. Call `purchases.subscriptionsv2.get` with fixed package and the raw linked
   predecessor token.
5. Require exactly one predecessor line item. Validate its returned product
   independently against the full fixed allowlist and derive predecessor
   `planId`, product, base plan, offer, and expiry from that line item.
6. Do not require predecessor product equality with the canceled successor
   request product. Same-product and cross-product replacement failures are
   both valid shapes.
7. Apply exact predecessor account binding, token/same-subject uniqueness,
   auto-renewing monthly/absent-offer, future-expiry, eligible-state, and
   acknowledgement/durable-delivery checks. Every predecessor delivery,
   acknowledgement-start, unknown-result, and finalization transaction must
   CAS the independently acquired predecessor attempt owner and expected phase.
8. Return only the predecessor `planId`, `productId`, normalized state,
   `playExpiresAt`, and capped lease after predecessor delivery and
   acknowledgement are safely finalized.

Any missing link, malformed/multiple line item, unknown predecessor product,
base-plan/offer mismatch, account/token mismatch, ineligible state, API,
storage, rate, or acknowledgement failure returns Free and leaves an existing
predecessor binding/access record unchanged. The canceled successor remains
unacknowledged, unbound, and absent from purchase bindings in every outcome.

## State, Lease, And Downgrade Mapping

Every paid row also requires current disclosure, identity, allowlist, account,
token, durable delivery, and final acknowledgement checks. A fail-Free result
carries no paid lease.

| Play/local/durable input | Normalized result | Access |
| --- | --- | --- |
| `SUBSCRIPTION_STATE_ACTIVE`, future expiry, acknowledged delivery | `active` | Paid lease |
| `SUBSCRIPTION_STATE_IN_GRACE_PERIOD`, future expiry, acknowledged delivery | `grace` | Paid lease |
| `SUBSCRIPTION_STATE_CANCELED`, future expiry, acknowledged delivery | `canceled` | Paid lease only through Play expiry |
| `SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED` with independently valid predecessor | predecessor state/plan/product/expiry | Predecessor lease only |
| Verified delivery committed with acknowledgement pending/unknown | `free` / `verification_pending` | Free until recovered |
| `SUBSCRIPTION_STATE_UNSPECIFIED`, `PENDING`, `PAUSED`, `ON_HOLD`, or `EXPIRED` | `free` | Free |
| Revoked/voided, past/missing expiry, malformed/multiple line items, prepaid/add-on, unknown acknowledgement | `free` | Free |
| Disclosure, package, product, base-plan, offer, account, token, subject, replay, generation, or database mismatch | `free` | Free |
| Rate limit, Auth/App Check, Play API, acknowledgement, persistence, or verifier failure | `free` | Free |
| Lease expiry, process restart, account change/sign-out, unavailable verifier, or failed/newer refresh | `free` | Free |

For a paid result:

```text
leaseExpiresAt = min(verifiedAt + 15 minutes, playExpiresAt)
```

The paid response contains only `version=play-billing-v1`, `requestId`,
`planId`, `productId`, normalized `state`, `verifiedAt`, `playExpiresAt`, and
`leaseExpiresAt`. For canceled-pending recovery, those values are the
predecessor's values.

A Free response contains only `version=play-billing-v1`, a validated
`requestId` when available, `state=free`, and one fixed reason:
`invalid_request`, `identity_rejected`, `disclosure_required`,
`replay_conflict`, `in_flight`, `rate_limited`, `unsafe_record`,
`not_verified`, `verification_pending`, or `temporarily_unavailable`. No reason
reveals package, product, account, token, Play state, expiry, or acknowledgement
details. Neither response echoes purchase/linked/Auth/App Check tokens, UID,
account binding, subject/fingerprint, order data, Play response, or payload.

## Client Generation And Account Fences

#192 must keep an in-memory monotonic `entitlementGeneration`, current anonymous
Auth UID, current request ID, and optional in-flight operation. None is
persisted or logged.

Rules:

1. App/process start begins at generation 0 and Free.
2. Starting a new authoritative purchase, restore, foreground refresh, or
   gated-action refresh increments the generation, clears any current lease,
   creates a new request ID, and captures the current Auth UID plus generation.
3. Duplicate purchase-stream events for the same token coalesce into the
   current in-flight operation. If a new operation is intentionally started, it
   receives a new generation and invalidates the old one.
4. Account change, sign-out, anonymous-user replacement, disclosure revocation,
   failed refresh, and explicit Free transition increment the generation,
   clear the lease, and invalidate/cancel every older operation best-effort.
5. A response may install only when its `requestId`, captured Auth UID, and
   captured generation exactly equal the coordinator's current request, UID,
   and generation at installation time.
6. A stale response is discarded without changing current Free/paid state. A
   delayed paid response cannot overwrite a newer Free result, and a delayed
   Free result cannot overwrite a newer paid result.
7. The server does not accept or trust client generation; the fence is local
   race control layered on server Auth/account/token verification.

Deterministic deferred-response tests must cover UID A to UID B switch,
sign-out, failed refresh, paid-then-Free and Free-then-paid out-of-order
completion, duplicate purchase-stream events, and a new refresh overtaking an
older request.

When Free caps block a new active artwork or AI request, existing records remain
viewable, editable, reportable, and exportable. Downgrade must never delete,
hide, lock, or corrupt existing records or supporting documents.

## Persistence, TTL, And Redaction

All records below exist only in `archivale-play-billing`.

### `playBillingDisclosureAssertions`

May store only account subject, contract/disclosure versions, exact purpose,
accepted/status timestamps, status, and retention expiry. TTL is 365 days from
acceptance, or no later than 30 days after revocation/account deletion. It is a
purpose gate, not payment evidence.

### `playBillingPurchaseBindings`

May store only:

- token fingerprint and account subject;
- contract/key versions;
- plan, product, base-plan, and absent-offer marker;
- normalized state, Play expiry, and verification time;
- `deliveryState`, `ackState`, `bindingState`, and fixed recovery reason;
- opaque staged-delivery `attemptGeneration` and `attemptNonce` CAS fields;
- staged/final predecessor/successor fingerprints and superseded state; and
- created, updated, state-change, acknowledgement-confirmed, and retention
  timestamps.

TTL is `max(playExpiresAt, lastVerifiedAt) + 30 days`. TTL is cleanup, not
payment authority. An expired, malformed, unknown-version, partial, or binding-
mismatched record fails to Free. A correctly bound token that refreshes to an
ineligible state is atomically invalidated without altering another valid
predecessor.

The binding is durable server entitlement-delivery/recovery state required by
the Play acknowledgement order. It is never sufficient without current Play
verification and acknowledged final state, and it is never an offline/client
lease or a `brokerDurableEntitlements` payment grant.

### Operational Collections

- `playBillingRequestReplays`: request/token fingerprints, opaque server attempt
  generation/nonce CAS fields, phase, lease/cooldown, fixed outcome,
  timestamps, and 24-hour retention expiry only.
- `playBillingTokenOperations`: token/request fingerprints, optional verified
  account subject only after exact Play binding, server attempt
  generation/nonce CAS fields, phase, lease/cooldown, `lastGetStartedAt`, a
  bounded `acknowledgementStartedAt` timestamp history of at most 3 entries
  pruned to the rolling 15-minute window, fixed outcome, timestamps, and
  24-hour TTL.
- `playBillingRateLimits`: account subject, a bounded `getStartedAt` timestamp
  history of at most 6 entries pruned to the rolling 15-minute window,
  timestamps, and 24-hour TTL.

Operational records bound calls and recover concurrency; they never grant a
lease. Malformed records fail to Free rather than being treated as absent.

### Absolute Redaction

The following are request-memory only and must never enter Firestore or other
storage, logs, telemetry, Crashlytics, Analytics, Performance Monitoring,
screenshots, console captures, fixtures, test names, issue/PR comments, or
review/deployment evidence:

- raw `purchaseToken` or `linkedPurchaseToken`;
- raw Auth or App Check token;
- raw Firebase UID or captured client UID/generation;
- derived `obfuscatedAccountId` or returned account identifiers;
- any order ID, developer payload, Play response body, cancellation free text,
  or Subscribe with Google profile data; and
- server fingerprint key, secret path, or real assertion/account/token/request
  fingerprint.

`attemptGeneration` and `attemptNonce` are the sole exception: they are opaque
server-owned CAS fields, not request-memory-only values. They may be persisted
only in `playBillingPurchaseBindings`, `playBillingRequestReplays`, and
`playBillingTokenOperations`, only in `archivale-play-billing`, and only for
the exact owner-and-phase comparisons defined above. They must never be exposed
to a client or copied to any other Firestore database, collection, storage
system, log, telemetry product, fixture, screenshot, console capture, test
name, issue/PR comment, or review/deployment evidence. A complete attempt
owner remains forbidden outside those three server-only records.

Clear request-memory references at completion. Logs/evidence may contain only
fixed event/reason codes, contract/key/disclosure versions, coarse timing, and
aggregate counts. There is no persisted mobile lease. The only durable payment
state is the narrowly scoped, non-client-readable delivery/recovery binding in
the named billing database.

## Internal-MVP Limitations And #194 Gate

The internal contract relies on foreground purchase/restore/refresh requests
and a 15-minute in-memory lease. It intentionally has no:

- Real-time Developer Notifications (RTDN);
- scheduled Play reconciliation or voided-purchase processing;
- encrypted raw-token custody for unattended acknowledgement recovery;
- durable account recovery, anonymous-identity migration, reinstall recovery,
  or reliable multi-device entitlement;
- offline paid lease, persisted client paid state, or background renewal;
- public payment monitoring, support, incident, refund, or reconciliation
  operation; or
- closed/open/production Data Safety and privacy approval for the future
  Billing/Auth/App Check artifact.

These limitations are acceptable only for the controlled internal test. #194
must design, implement, test, and review RTDN, scheduled reconciliation, voided
purchases, encrypted token custody, durable account/reinstall/multi-device and
offline/signed-lease behavior, KMS/JWS decisions, monitoring/support,
migration/rollback, exact-build Data Safety/privacy declarations, and explicit
owner approval before paid rollout beyond internal testing.

## Human Inputs And Evidence Gates

Before #191 implementation, the code owner must preserve this exact database,
rules/IAM, disclosure, package/product/base-plan/offer, function/schema,
derivation, call-bound, delivery/acknowledgement, state, and rollback contract
in tests. A contract change returns to review rather than becoming runtime
configuration.

Before any internal purchase or deployment, humans must provide and approve:

- exact Play app/package ownership and matching subscription/base-plan setup;
- final localized prices, tax/merchant/country settings, and internal testers;
- creation/location and enabled delete protection for
  `archivale-play-billing`, its database-targeted rules, indexes, TTLs, backup,
  and rollback owner;
- exact dedicated runtime principal, database-conditioned IAM, proof of no
  conflicting inherited/unconditional roles, and Android Publisher permissions;
- explicit approval of `us-central1`, Node.js 22, Blaze/billing attachment,
  budget/alert posture, and deployment/rollback/payment owners;
- App Check provider/app IDs and anonymous Auth configuration for
  `my-art-collections`;
- fingerprint key custody, active `keyVersion`, rotation/rollback procedure,
  and sanitized observability;
- exact `billing-verification-disclosure-v1` copy, acceptance/revocation flow,
  and separate AI research-consent copy;
- explicit acceptance of internal restart, reinstall, multi-device, offline,
  foreground-retry, and unattended-lifecycle limitations;
- internal-test build/version and evidence window; and
- a Data Safety/privacy worksheet based on the exact artifact.

Names of owners and sanitized configuration identifiers may be recorded.
Credentials, tokens, UIDs, tester identities, account bindings/subjects,
fingerprints, order data, Play responses, and secret values/paths must not
appear in evidence.

Required acceptance evidence is serialized:

| Dependency | Evidence before it advances |
| --- | --- |
| #190 | Exact eight-file diff, stale-topology/redaction/protocol scans, blocker matrix, independent focused task review, then focused payment redteam |
| #191 | Fake/unit/emulator proof of named-database targeting and deny-all client rules, including opaque attempt generation/nonce persisted only in the three permitted server-only records and asserted without displaying owner material; database-IAM negative evidence plan; disclosure zero-Play gates; request/token concurrency and ceilings; same/cross-product canceled-pending recovery; exact API arguments; TTL/redaction; deterministic parallel/fault matrix for identical request IDs crossing delivery commit, crash immediately after delivery commit, duplicate arrival while acknowledgement is running, success racing 409/timeout, post-90-second generation-advancing reclaim, stale prior-owner CAS rejection, cross-UUID token single-flight, one acknowledgement start, finalized success never regresses to `ack_unknown`, and no owner material reaches telemetry |
| #192 | Fake-driven proof of official disclosure flow, account derivation, duplicate coalescing, generation/request/UID fences, memory-only lease, foreground recovery, restart/account-change/failure Free behavior, and preserved existing-record access |
| #193 | Mobile visual/interaction evidence for disclosure, purchase/restore, verification pending, rate/unavailable, pending/grace/canceled/hold/paused, Free/downgrade, and safe errors |
| #194 | Payment redteam, privacy/Data Safety, deployment/rollback, RTDN/reconciliation, monitoring, durable identity/token custody, and explicit closed/public approval |

#191 must implement the acknowledgement-race cases with a fake clock,
deterministic nonce source, transaction barriers, and counted fake Play calls:

| Deterministic case | Required assertion |
| --- | --- |
| Identical request IDs cross the delivery commit | The duplicate returns `in_flight`; it starts zero Play get/acknowledgement calls and cannot adopt the first owner |
| Crash immediately after delivery commit | Calls before 90 seconds are zero; reclaim at the exact boundary advances generation once, changes nonce, and re-verifies |
| Duplicate arrives while acknowledgement runs | The duplicate returns `in_flight`, starts zero Play calls, and cannot transition `ack_in_progress` |
| Success races timeout/409 handling | Exactly one owner-and-phase CAS commits; paid finalization rejects the unknown writer, or unknown state forces cooldown/re-verification |
| Old owner completes after post-90-second reclaim | Every delivery, unknown-result, finalization, and linked-predecessor CAS from the old owner fails without a write or Play call |
| Distinct request IDs race for one token | Exactly one owner wins; every loser makes zero Play get/acknowledgement calls |
| Two workers reach acknowledgement start | Exactly one `delivery_committed` to `ack_in_progress` CAS and exactly one acknowledgement call occur |
| Finalized success receives a stale timeout callback | `ackState=acknowledged`, acknowledged delivery, paid outcome, and predecessor/successor finalization remain unchanged |

#191 and #192 remain held until focused independent task review and payment
redteam accept #190. No implementation task may self-certify this contract
complete.

## Non-Goals

- No source, configuration, dependency, Firebase, Firestore, Play Console,
  account, or billing mutation in #190.
- No Play/Firebase/provider API call, purchase, deployment, credential access,
  or console evidence in #190.
- No direct OpenAI or paid-provider call from mobile.
- No public-price promise until the human Play setup is approved.
- No credit packs, prepaid products, offers, add-ons, family sharing, promo-code
  policy, or alternate app stores in v1.
- No claim that a supporting record or subscription proves artwork
  authenticity, attribution, appraisal, provenance, insurance approval, or
  market value.

## Primary Guidance

Current Google guidance was rechecked for #190 on 2026-07-10:

- [Integrate the Google Play Billing Library](https://developer.android.com/google/play/billing/integrate)
- [Fight fraud and abuse](https://developer.android.com/google/play/billing/security)
- [Subscription lifecycle](https://developer.android.com/google/play/billing/lifecycle/subscriptions)
- [`purchases.subscriptionsv2` resource](https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptionsv2)
- [`purchases.subscriptionsv2.get`](https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptionsv2/get)
- [`purchases.subscriptions.acknowledge`](https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptions/acknowledge)
- [Manage multiple Firestore databases and database IAM](https://firebase.google.com/docs/firestore/manage-databases)
- [Firestore Security Rules and server IAM boundary](https://firebase.google.com/docs/firestore/security/rules-conditions)
