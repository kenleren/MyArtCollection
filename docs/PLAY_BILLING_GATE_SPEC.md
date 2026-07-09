# Play Billing Gate Spec

Status: accepted documentation contract; implementation and deployment remain
gated
Issue: #190
Date: 2026-07-10

## Scope And Authority

This is the canonical contract for Archivale's internal-track Android
subscription verification. It defines the boundary consumed by #191 (server),
#192 (mobile adapter and lease), and #193 (subscription UI). It does not
authorize implementation, Play or Firebase mutation, a purchase, credential
access, deployment, or public paid rollout.

Google Play is the payment-state authority. The server verifies Play state and
returns a short result; the mobile app holds that result only as an in-memory
lease. No client claim, local plan selection, Firebase document, AI broker
entitlement, or cached purchase object can prove payment.

The initial contract is deliberately internal-track only. Issue #194 is a hard
gate before any closed, open, or production paid rollout.

## One-Project Isolation

`my-art-collections` is the only approved Firebase/GCP project. Earlier
proposals that require another Firebase project for paid AI or Play Billing are
obsolete. Billing remains isolated inside the shared project by all of these
boundaries:

| Surface | Billing-owned contract |
| --- | --- |
| Source directory | `backend/play_billing` |
| Functions codebase | `play-billing` |
| Callable function | `verifyPlaySubscription` v1 |
| Region/runtime | `us-central1`; Node.js 22 |
| Runtime identity | Dedicated billing-verifier service identity, distinct from the research broker identity |
| Durable collections | `playBillingPurchaseBindings`, `playBillingRequestReplays` |
| Secret use | Server-only fingerprint key with an explicit version; never available to mobile or the research broker |
| IAM | Only the verifier may call the required Android Publisher read/acknowledge methods and read/write the two billing collections |
| Rollback target | Billing callable/codebase and its runtime identity, without disabling the AI broker |

The deployment owner must record the exact runtime principal and least-privilege
IAM bindings before deployment. The verifier must not read or write
`brokerDurableEntitlements`, broker credits, broker requests, artwork records,
or attachment records. Conversely, the research broker has no read or write
authority over billing collections and no payment authority.

Because the project is shared, project-wide billing disablement is not an
isolated billing or AI kill switch. It can disrupt Auth, App Check, App
Distribution, telemetry, billing verification, and the research broker. Use
function/codebase, runtime-IAM, and provider-specific controls first; any
project-wide action remains an explicit human-owned last resort.

## Billing Identity Is Not AI Consent

When a collector initiates purchase or restore, the app must first show a
distinct billing-verification disclosure. Acceptance authorizes the app to
create or reuse anonymous Firebase Auth for `my-art-collections` and obtain App
Check only for subscription verification and entitlement refresh.

That disclosure:

- does not create, imply, or satisfy AI research consent;
- does not enable `online_research_enabled` or authorize a broker request;
- does not authorize an artwork image, metadata, notes, documents, or research
  hints to leave the device;
- does not turn the anonymous UID into a Google Play or Archivale account; and
- is required independently of whether the same anonymous identity is later
  reused after separate, current-version research consent.

Research still requires its own disclosure, current consent-copy version, and
all gates in `AI_BROKER_AUTH_AND_QUOTA_SPEC.md`. Possession of a billing lease
does not bypass those gates. App Check attests the app instance; it is not user
identity, payment evidence, or consent.

The billing callable requires a verified anonymous Auth context and a fresh
limited-use App Check token from `my-art-collections`, consumed server-side.
Missing, stale, replayed, revoked, wrong-project, or unapproved-app identity
fails to Free before any Android Publisher request.

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
| `requestId` | Required canonical lowercase UUID; used only for idempotency and safe correlation |
| `productId` | Required string but untrusted; it must match the verified single Play line item and fixed allowlist |
| `purchaseToken` | Required non-empty Play purchase token; request-memory only |

Firebase Auth and App Check arrive only through verified callable context. The
body must not accept a UID, App Check token, Auth token, package override,
account binding, plan, price, entitlement, expiry, acknowledgement state, or
linked token. Unknown or malformed fields fail to Free before a Play call.

The app sends the same Auth-derived account binding to Google Play when it
launches the billing flow:

```text
base64urlNoPad(
  SHA-256(UTF8("archivale-play-account-v1\n" + auth.uid))
)
```

The output is the 43-character, unpadded base64url SHA-256 digest. #192 passes
that exact value through `setObfuscatedAccountId`. #191 recomputes it from the
verified Auth UID and requires exact, case-sensitive equality with
`externalAccountIdentifiers.obfuscatedExternalAccountId` from
`purchases.subscriptionsv2.get`. Missing or unequal values fail to Free.

The server also derives three non-reversible storage identifiers with a
server-only HMAC key:

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

Both collections store `contractVersion=play-billing-v1` and `keyVersion`. The
purchase-token fingerprint is globally unique and may bind to only one account
subject. A fingerprint already bound to another subject, product, or
incompatible lifecycle fails to Free. The raw UID, `obfuscatedAccountId`, and
raw purchase token are never storage keys.

The internal MVP permits exactly one active fingerprint key version. An
unknown version or an attempted live key change fails to Free. Rotation needs a
separately reviewed disable/migration/rollback procedure; `keyVersion` is not
permission to silently create a second identity for an existing token or UID.

### Request Replay And Concurrency

Before the first Play call, atomically create the request-replay record with
the request fingerprint, token fingerprint, `outcomeCode=in_flight`, and
timestamps. Reuse has these exact outcomes:

- same request fingerprint and token fingerprint while `in_flight` is younger
  than 60 seconds: return Free with fixed reason `in_flight` and make no Play
  or acknowledgement call;
- same request and token at or after the 60-second boundary, or after a fixed
  terminal outcome: after the new request has independently passed Auth/App
  Check, atomically reclaim it, then re-run `purchases.subscriptionsv2.get`,
  every binding/state check, and any required acknowledgement; the prior
  outcome is not entitlement evidence;
- same request fingerprint with a different token fingerprint: return Free
  with fixed reason `replay_conflict` and make no Play call; and
- any malformed, unknown-version, missing-field, or partially written replay
  record: return Free with fixed reason `unsafe_record` and do not overwrite it.

Completion replaces `in_flight` with exactly `paid`, `free`, or `ack_failed`
and updates the timestamp. No other outcome code is valid. A crash may leave
`in_flight`; the boundary above permits safe, idempotent recovery. Concurrent
attempts cannot both own the record. Replay records never cache a paid response
or skip current Play verification.

## Verification Order

For an ordinary purchase or refresh, #191 must perform these steps in order:

1. Validate callable shape, method, size, and canonical `requestId`.
2. Verify revoked/project-bound anonymous Auth.
3. Verify and consume a fresh, approved-app, project-bound App Check token.
4. Recompute the account binding, account subject, token fingerprint, and
   request fingerprint in memory, then acquire the replay record as specified
   above.
5. Reject a replay conflict, unsafe/superseded binding, or a token binding owned
   by another account.
6. Call `purchases.subscriptionsv2.get` with fixed
   `packageName=app.archivale` and the raw request purchase token.
7. Require exactly one line item and exact agreement among the requested
   `productId`, returned `lineItems[0].productId`, and the allowlist.
8. Require an auto-renewing item with `offerDetails.basePlanId=monthly`, absent
   `offerDetails.offerId`, a parseable future `expiryTime`, exact account
   binding, unique token binding, and an eligible state.
9. Resolve `linkedPurchaseToken` according to the atomic rules below.
10. If acknowledgement is pending, call
    `purchases.subscriptions.acknowledge`; if already acknowledged, perform the
    defined no-op. Any unspecified acknowledgement state fails to Free.
11. Only after successful/already-complete acknowledgement, atomically persist
    the binding and any linked-token supersession.
12. Return a bounded lease response. Any failure before step 12 returns Free.

`purchases.subscriptionsv2.get` is the source of truth on every verification or
refresh. A client `Purchase`, prior server response, replay record, or stored
binding never replaces that call in this internal MVP.

## Acknowledgement Contract

Exact account-binding equality and all package/product/base-plan/offer,
token-uniqueness, state, and expiry checks are acknowledgement preconditions.
For an eligible purchase whose Play response is
`ACKNOWLEDGEMENT_STATE_PENDING`, call
`purchases.subscriptions.acknowledge` with exactly:

```text
packageName = app.archivale
subscriptionId = the verified product ID
token = the raw purchase token held in request memory
body = {}
```

Do not send an account identifier, `externalAccountIds`, developer payload,
UID, or any additional body field. `ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED` is a
successful no-op. The verifier never acknowledges a pending, unknown,
ineligible, mismatched, expired, revoked, or voided purchase.

All successor and predecessor changes are staged in request memory only before
acknowledgement. An acknowledgement error or timeout returns Free, discards the
staged changes, does not create a purchase binding, and does not change a
predecessor. Only the sanitized 24-hour replay outcome `ack_failed` may persist.
A retry re-runs `purchases.subscriptionsv2.get`, every check, and acknowledgement
idempotently. If acknowledgement succeeded but the server failed before its
transaction, the retry observes already acknowledged and completes the same
atomic binding transaction without another acknowledgement call.

## Linked Purchase Tokens

For an eligible successor with `linkedPurchaseToken`:

1. Keep the raw linked token in request memory and derive its token fingerprint.
2. Fully verify the successor first, including account binding, token
   uniqueness, package, product, base plan, absent offer, eligible state, and
   future expiry.
3. Treat predecessor reads as read-only before acknowledgement. Any existing
   predecessor binding must belong to the same account subject and must not
   already be superseded by another successor.
4. Acknowledge the successor as specified above, or accept the already-
   acknowledged no-op.
5. Only then, in one transaction, bind/update the successor, store its
   predecessor fingerprint, and mark/tombstone the predecessor as superseded
   with the successor fingerprint.

After that transaction, the predecessor cannot issue another lease. Raw linked
tokens are never persisted or followed as substitute durable entitlements. An
acknowledgement or transaction failure must not supersede, tombstone, or alter
predecessor access; it returns Free and the retry begins from Play verification.

### Canceled Pending Replacement

`SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED` never grants access from the
canceled pending token itself.

When it includes `linkedPurchaseToken`, re-query that raw predecessor in the
same request with `purchases.subscriptionsv2.get`. Apply the identical fixed
package, one-line-item product/base-plan/absent-offer, exact account binding,
token/account binding, future-expiry, eligible-state, and acknowledgement
checks. Return only the predecessor's capped lease when it is verified as
`ACTIVE`, `IN_GRACE_PERIOD`, or `CANCELED` with future expiry and its
acknowledgement succeeds or was already complete.

The verifier may bind or refresh the valid predecessor after its own successful
acknowledgement, but it must not acknowledge, bind, supersede, or tombstone the
canceled pending successor. A missing linked token or any predecessor failure
returns Free and leaves an existing predecessor binding unchanged.

## State, Lease, And Downgrade Mapping

Every row also requires the identity, allowlist, account, token, line-item,
expiry, and acknowledgement checks above. A fail-Free result carries no paid
lease.

| Play or local input | Normalized result | Access |
| --- | --- | --- |
| `SUBSCRIPTION_STATE_ACTIVE` with future expiry | `active` | Paid lease |
| `SUBSCRIPTION_STATE_IN_GRACE_PERIOD` with future expiry | `grace` | Paid lease |
| `SUBSCRIPTION_STATE_CANCELED` with future expiry | `canceled` | Paid lease only through Play expiry |
| `SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED` with a valid linked predecessor | predecessor's normalized state | Predecessor lease only, as specified above |
| `SUBSCRIPTION_STATE_UNSPECIFIED`, `PENDING`, `PAUSED`, `ON_HOLD`, or `EXPIRED` | `free` | Free |
| Revoked/voided, past or missing expiry, malformed/multiple line items, prepaid/add-on, unknown state, or unspecified acknowledgement | `free` | Free |
| Package, product, base-plan, offer, account, token, subject, or replay mismatch | `free` | Free |
| Auth/App Check, Play API, acknowledgement, persistence, or verifier failure | `free` | Free |
| Lease expiry, process restart, account change, unavailable verifier, or failed refresh | `free` | Free |

For a paid result:

```text
leaseExpiresAt = min(verifiedAt + 15 minutes, playExpiresAt)
```

The paid response contains only `version=play-billing-v1`, `requestId`,
`planId`, `productId`, normalized `state`, `verifiedAt`, `playExpiresAt`, and
`leaseExpiresAt`. Timestamps are UTC RFC 3339 values.

A Free response contains only `version=play-billing-v1`, a validated
`requestId` when available, `state=free`, and one fixed reason:
`invalid_request`, `identity_rejected`, `replay_conflict`, `in_flight`,
`unsafe_record`, `not_verified`, `ack_failed`, or
`temporarily_unavailable`. No reason distinguishes package, product, account,
token, state, expiry, or acknowledgement details publicly. Neither response
echoes any purchase or linked token, Auth/App Check token, UID, account
binding, token/account fingerprint, order data, provider response, or developer
payload.

#192 keeps the response in process memory only. It must not persist a paid
plan, lease, expiry, or server response to a database, preferences, secure
storage, backup, analytics, or crash state. App start/process restart and lease
expiry begin at Free. A foreground refresh may replace Free only after a fresh
successful verification. Account change clears the lease before refresh.

When Free caps block a new active artwork or AI request, existing records remain
viewable, editable, reportable, and exportable. Downgrade must never delete,
hide, lock, or corrupt existing records or their supporting documents.

## Persistence, TTL, And Redaction

`playBillingPurchaseBindings` may store only:

- token fingerprint and account subject;
- contract and key versions;
- plan, product, base-plan, and absent-offer marker;
- normalized state and Play expiry;
- acknowledgement state;
- predecessor/successor fingerprints and superseded/tombstone state;
- created, last-verified, last-state-change, and retention-expiry timestamps;
- a fixed allowlisted reason code when applicable.

Its TTL is `max(playExpiresAt, lastVerifiedAt) + 30 days`. TTL is cleanup, not
payment authority. Expired, missing, malformed, unknown-version, or partially
written records fail to Free; they are never interpreted as a paid plan.

When a correctly bound token refreshes to an ineligible Play state, the
verifier may atomically replace its prior normalized state/expiry with the
verified Free state and fixed reason, but it returns no lease. It does not
create a new binding for an unverified or mismatched token.

`playBillingRequestReplays` may store only a one-way request fingerprint, token
fingerprint, fixed outcome code, created/updated timestamp, and
`retentionExpiresAt=createdAt+24 hours`. A replay record prevents conflicting
reuse but never grants access or replaces Play verification.

The following are request-memory only and must never enter Firestore or other
storage, logs, telemetry, Crashlytics, Analytics, Performance Monitoring,
screenshots, console captures, fixtures, test names, issue/PR comments, or
review/deployment evidence:

- raw `purchaseToken` or `linkedPurchaseToken`;
- raw Auth or App Check token;
- raw Firebase UID;
- derived `obfuscatedAccountId` or returned account identifiers;
- any order ID, developer payload, Play response body, free-form cancellation
  response, or Subscribe with Google profile data; and
- the server-only fingerprint key or secret path.

Clear request-memory references at completion. Logs and evidence may contain
only fixed event/reason codes, contract/key versions, coarse timing, aggregate
counts, and synthetic placeholders that cannot be mistaken for real values.
There is no persisted lease or durable payment entitlement, and there are no
writes to `brokerDurableEntitlements`.

## Internal-MVP Limitations And #194 Gate

The internal contract relies on foreground purchase/restore/refresh requests
and a 15-minute in-memory lease. It intentionally has no:

- Real-time Developer Notifications (RTDN);
- scheduled Play reconciliation or voided-purchase processing;
- encrypted raw-token custody for background verification;
- durable account recovery, anonymous-identity migration, reinstall recovery,
  or reliable multi-device entitlement;
- offline paid lease, persisted paid state, or background renewal;
- public payment monitoring, support, incident, refund, or reconciliation
  operation; or
- closed/open/production Data Safety and privacy approval for the future
  Billing/Auth/App Check artifact.

These limitations are acceptable only for the controlled internal test. #194
must design, implement, test, and review RTDN, scheduled reconciliation, voided
purchases, encrypted token custody, durable account/reinstall/multi-device and
offline/signed-lease behavior, KMS/JWS decisions, monitoring and support,
migration/rollback, exact-build Data Safety/privacy declarations, and explicit
owner approval before paid rollout beyond internal testing.

## Human Inputs And Evidence Gates

Before #191 implementation, the code owner must preserve this exact package,
product/base-plan/offer table, function/schema versions, collection names,
derivations, API methods, state mapping, and rollback behavior in tests. A
contract change returns to review rather than becoming runtime configuration.

Before any internal purchase or deployment, humans must provide and approve:

- exact Play app/package ownership and matching subscription/base-plan setup;
- final localized prices, tax/merchant/country settings, and internal license
  testers;
- the exact dedicated runtime principal and least-privilege Android Publisher
  and Firestore IAM bindings;
- explicit approval of `us-central1`, Node.js 22, Blaze/billing attachment,
  budget/alert posture, and named deployment/rollback/payment owners;
- App Check provider/app IDs and anonymous Auth configuration for
  `my-art-collections`;
- fingerprint key custody, active `keyVersion`, rotation/rollback procedure,
  TTL policy setup, and sanitized observability;
- the separate billing disclosure and separate AI research consent copy;
- explicit acceptance of the internal-only restart, reinstall, multi-device,
  offline, and unattended-lifecycle limitations;
- the internal-test build/version and evidence window; and
- a Data Safety/privacy worksheet based on the exact artifact.

Names of owners and sanitized configuration identifiers may be recorded.
Credentials, tokens, UIDs, order data, tester identities, account bindings,
provider responses, and secret values/paths must not appear in evidence.

Required acceptance evidence is serialized:

| Dependency | Evidence before it advances |
| --- | --- |
| #190 | Documentation diff/name checks, stale-topology and redaction scans, independent task review, then payment redteam review |
| #191 | Unit/fake/emulator proof of exact gate order, API arguments, bindings, linked-token rollback, idempotency, persistence/TTL, state table, and redaction |
| #192 | Fake-driven Flutter proof of disclosure separation, account derivation, request schema, memory-only lease, refresh/restart/account-change fail-Free behavior, and downgrade access |
| #193 | Mobile visual/interaction evidence for purchase, restore, pending, grace, canceled, hold/paused, Free/downgrade, unavailable, and safe-error states |
| #194 | Payment redteam, privacy/Data Safety, deployment/rollback, reconciliation, monitoring, durable identity/token custody, and explicit closed/public rollout approval |

#191 and #192 remain held until independent task review and payment redteam
accept #190. No implementation task may self-certify this contract complete.

## Non-Goals

- No source, configuration, dependency, Firebase, Play Console, account, or
  billing mutation in #190.
- No API call, purchase, deployment, credential access, or console evidence in
  #190.
- No direct OpenAI or paid-provider call from mobile.
- No public-price promise until the human Play setup is approved.
- No credit packs, prepaid products, offers, add-ons, family sharing, promo-code
  policy, or alternate app stores in v1.
- No claim that a supporting record or subscription proves artwork
  authenticity, attribution, appraisal, provenance, insurance approval, or
  market value.

## Primary Guidance

Current Google guidance was rechecked for #190 on 2026-07-10:

- [Fight fraud and abuse](https://developer.android.com/google/play/billing/security)
- [Subscription lifecycle](https://developer.android.com/google/play/billing/lifecycle/subscriptions)
- [`purchases.subscriptionsv2` resource](https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptionsv2)
- [`purchases.subscriptionsv2.get`](https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptionsv2/get)
- [`purchases.subscriptions.acknowledge`](https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptions/acknowledge)
