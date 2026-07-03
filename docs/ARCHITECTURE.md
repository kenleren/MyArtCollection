# Architecture Plan

## Recommendation

Build the MVP as a local-first Flutter app with optional Google Drive backup and a thin server-side AI broker.

Recommended stack:

- Client: Flutter
- Local structured data: SQLite
- Local attachments: app-private file store
- Backup/sync: blobs and manifest in Google Drive `appDataFolder`
- Export: explicit user-triggered ZIP and PDF export through system share/document pickers
- AI: opt-in server-mediated multimodal extraction, never direct vendor calls from the app

## Product Architecture Principles

- The app should work without an app account.
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

## App Store Implications

If charging for subscription or app features:

- Use Apple In-App Purchase on iOS.
- Use Google Play Billing on Android.

Avoid making Google Sign-In the primary account system for MVP. Make Google Drive an optional backup connection instead. This keeps the app simpler and avoids making Google identity a mandatory login surface.

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
