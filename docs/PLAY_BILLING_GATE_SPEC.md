# Play Billing Gate Spec

Status: implementation-ready app gate; Play Console setup remains human-owned
Date: 2026-07-07

## Scope

This spec records the launch entitlement gates for the Android Play-ready build.
It does not authorize Play Console mutation, real purchase testing, production
store submission, live provider calls, Blaze enablement, or billing-secret
handling.

## Launch Entitlements

| Plan | Planned Play product ID | Price | Active artworks | AI credits |
| --- | --- | --- | --- | --- |
| Free | n/a | USD 0 | 5 | 1/month |
| Starter | `archivale_starter_monthly` | USD 2.99/month | 50 | 10/month |
| Collector | `archivale_collector_monthly` | USD 4.99/month | 200 | 50/month |
| Archive | `archivale_archive_monthly` | USD 9.99/month | Unlimited | 200/month |

Rules:

- Active artwork caps limit creation of new active artworks only.
- Existing records remain viewable, editable, reportable, and exportable.
- AI credits must not gate manual cataloging, existing record access, record
  edits, or export safety.
- Credit packs remain future work and require separate cost, broker, and Play
  product approval.

## App-Side Gate

The app defaults to the Free plan until a trusted entitlement source proves a
paid plan. The current gate protects:

- collection add-artwork entry,
- direct photo capture/import routes,
- CSV import writes after preview/mapping.

CSV preview remains available so a collector can inspect mappings and cancel
without writing. The final write re-checks the local record count and refuses
imports that would exceed the active-artwork cap.

## Remaining Play Console Work

Human-owned setup before real purchases:

1. Create subscription products and monthly base plans in Play Console using the
   product IDs above or record the final IDs before client integration.
2. Confirm tax, merchant, country, price, and tester-account settings.
3. Add Play Billing Library integration in a new implementation task after the
   product IDs are stable.
4. Validate purchase, restore, cancellation, expiry, grace-period, and account
   switching behavior on internal testing.
5. Update Data safety and store-listing disclosure if the distributed build
   adds billing SDK telemetry or mandatory account identity.

## Non-Goals

- No direct OpenAI/provider calls from mobile.
- No server-side provider billing changes.
- No Play Console mutation from Codex.
- No promise that a public price is final until the Play products are approved.
