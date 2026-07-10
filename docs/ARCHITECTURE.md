# Architecture Plan

## Recommendation

Build the MVP as a local-first Flutter app with optional Google Drive backup, a
thin server-side AI broker, and isolated Play Billing verification inside the
single approved Firebase/GCP project `my-art-collections`.

Recommended stack:

- Client: Flutter
- Local structured data: SQLite
- Local attachments: app-private file store
- Backup/sync: blobs and manifest in Google Drive `appDataFolder`
- Export: explicit user-triggered ZIP and PDF export through system share/document pickers
- AI: opt-in server-mediated multimodal extraction, never direct vendor calls from the app
- Cloud identity: anonymous Firebase Auth plus App Check only after a
  purpose-specific billing disclosure or AI research consent; billing also
  requires its own current purpose-bound server assertion
- Android paid access: Google Play state verified server-side under
  [Play Billing Gate Spec](PLAY_BILLING_GATE_SPEC.md)

## Product Architecture Principles

- Core cataloging should work without an app account or cloud identity.
- The device is the primary source of truth.
- Google Drive backup is optional, not a login requirement.
- The app should work offline for capture, edit, search, report generation, and export.
- AI upload must be explicit and minimal.
- Export is a first-class recovery path, not an afterthought.

## Why Flutter

Flutter is the recommended MVP client because the product needs:

- High-quality iOS and Android UI from one codebase
- Camera, photo picker, document picker, file, and PDF capabilities
- Fast iteration across app-store targets
- A premium custom interface without building two native apps immediately

Native iOS and Android may become appropriate later if the app needs deep platform-specific capture, OCR, or background sync behavior.

## Local Data

See [Local Storage Spec](LOCAL_STORAGE_SPEC.md) for the canonical storage and attachment rules.

Use SQLite for structured records:

- artworks
- attachments
- reports
- ai_jobs
- sync_state
- export_jobs

Use app-private file storage for binary assets:

- artwork photos
- document scans
- PDFs
- generated reports
- export archives

Keep the exact encryption design in a separate crypto task so the prototype spec does not overclaim a solved at-rest story.

## Backup And Sync

Use Google Drive `appDataFolder` for automatic backup/sync.

Store:

- manifest
- record snapshots
- attachment chunks
- sync metadata

Use opaque IDs and metadata that do not leak artist names, titles, or locations through filenames.

Treat MVP sync as eventual backup/restore and light multi-device sync, not collaborative real-time editing.

Conflict rule:

- Never silently overwrite.
- Create a conflict copy when both local and remote records changed.

## Google Drive Decision

Primary storage target:

- Google Drive `appDataFolder`

Do not use as primary storage:

- User-visible Google Drive folder
- Google Photos

Reasoning:

- `appDataFolder` matches hidden app-specific backup.
- It can use a narrower Drive scope than broad Drive access.
- Visible folders improve transparency but leak metadata and create user-edit risks.
- Google Photos is unsuitable as primary storage because API access has become more limited, especially for non-app-created media.

Required compromise:

- Automatic Drive backup in `appDataFolder`
- Explicit user export of ZIP/PDF to any visible destination

Important caveat:

- Users can delete app hidden data from Drive settings, so export must remain easy and obvious.

## Google Photos Stance

Do not use Google Photos as backup or record storage in MVP.

Use:

- Camera capture
- Android Photo Picker where available
- iOS photo picker
- System document picker

If users want copies in Photos, make it an explicit share/save action.

## AI Pipeline

Use two stages.

### Stage 1: On-device Preprocessing

Possible local work:

- EXIF reading
- image downscaling
- cropping
- basic OCR where feasible
- document page extraction
- heuristic parsing of dimensions, dates, and seller text

### Stage 2: Opt-In AI Broker

Flow:

1. User taps an AI action.
2. App explains what will be uploaded.
3. App uploads only the minimum required image, document page, or extracted text.
4. Server broker calls the AI provider.
5. Response is schema-validated.
6. App shows suggested fields with provenance and uncertainty.
7. User confirms before record data becomes verified.

Do not call AI vendors directly from the mobile app.

### One-Project Cloud Boundaries

`my-art-collections` is the only approved Firebase/GCP project. Isolation is by
codebase, function, runtime identity, IAM, collections, secrets, telemetry, and
rollback target rather than by another Firebase project:

| Surface | Research AI | Play Billing |
| --- | --- | --- |
| Codebase/function | `broker` / `artResearchBroker` | `play-billing` / `verifyPlaySubscription` |
| Runtime authority | Provider call plus broker-owned/default-database records | Android Publisher verify/acknowledge plus named-billing-database records |
| Firestore boundary | Broker/default database; no billing-database IAM | Named `archivale-play-billing`; database-conditioned IAM; deny-all client rules |
| Durable records | Versioned broker control, entitlement, credit, request, and ledger records | Disclosure assertions, purchase delivery/bindings, replay, token-operation, and rate-limit records |
| User authority | Current explicit AI research consent plus broker gates | Current purpose-bound billing-disclosure assertion plus verified Play state |
| Rollback | AI breaker, route/runtime IAM, provider credential | Billing callables/codebase/runtime IAM/rules; never routine database deletion |

Anonymous Auth is shared identity infrastructure, not shared authority. Billing
identity may be created or reused only after the collector initiates purchase
or restore and accepts the billing disclosure. That action does not create AI
consent, enable research, or authorize collector content to leave the device.
The official acceptance flow writes a versioned, purpose-bound server assertion
before verification; UID existence, AI research consent, and App Check do not
substitute for it. AI research consent does not prove payment. App Check
attests an app instance; it proves neither identity, consent, nor payment.

The AI broker cannot call Android Publisher APIs or access
`archivale-play-billing`; the billing verifier cannot access broker/artwork
records in another database. Runtime IAM is conditioned per database and all
mobile/web client access to the billing database is denied by Security Rules.
`brokerDurableEntitlements` has no payment authority. Billing verification
cannot bypass AI owner allowlist, research consent, broker entitlement,
breaker, credit, payload, or provider gates.

### Android Paid Access

Google Play is the payment-state authority. The server verifies the fixed
`app.archivale` subscription allowlist with
`purchases.subscriptionsv2.get`, checks the exact Auth-derived account binding,
and serializes work by purchase-token fingerprint. It durably commits verified
entitlement delivery in `archivale-play-billing` before acknowledging eligible
new purchases with `purchases.subscriptions.acknowledge`. A lease is returned
only after acknowledged delivery and final binding state are committed or
safely recovered.

Distinct request IDs for one token share a token single-flight owner; bounded
per-subject/token ceilings limit Play calls and acknowledgement races. A crash
before delivery makes no acknowledgement. A crash/timeout after delivery or
acknowledgement retains recoverable sanitized state; retry re-verifies current
Play state and never acknowledges twice blindly.

The app holds only a lease capped at 15 minutes and Play expiry, in process
memory. Only verified active, grace-period, or canceled-with-future-expiry
states receive paid access. Unknown, pending, paused, on-hold, expired,
mismatched, unavailable, failed-acknowledgement, expired-lease, and restart
states fail to Free. A canceled pending replacement may preserve only a
separately re-verified valid predecessor. That branch occurs before successor
eligibility; it validates the predecessor's own product/base plan/offer and
returns predecessor plan/product/expiry, including cross-product replacement
failures.

No mobile paid lease or client/offline-authoritative entitlement is persisted.
Downgrade limits new paid actions but keeps every existing artwork and
supporting record viewable, editable, reportable, and exportable. #194 is
mandatory before any paid build moves beyond internal testing because the MVP
lacks RTDN, reconciliation, voided-purchase processing, encrypted token
custody, durable account recovery, and reliable reinstall/multi-device/offline
entitlement.

The durable purchase binding is server-only delivery/recovery state, not a
persisted mobile/offline lease and not payment authority by itself. Current Play
verification plus acknowledged final state are required for every returned
lease.

The mobile coordinator keeps a monotonic in-memory entitlement generation.
Each new authoritative refresh captures its request ID, current anonymous UID,
and generation; account change, sign-out, failure, or a newer refresh clears
the lease and invalidates older work. A response installs only when all three
still match, preventing delayed paid/Free results from crossing account or
refresh boundaries.

## AI Response Requirements

Responses must include:

- suggested field value
- field source:
  - image
  - document
  - user
  - existing record
  - unknown
- uncertainty label:
  - high confidence
  - medium confidence
  - low confidence
  - unknown
- evidence snippet or visual note when available
- explicit warning if the field touches attribution, authenticity, or value

User-confirmed values always override AI suggestions.

## Security And Privacy Controls

Required:

- Local-only mode by default
- Explicit consent before AI upload
- No broad photo or storage permissions
- System pickers for import
- App-private local storage by default
- Separate crypto and backup design work before any encryption guarantee is claimed
- Token revocation on disconnect
- Delete local data flow
- Disconnect Drive flow
- Clear export flow
- Minimal AI broker logging
- No long-term AI payload retention unless explicitly disclosed and justified
- No raw purchase/linked/Auth/App Check tokens, UID, account binding, order
  data, or Play response body in storage, logs, telemetry, screenshots, or
  evidence; only the billing spec's one-way binding records may persist
- Independent AI and billing runtime/IAM/rollback boundaries inside
  `my-art-collections`
- Named billing database with database-conditioned runtime IAM, deny-all client
  rules, and negative cross-database/client tests
- Purpose-bound billing-disclosure assertion before any Play call
- Token single-flight/call ceilings and client request/UID/generation fences

## App Store Implications

If charging for subscription or app features:

- Use Apple In-App Purchase on iOS.
- Use Google Play Billing on Android.

Avoid making Google Sign-In the primary account system for MVP. Make Google Drive an optional backup connection instead. This keeps the app simpler and avoids making Google identity a mandatory login surface.

Anonymous Firebase identity used for billing or research remains
purpose-disclosed infrastructure, not a general Archivale account and not a
replacement for optional Drive connection.

Expect to prepare:

- Apple App Privacy disclosure
- Google Play Data safety disclosure
- Apple encryption/export compliance answers
- Account deletion flow if a real app account is introduced later

## Offline Behavior

Works offline:

- create artwork
- edit artwork
- attach local documents
- search/list records
- generate PDF report
- export archive

Unavailable offline:

- AI suggestions
- paid-plan verification or refresh; after lease expiry/restart the app remains
  Free until online verification succeeds
- Drive backup/sync
- cloud restore

Sync resumes on foreground, manual backup, or connectivity return.

## Redteam Gates

Before public beta:

- Confirm no restricted Drive scopes are used.
- Verify encryption and restore work are specified and implemented in the follow-up crypto/backup path.
- Verify exports are always explicit user actions.
- Verify AI upload payloads are minimal and logged safely.
- Verify no screen implies authenticity, attribution certainty, or appraisal certainty.
- Verify disconnect, wipe, and token revocation flows.
- Verify store privacy declarations match actual SDK behavior.
- Verify billing and AI disclosures remain separate even when they reuse one
  anonymous UID.
- Verify missing/stale/research-only billing assertions cause zero Play calls.
- Verify client/broker/verifier identities cannot cross the named database
  boundary and that server clients are governed by IAM, not client rules.
- Verify payment state comes only from the canonical server contract, raw
  billing identifiers never enter evidence, and downgrade preserves existing
  record access.
- Verify delivery-before-ack crash recovery, canceled-pending cross-product
  predecessor recovery, token serialization/call ceilings, and delayed-response
  generation fences.
- Require independent task review and payment redteam for billing contracts;
  require #194 privacy/deployment/payment acceptance before paid rollout beyond
  internal testing.

## Implementation Phases

1. Local-first shell:
   - schema
   - storage hardening
   - capture/import
   - manual export
2. Google Drive backup/restore:
   - `appDataFolder`
   - manifest
   - restore path
3. AI assist:
   - broker
   - schema validation
   - confirmation UI
4. Reporting:
   - PDF insurance report
   - archive export
5. Hardening:
   - conflict handling
   - privacy review
   - app-store submission readiness

## Sources To Recheck Before Implementation

- Google Drive app data folder: https://developers.google.com/workspace/drive/api/guides/appdata
- Google Drive scopes: https://developers.google.com/workspace/drive/api/guides/api-specific-auth
- Google Photos API updates: https://developers.google.com/photos/support/updates
- Android Photo Picker: https://developer.android.com/training/data-storage/shared/photopicker
- Apple App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- Apple App Privacy: https://developer.apple.com/app-store/app-privacy-details/
- Google Play Data safety: https://support.google.com/googleplay/android-developer/answer/10787469
- Google Play billing: https://support.google.com/googleplay/android-developer/answer/1072599
