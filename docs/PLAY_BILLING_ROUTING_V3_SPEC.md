# Paid purchase routing v3 — disabled source foundation (#194)

Status: implementation candidate for independent task/payment/privacy review.
No provider setup, deployment, purchase or store release is authorized.
The [v2 recovery contract](PLAY_BILLING_RECOVERY_V2_SPEC.md) remains historical;
v3 is a coordinated wire/storage transition, never mixed writers or automatic
adoption of old test state. The owner attested no real customer payments.

## Outcome

Before opening Play for an eligible new purchase, Archivale stores a stable
opaque account reference on the server and passes it to Play. The same active
Archivale account uses that reference across installations and sign-ins.
Foreground verification derives the expected reference from authenticated
server state. Local Play receipts are candidates, not account authority.

This supplies routing for a later background lifecycle worker. It does not
implement RTDN, scheduled reconciliation, void processing, deletion, a broker
bridge or the accepted seven-day offline creation lease. Access here remains
the existing short memory-only verification lease. The archive remains usable
without an account; Google is required only for purchase/restore.

## Exact protocol

All callable responses use `version: play-billing-v3`; disclosure is
`billing-verification-disclosure-v4`, purpose `play_subscription_verification`.
Existing verify/restore request fields and paid/non-paid response fields retain
the v2 shapes and fixed status/reason mappings, with these new versions.
Old disclosure does not authorize v3 operations. Disclosure v4 explains the
stored account reference sent to Play, alongside encrypted confirmation storage;
it does not authorize artwork transfer, backup or AI processing.

New callable `preparePlayPurchase`:

- Exact request: `version`, canonical UUID `requestId`, `billingDisclosureVersion`;
  body at most 1 KiB. UID, provider, subject, epoch and route are never accepted
  from the client as authority.
- Exact success: `version`, echoed `requestId`, `status: ready`,
  `obfuscatedAccountId`, `lifecycleEpoch`.
- Account reference: exactly 32 server-generated random bytes, canonical
  unpadded base64url (43 characters). Epoch: 16 random bytes as 32 lowercase hex
  characters. Neither is an authentication credential or payment proof.
- Failure: `version`, optional valid `requestId`, `state: free`, fixed status/reason.
  `rejected` permits `invalid_request`, `identity_rejected`, `disclosure_required`,
  `recovery_required`, `unsafe_record`; `unavailable` permits
  `temporarily_unavailable`, `rate_limited`. Prepare never grants paid access.

Revoked-checked Google Firebase identity and consumed approved-app App Check
remain required. The shared callable guard accepts only SDK-verified
`request.app.alreadyConsumed === false`; true, absent or malformed consumption
state rejects before the additional revoked-token Auth check or billing work.
The pinned [Functions SDK v7.2.5](https://github.com/firebase/firebase-functions/blob/v7.2.5/src/common/providers/https.ts)
marks a consumed-but-valid token as valid context, so configuration alone does
not enforce freshness. Every v3 callable additionally requires the disabled-by-default
`PLAY_BILLING_ROUTING_ENABLED=enabled`. Prepare, verify and restore also require
the existing recovery switch; Publisher and custody have their separate gates.
No disabled default performs credential lookup or a provider call.

Mobile preserves Google/disclosure -> awaited account Restore/local receipt
preflight -> purchase eligibility and product preflight -> prepare -> buy.
The preparation UUID is separate from receipt verification. Paid, pending,
unavailable, hold/pause, ambiguous, legacy or retired recovery cannot launch a
purchase. Prepare is still secure when a direct caller skips mobile preflight.
Restore never creates a lifecycle. With no root and no legacy/orphan records,
it returns no-known-purchase. The locked Android local query ignores its old
account argument; the facade now queries receipts without one. There is no
UID-hash fallback for purchase or restore.

## Reciprocal lifecycle authority

The named billing database contains `playBillingLifecycles`, keyed by existing
HMAC account subject, and `playBillingAccountRoutes`, keyed by a separately
domain-separated HMAC of the opaque account reference. Raw Firebase UID/email
is not stored. Only the lifecycle root stores the opaque reference; it is
excluded from Firestore indexing and telemetry.

The strict root contains version `play-billing-lifecycle-v1`, subject, epoch,
positive safe-integer generation, status `active|consent_paused|retired`, route
fingerprint, opaque reference, assertion identity and created/updated timestamps.
The strict reverse route contains version `play-billing-route-v1`, subject,
epoch, generation, status and assertion identity. Reciprocal mismatches fail
closed. There is no untyped metadata or partial repair.

First prepare reads root, disclosure, account index and bounded exact-subject
binding/route queries in its creation transaction. Any legacy/orphan state
prevents creation. Route collisions fail closed. New root/route are committed
atomically; retry, concurrent prepare or a lost response returns the existing
active route. No renewal, sign-in, installation or ordinary disclosure refresh
rotates it. A ready result does not permit a second subscription.

Accept/revoke disclosure updates an existing root and route atomically with a
fresh assertion identity. Reacceptance resumes a paused lifecycle; revocation
pauses it, including when its old assertion has been removed by TTL. With no
lifecycle, these actions only affect disclosure. Malformed reciprocal state is
rejected without writes. Epoch/generation/route remain stable and retired state
never revives. Fresh-install reaccept followed by Restore works without prepare.

Bindings, indexes, token operations and request replays explicitly carry the
lifecycle epoch/generation. Every authority transaction validates the current
reciprocal root, disclosure assertion, epoch, attempt owner and account revision.
Provider dispatch rechecks current authority after delayed acquire/delivery
results. Paid/inactive response ordering and both account-chain pointer checks
from v2 remain mandatory.

An unverified token operation is only a lease/cost record, not durable account
ownership. Another lifecycle may reclaim it after the existing lease/cooldown
only when it has no binding, verified account subject or acknowledgement history,
and its phase is lookup/free/canceled-pending-read-only. Reclamation retains
cost history and advances owner generation/nonce, so old results and replays
cannot mutate the new attempt. Verified-owner claims survive subsequent lookups;
bindings, custody and acknowledgement state never transfer this way.

The internal repository retirement primitive takes an expected epoch/generation
and atomically retires root/route while advancing generation. It invalidates
older attempts and refuses stale/overflowed state. It has no public endpoint,
identity deletion, erasure, account cancellation or automatic recreation.
Source-only high-water records have no TTL; this is not approved permanent
production retention. Retention/recreation policy remains a launch blocker.

## Custody transition

Envelope exact keys remain `version`, `keyVersion`, `ciphertext`, with version
`play-token-custody-v2`. Canonical AAD is UTF-8 JSON of this ordered string array:

`[custodyVersion, packageName, databaseId, accountSubject, lifecycleEpoch,
String(lifecycleGeneration), tokenFingerprint, exactFullyQualifiedKmsCryptoKeyVersion]`.

Epoch/generation come from trusted records, not envelope labels or client input.
The existing exact KMS version allowlist, returned-version check, CRC32C,
strict base64 and bounded transport remain. Cross-epoch/generation replay,
old envelope version and same-key ciphertext version relabel fail closed.
No existing ciphertext is re-encrypted or adopted automatically.

## Validation and remaining gates

Focused tests cover first registration/concurrency/lost response, direct legacy
and orphan bypass attempts, disclosure/TTL transitions, fresh-install restore,
old UID-hash rejection, epoch AAD replay, retirement at transaction/KMS/provider
boundaries and the existing recovery ordering/chain regressions. Named Firestore
emulator tests cover reciprocal persistence, concurrent registration, reacceptance,
retirement and denied client access. These are synthetic tests, not live IAM,
Play-track or KMS evidence.

Public launch still requires background routing/RTDN, reconciliation and voids,
retention/deletion and recreation policy, seven-day signed offline leases,
paid-AI allocation/bridge, monitoring and budget policy, actual provider/IAM
configuration, internal-track lifecycle evidence, independent reviews and owner
release approval. Prices/countries and plan replacement/proration remain owner
choices. Rollback preserves custody/lifecycle high-water; never run v1/v2 writers
against v3 records or delete the registry as an operational shortcut.

Primary platform reference: [Play obfuscated account identifier](https://developer.android.com/reference/com/android/billingclient/api/BillingFlowParams.Builder#setObfuscatedAccountId(java.lang.String))
limits the field to 64 characters and prohibits cleartext personal information.
The 43-character random stable reference satisfies those constraints by design;
Google does not prescribe this exact random-route architecture.
