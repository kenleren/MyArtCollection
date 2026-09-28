# Paid Android account recovery, disabled source slice (#194)

Status: implementation candidate for independent task/payment/privacy review.
No provider configuration, purchase, deployment or store release is authorized.
The [internal-v1 gate](PLAY_BILLING_GATE_SPEC.md) is historical; this is a
coordinated v2 wire/storage transition, not a mixed-writer upgrade.

## Outcome and boundaries

A purchase already verified by Archivale can be recovered after fresh Google
sign-in on another installation without a token from that device. The server
resolves the account's encrypted token, re-queries Play and uses the existing
delivery/acknowledgement state machine. An account index or cached expiry alone
never grants access. Google identity and the Play purchasing account are
separate; sign-in does not upload collection records or enable backup/AI.

Accepted owner decisions: Google is required for purchase/restore only; local
archive use is account-optional. There have been no real customer payments
(owner attestation). Seven-day offline creation capped at Play expiry and UTC
calendar-month AI credits/no rollover/no usage reset on upgrade are accepted
but **not implemented by this slice**. Authority here remains a maximum
15-minute, memory-only lease. Foreground/resume clears that lease before a
fresh verification; a Dart Stopwatch is not suspend-inclusive authority.

## Exact callable boundary

All responses use `version: play-billing-v2`. Revoked-checked Google Firebase
identity and consumed approved-app App Check derive the account; client body
fields cannot select UID, provider, subject, token fingerprint or entitlement.

| Callable | Exact request fields |
| --- | --- |
| `acceptPlayBillingDisclosure` | `requestId`, `disclosureVersion: billing-verification-disclosure-v3`, `purpose: play_subscription_verification`, literal `accepted: true` |
| `revokePlayBillingDisclosure` | Same, without `accepted` |
| `verifyPlaySubscription` | `version: play-billing-v2`, `requestId`, `billingDisclosureVersion: billing-verification-disclosure-v3`, `productId`, `purchaseToken` |
| `restorePlayEntitlement` | `version: play-billing-v2`, `requestId`, `billingDisclosureVersion: billing-verification-disclosure-v3` |

Requests require canonical UUIDs and exact keys. Restore/disclosure bodies are
at most 1 KiB; purchase verification is at most 8 KiB and token UTF-8 at most
4 KiB. Disclosure v3 explains encrypted subscription-confirmation storage for
recovery, without artwork/record transfer or implied Drive/AI permission.

Paid replies have `status: paid`, an allowlisted plan/product, supported
`state: active|grace|canceled`, and verified/Play/lease timestamps. Non-paid
replies have `state: free` and a fixed reason with status:

- `none`: `no_known_purchase`, `expired`, `on_hold`, `paused`, `revoked`;
- `pending`: `in_flight`, `verification_pending`, `play_pending`;
- `unavailable`: `temporarily_unavailable`, `rate_limited`;
- `rejected`: invalid request/identity/disclosure, replay conflict, unsafe
  record, unverified purchase, `account_conflict` or `recovery_required`.

No token, ciphertext, UID, subject, order or attempt owner appears in replies.
No known purchase is not proof that the device's Play account has no receipt.
Malformed, legacy or orphan state cannot be translated to no known purchase.
An exact-subject, limit-one legacy lookup precedes that result. Legacy test
bindings remain untouched and require explicit recovery/test handling; there
is no cross-UID transfer, live reset or automatic v1 backfill.

## Atomic durable custody and account selection

Only `archivale-play-billing` is used. `playBillingAccountSubscriptions` is keyed
by the existing HMAC account subject. Its revision and current/pending token
fingerprints select one chain; it has no independent payment authority.
The encrypted envelope is committed on the existing purchase binding in the
same transaction that installs its account pointer, **before acknowledgement**.
Thus an interrupted delivery is discoverable after reinstall. A linked
successor retires its predecessor and becomes current in the acknowledgement
finalization transaction. Unrelated active chains cannot overwrite each other.
An unrelated expired chain needs a fresh verified-expired observation (within
15 seconds of the new verification) and the same index revision to be replaced.
Its obsolete current pointer is cleared atomically when staging the unrelated
candidate, while the encrypted binding is retained. A crash before acknowledgement
therefore leaves one discoverable candidate without an invented lineage link.

A restore resolves the index and acquires the existing request/token attempt
and rate budget before decrypting. Both current and pending index pointers must resolve valid same-account
bindings before custody or Play work (at most two indexed binding reads). A
distinct current/pending pair must be a staged predecessor/successor chain;
conflicting successor pointers or incompatible delivery phases fail closed.
The selected token, operation kind and index revision are fenced; duplicate request IDs cannot switch token/action.
The existing 90-second owner lease, 15-second cooldown and counted Play/ack
limits remain. Ownership is never adopted by reading a stored nonce.

Every disclosure acceptance/revocation gets a fresh server-generated 128-bit
assertion identity, including after TTL recreation. Delivery, acknowledgement,
finalization and response authority check that assertion, index revision and
attempt owner. Unknown state fails closed. A verified inactive observation
advances the account revision, fencing older paid replies. Final paid replies
also require the current paid operation/replay owner; inactive replies require
a committed observation and successful owner-fenced close. A network/KMS error
is not evidence of expiry.

V2 active bindings and account indexes have no expiry-derived TTL. The existing
v1 TTL configuration remains for older records. Ciphertext is not indexed.
Production retention/deletion policy is unresolved; this is a release blocker,
not an indefinite retention promise. Do not enable this slice alone publicly.

## KMS protocol and deadlines

`TokenCustody` is a narrow testable boundary. The real `GoogleKmsTransport`
uses existing Google Auth plus KMS REST, with no custom encryption or local
master key. Defaults construct a disabled adapter with zero credential lookup
or network use. Enabling requires the separate recovery, Publisher and custody
switches plus exact configured encryption/retained key-version allowlists.

Canonical AAD is UTF-8 JSON of an ordered string array, no optional fields:
`[custodyVersion, packageName, databaseId, accountSubject, tokenFingerprint,
kmsCryptoKeyVersion]`. The last value is the exact fully qualified approved
CryptoKeyVersion. Encryption pins that version and validates KMS's returned
name. Decryption allowlists the envelope version and reconstructs AAD, then
addresses its parent key. KMS chooses the actual version from ciphertext and
returns no exact version name; `usedPrimary` is not version proof. Relabeling
ciphertext to another version under the same key must fail authenticated
decryption before any Play call. Decrypted bytes must match the fingerprint.

CRC32C request/response integrity fields, strict base64, bounded transport body
(32 KiB), ciphertext and plaintext are checked. Raw tokens stay in bounded
request memory and approved KMS/Play calls, never logs or records. JavaScript
string zeroization is not promised. Fake encryption exists only in tests.

The whole callable has a 55-second deadline starting before authentication;
individual external operations have at most ten seconds and no hidden retries.
Timeout permanently invalidates that invocation, including late Auth/body/
transaction callbacks. Play lookup and acknowledgement dispatch are deferred
until immediately after checking the invocation cancellation and time budget. Transactions check their fence before and after their
callback; no external calls occur inside retryable transactions. Already
submitted remote work cannot be recalled: no late result may issue client
authority or start acknowledgement, and persisted state must still pass the
next current owner/disclosure/index checks. This is not a claim that a database
network commit or a Play acknowledgement can be physically canceled.

## Remaining release requirements

This slice proves a synthetic foreground journey only. It cannot discover a
purchase whose token never reached Archivale, or an unknown replacement token.
RTDN, account-binding registration, scheduled reconciliation, void/refund
handling and unattended acknowledgement recovery remain required. KMS/Firestore
IAM, key provisioning/rotation/retention, exact runtime monitoring and costs
remain human-owned and untested live.

Seven-day signed leases, paid-AI allocation, deletion/tombstone/retention and
active-subscription recreation policy are later slices. Tier replacement and
proration need a concrete launch policy; do not launch a second independent
subscription while restore or an existing plan is active/unresolved.

Independent output/payment/privacy review, mobile visual/device evidence,
Play-track purchase/reinstall/multidevice/lifecycle tests and owner deployment/
store approval remain open. Rollback preserves custody and account recovery;
never delete bindings or let internal-v1 writers mutate v2 state.

Primary protocol references checked 2026-09-28:
[Play security](https://developer.android.com/google/play/billing/security),
[subscription lifecycle](https://developer.android.com/google/play/billing/lifecycle/subscriptions),
[KMS encrypt](https://docs.cloud.google.com/kms/docs/reference/rest/v1/projects.locations.keyRings.cryptoKeys/encrypt),
[KMS decrypt](https://docs.cloud.google.com/kms/docs/reference/rest/v1/projects.locations.keyRings.cryptoKeys/decrypt),
[KMS AAD](https://docs.cloud.google.com/kms/docs/additional-authenticated-data).
