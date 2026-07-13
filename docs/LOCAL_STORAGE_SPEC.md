# Local Storage Spec

This document is the canonical storage and attachment spec for the prototype. It defines the local persistence model, file handling rules, and the prototype limits that the app must respect before the later backup and crypto work is designed.

## Scope

- Local-first prototype storage only.
- SQLite-backed structured data.
- App-private attachment and export storage.
- Prototype file type and size limits.
- Schema versioning and migration assumptions for the prototype.

Out of scope here:

- Google Drive backup implementation.
- Encryption design and key management.
- Restore UX and conflict resolution mechanics.
- Production migration guarantees.
- Redteam gates beyond the documentation follow-ups listed below.

## Canonical Data Model

The prototype should treat the following as the local entities that matter for storage design:

- `artworks`
- `attachments`
- `ai_jobs`
- `reports`
- `sync_state`
- `export_jobs`

The first-artwork prototype may have only one record, but the model must be shaped so it can grow to a small collection without changing the basic storage rules. Opaque identifiers and per-entity metadata keep the design stable as the MVP expands.

### `artworks`

Artwork rows store the user-facing record and the minimal fields needed to find related data.

Suggested fields:

- opaque `artwork_id`
- `created_at`
- `updated_at`
- `record_state`
- `lifecycle_status` for active, sold, lost, stolen, or removed holdings
- core descriptive fields used by the schema
- attachment counts or summary flags that help list views

### `attachments`

Attachments represent all file-backed evidence tied to an artwork.

Suggested fields:

- opaque `attachment_id`
- opaque `artwork_id`
- attachment kind or subtype
- attachment role: primary artwork photo, supporting photo, or supporting document
- optional `derived_from_attachment_id` for edited photo derivatives that keep the original capture intact
- optional `transform_summary` describing the local crop/rotate/straighten steps that produced a derivative
- original file name
- MIME type
- byte size
- checksum
- created/imported timestamps
- source state
- local storage key or relative path
- extracted text or extraction summary when present
- warning flags for over-limit or generated content
- attachment lifecycle: `active`, `unavailable`, `superseded`, or `removed`
- optional lifecycle timestamp and `superseded_by_attachment_id`

### `ai_jobs`

AI jobs record user-triggered drafting or extraction requests.

Suggested fields:

- opaque `ai_job_id`
- opaque `artwork_id`
- requested operation
- input references
- output references
- request state
- timestamps
- provenance notes

### `reports`

Reports cover generated PDFs and other reviewable outputs.

Suggested fields:

- opaque `report_id`
- opaque `artwork_id` or collection scope
- report type
- output format
- size metadata
- checksum
- generation state
- timestamps

### `sync_state`

Sync state tracks local knowledge about backup or restore progress without assuming that backup exists yet.

Suggested fields:

- sync version
- last successful sync marker
- last error summary
- pending conflict marker
- remote manifest reference when backup is enabled later

### `export_jobs`

Export jobs record explicit user exports such as ZIP archives or PDF bundles.

Suggested fields:

- opaque `export_job_id`
- export format
- output size metadata
- checksum
- destination hint
- created_at
- completed_at
- warning flags

## Storage Locations

All binary content should live in app-private storage, not in public gallery or shared folders.

Recommended logical layout:

- artwork records: SQLite
- attachment bytes: app-private file store
- generated reports: app-private file store
- export archives: app-private file store until the user explicitly shares or saves them

Logical path pattern:

- `artworks/<artwork_id>/attachments/<attachment_id>/<original or generated file>`
- `artworks/<artwork_id>/reports/<report_id>/<output file>`
- `exports/<export_job_id>/<output file>`

The actual on-device path can differ by platform. The important rule is that the app owns the location and the files are not placed in a public user-facing library by default.

On Android, `getApplicationDocumentsDirectory()` resolves through
`Context.getDir("flutter", MODE_PRIVATE)`. The native attachment viewer and its
non-exported `FileProvider` must therefore authorize only
`<application documents>/attachments/artworks/`; `filesDir`, a public storage
root, and a broader app-private root are not equivalent substitutes.

## Attachment Classes And Limits

The prototype must accept the following imported attachment types:

- `image/jpeg` up to 25 MB each
- `image/png` up to 25 MB each
- `image/heic` up to 25 MB each
- `image/heif` up to 25 MB each
- `application/pdf` up to 50 MB each

Rules:

- Size limits apply per file, not per artwork.
- The app should reject over-limit imports with a clear user-facing reason.
- The app should preserve the original file class when possible instead of silently converting it into a different user import.
- Image attachments retain their image subtype while `attachment_role`
  distinguishes the primary artwork photo from supporting reference photos.
- Edited photos must be stored as new attachment rows with lineage metadata
  back to the original capture; do not overwrite the original attachment row or
  reuse its file path for the edited derivative.
- The attachment write path must reject derivative rows when the source
  attachment is missing or belongs to a different `artwork_id`.
- A file that arrives with an unrecognized MIME type should be rejected for the prototype unless a later spec explicitly widens support.
- The importer must check MIME, filename extension, and an allowed file
  signature plus bounded structural checks before committing bytes. PDFs require
  a `%PDF-` header, a valid `startxref` value, and a `%%EOF` trailer; JPEG and
  PNG require bounded complete marker/chunk structure; HEIC and HEIF require a
  complete ISO base-media `ftyp` box with an approved brand. Header-only,
  truncated, malformed, and MIME-mismatched files are rejected.
- Import writes stage-copy, validate, checksum, reopen, then returns metadata
  for the database commit. Failed writes clean staging and uncommitted bytes.

## Attachment Lifecycle

Attachments default to `active`. A file that cannot be reopened or whose
checksum no longer matches is `unavailable`; its metadata remains so the
collector can replace it. Replacing an attachment makes the prior record
`superseded`; removing one makes it `removed`. Both are soft-removal states in
this prototype: metadata and app-private bytes remain until a future explicit
purge/data-erasure task.

Only `active` and `unavailable` rows appear in the active UI. `superseded` and
`removed` rows are excluded from active UI, archive payloads, and future backup
inputs. Archive handling follows
[Supporting Record Attachment Export Contract v1](SUPPORTING_RECORD_ATTACHMENT_EXPORT_CONTRACT_V1.md)
and must never use local paths or claim attachment completeness.

Generated PDFs and ZIP exports are not user imports.

Rules for generated outputs:

- Track them as app outputs in `reports` or `export_jobs`.
- Store size metadata and checksum.
- Surface a warning if the output exceeds the prototype import limit, because that affects sharing and restore expectations even though the file was generated by the app.
- Do not classify them as imported attachments.

## Opaque IDs And Checksums

All local entities should use opaque identifiers that do not leak artwork meaning, ownership, or collection structure.

Recommended ID rules:

- Use non-guessable opaque IDs.
- IDs should be stable enough to survive rename and reordering operations.
- Do not encode artist, title, or storage location in the ID.

Checksum rules:

- Store a checksum for every file-backed local entity.
- Use the checksum for integrity checks, duplicate detection, and restore validation.
- Keep the checksum separate from the display name and separate from the storage path.

## Schema Versioning And Migrations

Prototype storage must be versioned from the start.

Required assumptions:

- SQLite schema version is recorded.
- Migration steps are explicit and ordered.
- The prototype should tolerate additive schema changes.
- Existing records should default additive lifecycle/status columns to safe
  current-state values such as `active`.
- Legacy attachment rows without `attachment_role` must be backfilled so the
  row referenced by `artworks.primary_image_attachment_id` is
  `primary_artwork_photo`, other `photo` rows are `supporting_photo`, and
  non-photo rows are `supporting_document`.
- Derivative provenance columns are additive: existing rows should remain
  readable, and new edited-photo rows may populate
  `derived_from_attachment_id` and `transform_summary` without rewriting
  original captures.
- Downgrades and production-grade migration guarantees are out of scope for this issue.

Testing assumptions for later implementation:

- Repository or DAO tests must cover the local entity contract.
- Migration smoke tests must cover at least the prototype-to-next-version path.
- Attachment import tests must cover file type and size limits.
- Generated-output tests must cover size metadata and output classification.

## Sensitive Local Storage Assumptions

This section states the security assumptions that the prototype docs must not forget.

- The device is the primary source of truth.
- Local data is app-private by default, but app-private storage is not the same thing as encryption.
- The prototype should not assume that local files are invisible to device owners, backups, or forensic tools.
- Do not rely on public gallery or shared document folders for private collection data.
- Do not use filenames or paths that expose artwork titles, artist names, or acquisition details.
- Treat notes, location, purchase details, and supporting documents as sensitive.
- Do not claim that local data is encrypted unless a separate crypto design task says so.
- Do not claim that restore or backup is already solved in the prototype.

## Relationship To Other Docs

- [Architecture Plan](ARCHITECTURE.md) describes the high-level storage direction.
- [Artwork Record Schema](ARTWORK_RECORD_SCHEMA.md) defines the user-facing record model and attachment semantics.
- This document defines the local storage and attachment rules that those docs rely on.

## Open Follow-Up Candidates

These are explicit follow-up issues, not hidden sub-scope.

1. Encryption design and key management.
   - Define the at-rest crypto envelope for local files and sensitive SQLite content.
   - Decide whether device-bound keys, user passphrases, or both are needed.

2. Backup and restore design.
   - Define the backup manifest, restore flow, and conflict behavior.
   - Decide how export archives and backup payloads stay distinct.

3. Redteam gate for local storage.
   - Review local data handling for privacy, leakage, and recovery risks.
   - Confirm that file names, logs, and exports do not expose sensitive metadata.

4. Attachment restore and migration hardening.
   - Add regression coverage for attachment import, checksum validation, and schema migrations.
   - Verify that prototype migration behavior remains additive and bounded.
