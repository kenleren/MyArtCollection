# Paid Android identity foundation (#194, Slice A)

Status: source implementation for independent review; no live configuration,
activation, complete restore claim or public release approval.

## Accepted decisions

- Google sign-in is required only before purchase and restore. Manual local
  collection use stays account-optional. Opening the app or plan screen does
  not silently initialize Google sign-in.
- AI credits use UTC calendar months with no rollover. Upgrades raise that
  month's allowance without resetting usage. This rule is accepted but its
  billing-to-broker allowance implementation belongs to a later slice.
- Verified subscribers may create artworks offline for up to seven days,
  capped at subscription expiry. AI requires an online server check and
  existing records remain accessible. Signed offline leases are not
  implemented in this slice.
- On 2026-09-28, the owner confirmed there have been no real customer
  subscription payments. This is an owner attestation, not a live account audit.

## Implemented identity contract

The official `google_sign_in` 7.2 plugin obtains a Google ID credential after
explicit billing disclosure. Firebase `linkWithCredential` upgrades an
accessible anonymous session without changing UID, preserving the existing
UID-derived Play binding and broker quota subject. A fresh installation uses
`signInWithCredential` to recover the same Google-backed Firebase UID.
Google reauthentication after linking and a forced ID-token refresh ensure
server verification sees `google.com`, rather than a stale anonymous claim.

A credential collision never silently merges identities, purchases, credits
or local records. The UI offers a separate, explicit existing-account sign-in
followed by restore. Canceling sign-in starts no billing operation. An account
change while sign-in or verification is pending fences the old operation.
Provider changes are observed even when UID stays the same.

Billing callables require the Google provider from revoked-checked Admin
Auth verification and matching callable UID. The request body cannot select
a provider. Broker verification accepts only `anonymous` and `google.com`,
propagates the verified provider through every adapter, and preserves existing
consent, owner allowlist, entitlement, credit and provider gates. It cannot
mint a paid entitlement merely because Google sign-in succeeded.

Google identity, the Play purchasing account and optional Google Drive backup
permission are separate. This implementation requests no Drive scopes and
uploads no collection records for authentication. Sign-in does not enable
research or backup. No identity service reads or mutates local artworks.

## Wire/disclosure migration and staged release

`billing-verification-disclosure-v2` replaces v1 because the UI now explains
durable Google identity. Older, structurally valid v1 assertions do not
authorize a Play call but can be replaced by a new affirmative v2 acceptance
or revoked. Unknown/malformed assertions still fail closed.

The `play-billing-v1` response/delivery protocol and its 15-minute memory-only
lease remain in place for this foundation slice. This is not the completed
public billing-v2 lifecycle. Existing deployed v1 mobile/server combinations
must not be mixed with these new identity/disclosure requirements without an
owner-controlled coordinated rollout. Firebase and Android Publisher defaults
remain disabled; no provider/Play/Firebase configuration was changed.

Lost anonymous sessions cannot recover the original binding from a purchase
token alone. The owner confirmed there are no real paying customers to
migrate. Existing test purchases still need explicit recovery/reset handling
during release validation. Do not transfer tokens across UIDs automatically.

## Remaining public-beta work

Account-scoped server entitlement recovery, RTDN, scheduled reconciliation,
KMS token custody, signed offline leases, monthly paid-AI allowance allocation,
account deletion and customer-support lifecycle remain separate #194 slices.
Google sign-in provides the identity foundation; it does not prove that a
fresh-install or multi-device paid restore works end to end.

Operational dependencies: owner-configured Google Firebase provider and
approved Android OAuth/certificate configuration; review of public disclosures
and Data Safety; independent task/payment/privacy review; exact Play-track
purchase/restore and real-device visual evidence. No account, provider,
credential, signed-build, store or deployment action is authorized by this
source change.

## Focused checks

- UID-preserving anonymous link; fresh-install existing account sign-in;
  canceled picker; credential collision and explicit recovery; same-UID
  provider observation; sign-out during an outstanding dialog.
- Google cancellation makes zero disclosure/Play calls; same-UID provider
  removal rejects delayed disclosure/entitlement authority.
- Verified Google billing identity and UID matching; unsupported providers
  rejected; legacy disclosure reacceptance without stale authority.
- Broker Google identity survives verification/adapters and keeps its quota
  subject, while current entitlement/consent/cost gates still apply.
- Narrow mobile billing disclosure and cancellation/collision interaction.

## Primary implementation references

Checked 2026-09-28:

- [Firebase Flutter Google integration](https://firebase.google.com/docs/auth/flutter/federated-auth)
- [Firebase anonymous account linking](https://firebase.google.com/docs/auth/flutter/anonymous-auth)
- [Firebase same-UID linking](https://firebase.google.com/docs/auth/flutter/account-linking)
- [Official Google sign-in plugin](https://pub.dev/packages/google_sign_in)
