# Mobile Information Architecture

This document defines the MVP mobile information architecture for Archivale. It stays at the product and navigation level only: routes, object model, entry and exit points, record states, empty/error/offline behavior, and the open product decisions still under discussion.

## Design Principles

- Local-first by default.
- AI assists drafting, but the user confirms facts.
- No screen should imply authenticity, appraisal certainty, or market value.
- `Missing documents` is a completeness status, not a separate lifecycle that competes with the record state.
- The app should make the next useful action obvious at every stage.

## Route Tree

- `/splash`
- `/onboarding`
  - `/onboarding/privacy`
  - `/onboarding/first-add`
- `/collection`
  - `/collection/add`
  - `/collection/incomplete`
  - `/collection/report`
  - `/collection/settings`
- `/artwork/:artworkId`
  - `/artwork/:artworkId/draft`
  - `/artwork/:artworkId/details`
  - `/artwork/:artworkId/documents`
  - `/artwork/:artworkId/report-preview`
  - `/artwork/:artworkId/export`
- `/capture`
- `/import`
- `/settings`
  - `/settings/privacy`
  - `/settings/storage`
  - `/settings/export`
  - `/settings/backup`

## Navigation Model

- Primary navigation is a bottom tab bar or equivalent persistent switcher for:
  - Collection
  - Incomplete
  - Reports
  - Settings
- The artwork detail stack is a drill-in flow from collection or incomplete queues.
- Capture and import are modal entry points launched from Add artwork and from empty states.
- Report preview and export are reachable from both the collection summary and an individual artwork record.

## Screen And Object Model

### Collection Home

Purpose:

- Show the user’s artworks as a scan-friendly list or grid.
- Surface the main next actions: add artwork, review incomplete records, generate report, export archive.

Objects shown:

- Artwork card or row
- Record state badge
- Document completeness badge
- Last updated timestamp

Entry points:

- App launch after first run
- Bottom navigation
- Return from artwork detail
- Return from report or export confirmation

Exit points:

- Add artwork
- Open artwork detail
- Open incomplete queue
- Open report preview
- Open settings

### Add Artwork

Purpose:

- Start a new record from photo capture or import.

Primary actions:

- Take photo
- Import photo
- Attach document
- Cancel

Exit points:

- Capture flow
- Import flow
- Draft review

### Capture

Purpose:

- Acquire the primary artwork image.

Entry points:

- Add artwork
- Retry from failed capture

Exit points:

- AI draft
- Save as draft if offline or AI unavailable

### AI Draft Review

Purpose:

- Present AI-suggested fields beside empty, user-entered, or confirmed values.

Primary actions:

- Confirm field
- Edit field
- Reject suggestion
- Save draft
- Continue to documents

Exit points:

- Artwork details
- Document attachment
- Incomplete queue

### Artwork Details

Purpose:

- Serve as the canonical record view for one artwork.

Shown objects:

- Core metadata
- Notes
- Current location
- Insurance value labeled as user-provided
- Record state
- Document list
- Completeness status

Primary actions:

- Edit details
- Attach document
- Generate report preview
- Export record package
- Mark complete by confirmation flow

Exit points:

- Documents
- Report preview
- Export
- Back to collection

### Document Attachment

Purpose:

- Attach supporting documents such as receipts, certificates, appraisals, and provenance notes.

Primary actions:

- Add document
- Scan or import document
- Mark document type
- Remove attachment

Exit points:

- Artwork details
- Incomplete queue

### Incomplete Queue

Purpose:

- Collect records that need attention.

Entry criteria:

- Drafts
- Needs review
- Missing documents
- Failed exports or incomplete reports

Primary actions:

- Open record
- Resolve missing fields
- Attach document
- Retry failed operation

Exit points:

- Artwork details
- Draft review
- Report preview

### Report Preview

Purpose:

- Show what will be included in an insurance-ready PDF before export.

Shown objects:

- Confirmed fields
- User-provided values
- Attached documents list
- Report date
- Inclusion/exclusion note

Primary actions:

- Review contents
- Regenerate
- Export PDF
- Export ZIP archive

Exit points:

- Artwork details
- Export confirmation

### Settings

Purpose:

- Manage privacy, storage, backup, and export.

Primary actions:

- View privacy rules
- Connect or disconnect backup
- Delete local data
- Export archive

Exit points:

- Privacy
- Storage
- Backup
- Export

## First-Run Flow

1. Launch to onboarding.
2. Show privacy and storage explanation early.
3. Present the first-add path directly from onboarding.
4. User adds a photo.
5. App creates an AI draft from the photo.
6. User confirms or edits the draft.
7. User attaches at least one supporting document.
8. App shows document completeness and record state.
9. User opens report preview.
10. User exports the report or archive preview.

The first-run path must support this full sequence without requiring the user to discover settings first:

- add photo -> AI draft -> confirm/edit -> attach document -> report/export preview

## Returning-User Flow

1. Launch to collection or the last active tab.
2. Show incomplete queue badges if any records need attention.
3. Allow fast resume into a record, a draft, or a report preview.
4. Support direct add artwork from collection home.
5. Support direct export from settings, collection, and report preview.

## Record State Model

The record has one primary state and one completeness overlay.

### Primary record states

- Draft
  - New record started but not yet confirmed.
- Needs review
  - AI draft exists and user confirmation is still required for one or more important fields.
- Verified by you
  - The user has confirmed the record’s core fields.

### Completeness overlay

- Missing documents
  - The record lacks one or more supporting documents.
  - This can exist alongside Draft, Needs review, or Verified by you.

### State transitions

- Draft -> Needs review when AI draft data is available.
- Needs review -> Verified by you when the user confirms the core fields.
- Any state -> Missing documents overlay when required support files are absent.
- Verified by you -> Missing documents resolved when at least one relevant supporting document is attached and the completeness rule is satisfied.

## Empty, Error, And Offline States

### Empty states

- No artworks yet
  - Show Add artwork as the primary action.
  - Show a short preview of the finished record/report value.
- No documents attached yet
  - Explain that documents strengthen insurance and provenance records.
- No report yet
  - Show the report preview action and explain what it will include.
- No incomplete records
  - Confirm the collection is currently up to date.

### Error states

- Capture failed
  - Offer retry and import instead.
- AI draft unavailable
  - Save as draft and continue manual editing.
- Upload or import failed
  - Keep the current record and allow retry.
- Export failed
  - Surface the failed export in the incomplete queue with retry.

### Offline states

- Capture, draft editing, document attachment, and local report prep continue offline.
- AI suggestions, backup, and cloud restore are unavailable offline.
- The UI should make offline status visible without blocking local work.

## Entry And Exit Points

### Entry points

- App launch
- Add artwork
- Resume incomplete record
- Open artwork from search or list
- Open report preview
- Open settings

### Exit points

- Back to collection
- Back to incomplete queue
- Export complete
- Save draft and close
- Discard draft

## Open Product Decisions

- Should the free limit gate at the fifth artwork or at first report/export attempt? Recommendation: gate on the free limit, but keep the first report/export preview visible so the user sees the payoff before purchase.
- Should backup setup happen during onboarding or after the first verified artwork? Recommendation: after first verified artwork, with a clear shortcut from onboarding for users who want it sooner.
- Should insurance value remain strictly user-entered in MVP? Recommendation: yes.
- Should the incomplete queue be a tab or a filtered view inside collection? Recommendation: a tab if the tab bar can stay within four items; otherwise a filtered view with a badge.
- Should report preview live per artwork, at collection level, or both? Recommendation: both, with collection-level export aggregating all verified records.
- Should `Missing documents` count as a visible queue item even when the core record is verified? Recommendation: yes, because completeness is part of the product promise.

## Traceability Notes

- This IA follows the local-first architecture and optional backup model in [Architecture Plan](ARCHITECTURE.md).
- It uses the trust and language constraints from [Copy and Trust Rules](COPY_TRUST_SPEC.md).
- It preserves the product promise from [Product Plan](PRODUCT_PLAN.md): fast AI-assisted intake, user confirmation, document-backed records, and exportable reports.
