# Paid Android Public Beta Acceptance

The owner requested a fully functional public beta suitable for recruiting
customers, and confirmed on 2026-09-28 that launch is paid and Android first.
iPhone follows later. A free private beta does not satisfy this release target.

GitHub Project #1 remains the live source for task status, ownership and
dependencies: https://github.com/users/kenleren/projects/1. This document defines
the release outcome, not a second work queue. Issue closure, passing isolated
tests and a successful upload alone do not prove that outcome.

## Required customer journey

| Requirement | Release evidence |
| --- | --- |
| A prospective customer can understand the beta, price, limits, privacy and support, then reach the correct Android install/purchase destination. | Published website and Play listing match the actual release; links and support route are exercised. |
| A new collector can photograph/import an artwork, edit and confirm its record, and find it after restarting offline. | Real-device first-run and returning-user checks with a synthetic collection. |
| Receipts, PDFs and other supported records can be attached, reopened and replaced without losing the original artwork record. | Real-device document flow, including cancellation, missing files and unsupported input. |
| Opt-in AI drafts useful suggestions through the server broker; the collector confirms them. | Exact release artifact against the approved broker; consent, image redaction, quota, retry/idempotency, failure and kill-switch evidence. No mobile provider keys or direct provider calls. |
| Subscription purchase and restore grant only server-verified access. | Play-track purchase, pending, cancellation, restore, renewal/expiry, refund/revocation and account-change evidence; existing records remain readable/exportable when paid access ends. |
| Optional encrypted Google-account backup restores a collection on a fresh installation. | Synthetic fresh-install restore proves record and attachment integrity; wrong passphrase, damaged/incomplete backup, disconnect and replacement behavior are tested. Recovery limitations are disclosed. |
| PDF reports and portable archive exports contain the promised records and files. | Generated files are opened outside Archivale; confirmed versus suggested/user-provided facts and excluded attachments are clear. |
| Removing local data truthfully removes owned record, attachment and generated-output data, including after interruption. | Crash/restart and retry evidence plus real-device removal journey. Shared exports and remote/device backups are not represented as locally deleted. |
| Customer records survive normal upgrades and recoverable failures. | Migration, interrupted-write and representative collection tests; no silent data loss or overwrite. |
| The beta can be operated and withdrawn responsibly. | Accepted independent task/visual/privacy reviews, passing checks for the exact candidate, owner-signed release, matching privacy disclosures, named support owner, cost caps/monitoring and a tested rollback path. |

## Existing work that feeds this release

- Core, attachments and exports: #178, #179, #211, #212, #214.
- Subscription purchase, verification and operation: #176, #193, #194, #209.
- Live AI activation: #115, #155, #177, #217.
- Backup and recovery: #180.
- Local deletion and generated-file ownership: #199, #221, #232.
- Recruitment, pricing and measurement: #181, #182, #184.
- Validation and release controls: #196, #257, #259, #261.

Inspect current source and issue evidence before treating any item as complete.
Pricing, AI allowances, store configuration, support ownership and backup
recovery choices must be concrete before the final release review.

## Owner-controlled release steps

Prepare reviewable source, artifacts, configuration proposals, costs and
rollback evidence before asking for operational approval. Repository rules
continue to require explicit owner approval for provider/Firebase/billing
account changes, deployment, store submission and external publication.
Credentials, signing material and tester lists remain human-owned and must not
be inspected by an agent.

The first launch decision concerns the complete paid Android journey above.
An unverified capability must remain an open release requirement; hiding it or
calling it a preview does not complete this goal.

## Accepted identity and AI-period decisions

Google sign-in is required for purchase and restore only; the local archive
remains account-optional. AI credits renew by UTC calendar month with no
rollover; upgrades raise the month's allowance without resetting use.
[The identity foundation](PUBLIC_BETA_IDENTITY_SPEC.md) is one source slice,
not evidence of a completed public paid journey. Account-scoped recovery,
payment lifecycle, monthly allowance enforcement, deletion and exact-build
Play/device evidence remain required. The owner approved seven-day offline creation capped at Play expiry and attests that no real customer subscription payments have occurred. Signed offline leases remain unimplemented. The [disabled account-recovery source slice](PLAY_BILLING_RECOVERY_V2_SPEC.md) does not complete the public payment lifecycle.
