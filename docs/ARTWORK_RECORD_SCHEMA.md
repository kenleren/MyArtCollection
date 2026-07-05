# Artwork Record Schema

This document defines the MVP artwork record model, attachment model, provenance labels, validation rules, and export/report mappings for Archivale.

## Scope And Rules

- This is a documentation-only schema spec.
- AI assists drafting; the user confirms facts.
- User-confirmed facts outrank AI-suggested or document-extracted values when they conflict.
- The schema must not imply authenticity determination, appraisal-grade valuation, or market-value claims.
- Provenance and supporting documents are records and evidence sources, not proof of authenticity.
- See [Local Storage Spec](LOCAL_STORAGE_SPEC.md) for the canonical local file, attachment, and import-size rules.

## Core Entities

### Artwork

An artwork record represents one collectible item and its associated metadata, documents, and export-ready report data.

Required fields:

- `artwork_id`
- `record_state`
- `lifecycle_status`
- `title`
- `artist`
- `primary_image`
- `created_at`
- `updated_at`

Optional fields:

- `year`
- `medium`
- `dimensions`
- `edition`
- `signature_notes`
- `subject_matter`
- `style_or_period_hint`
- `condition_notes`
- `frame_notes`
- `glass_notes`
- `mounting_notes`
- `purchase_price`
- `purchase_date`
- `seller_or_gallery`
- `current_location`
- `insurance_value`
- `notes`
- `provenance_summary`
- `source_summary`
- `reviewed_at`

### Artwork Field Value Model

Each user-visible field stores:

- `value`
- `source_state`
- `source_note`
- `last_confirmed_at`

Permitted `source_state` values:

- `AI-suggested`
- `user-confirmed`
- `document-extracted`
- `unknown`

Justified alternatives may be added later only if they map cleanly to the same trust model and do not weaken the user-confirmed override rule.

Rules:

- `user-confirmed` is the authoritative state for a field.
- `AI-suggested` is a draft and must remain visually distinct from confirmed data.
- `document-extracted` means the value came from a receipt, certificate, appraisal, auction record, or provenance note.
- `unknown` means the system could not determine a value and should ask the user to confirm or enter it.
- If a document and AI suggestion conflict, the UI should prefer the user review path, not automatic overwrite.

### Attachments

Each artwork can have zero or more attachments.

Attachment types:

- `photo`
- `receipt`
- `certificate`
- `appraisal`
- `auction_record`
- `provenance_note`
- `other_supporting_document`

Attachment metadata:

- `attachment_id`
- `artwork_id`
- `attachment_type`
- `attachment_role`
- `derived_from_attachment_id` for edited photo derivatives that preserve the original capture
- `transform_summary` for the local edit steps that produced the derivative
- `file_name`
- `mime_type`
- `file_size_bytes`
- `captured_at`
- `imported_at`
- `document_source_state`
- `extracted_text_available`
- `extraction_summary`
- `source_uri_or_local_path`
- `checksum`
- `notes`

Attachment source states:

- `AI-suggested`
- `user-confirmed`
- `document-extracted`
- `unknown`

Attachment rules:

- `attachment_type` preserves the media or document subtype.
- `attachment_role` determines whether the row is the `primary_artwork_photo`,
  a `supporting_photo`, or a `supporting_document`.
- A photo attachment may be the primary artwork image only when its role is
  `primary_artwork_photo` and its id is referenced by `primary_image_attachment_id`.
- Supporting photo rows keep `attachment_type: photo` and use
  `attachment_role: supporting_photo`.
- Edited photo derivatives are new photo attachments, not overwrites. They may
  store `derived_from_attachment_id` plus a short `transform_summary` so the
  app can show exactly which original capture they came from and what local
  edits were applied.
- Receipt, certificate, appraisal, auction record, and provenance note attachments use `attachment_role: supporting_document`.
- Legacy attachment rows without roles are compatible: the photo row referenced
  by `primary_image_attachment_id` is primary, other photo rows are supporting
  photos, and non-photo rows are supporting documents.
- The attachment label must not claim proof of authenticity.
- The app may extract text from a document, but extracted text is still reviewable and may be wrong.

## Completeness And Record States

### Lifecycle Status

Lifecycle status records what happened to the physical artwork. It is separate
from record completeness and provenance labels.

Permitted `lifecycle_status` values:

- `active`
- `sold`
- `lost`
- `stolen`
- `removed`

Status meaning:

- `active` means the artwork is treated as a current holding.
- `sold` means the artwork is retained in records but no longer owned.
- `lost` means the artwork is retained in records but cannot currently be found.
- `stolen` means the artwork is retained in records and marked stolen by the user.
- `removed` means the artwork is retained locally but removed from current holdings.

Rules:

- Existing or missing lifecycle values default to `active`.
- Lifecycle status must not be inferred from AI suggestions.
- Lifecycle status must not replace `record_state`; sold, lost, stolen, and
  removed records can still preserve their prior completeness state.
- User-facing remove/delete actions should be explicit and confirmed. The MVP
  uses `removed` as a soft-delete state and does not physically delete rows or
  attachments from this UI.

### Record States

- `Draft`
- `Needs review`
- `Verified by you`
- `Missing documents`

State meaning:

- `Draft` means the record exists but has unresolved fields or no confirmation.
- `Needs review` means at least one important field is still AI-suggested, document-extracted, or unknown.
- `Verified by you` means the user has confirmed the core identity and core descriptive fields.
- `Missing documents` is a completeness status, not a competing lifecycle state.

### Completeness Rules

Minimum completeness for `Needs review` to clear:

- At least one primary image exists.
- Title is present.
- Artist is present or explicitly marked unknown by the user.
- At least the core descriptive fields have a user-confirmed review path.

Minimum completeness for `Verified by you`:

- Primary image exists.
- Title, artist, medium, and dimensions are user-confirmed or explicitly unknown.
- Purchase or acquisition data is either entered or explicitly absent.
- Insurance value, if present, is marked as user-provided.
- Supporting documents are attached when available, or the record is flagged `Missing documents`.

Missing document logic:

- Mark `Missing documents` when the user expects supporting records but none are attached.
- Do not mark a record missing documents merely because no appraisal exists.
- Do not require a certificate of authenticity.

## Validation Rules

### Required Field Validation

- `artwork_id` must be unique.
- `record_state` must be one of the documented states.
- `lifecycle_status` must be one of the documented lifecycle statuses.
- `title` cannot be empty once the record reaches review.
- `artist` cannot be empty once the record reaches review, unless explicitly marked unknown.
- `primary_image` is required for the first usable artwork record.

### Field Validation

- `year` must be a four-digit year, a partial date, or `unknown`.
- `dimensions` must include a numeric measurement and unit when entered.
- `purchase_price` and `insurance_value` must be stored as money values with currency and source context.
- `purchase_date` must be a date or a clearly marked approximate/unknown value.
- `current_location` must be a human-readable location string, not a geolocation requirement.
- `notes` may be free text but should not be used to smuggle valuation claims.

### Trust Validation

- A field cannot be auto-promoted from `AI-suggested` to `user-confirmed`.
- A `document-extracted` field should show the source document type or reference.
- `unknown` is a valid and preferable value when the app cannot determine the field.
- The UI should never present a guess as certainty.

## Provenance And Source Labels

Provenance data should record source material without asserting authenticity.

Suggested provenance labels:

- `user memory`
- `receipt`
- `certificate`
- `appraisal`
- `auction record`
- `provenance note`
- `document extracted`
- `AI draft`
- `unknown`

Provenance rules:

- `provenance_summary` may describe a chain of custody or ownership history when the user provides it.
- If provenance is extracted from a document, label it `document extracted`.
- If provenance comes from memory or conversation, label it `user memory` until the user confirms it.
- Avoid wording that says a document proves an attribution or authenticates the work.

## Export And Insurance PDF Mapping

Export and report outputs must be derived from confirmed, reviewable record data.

### Included In Insurance PDF

- Artwork identifier
- Primary image reference
- Title
- Artist
- Year
- Medium
- Dimensions
- Edition
- Signature notes
- Condition notes
- Frame, glass, and mounting notes
- Purchase price and purchase date when provided
- Seller or gallery
- Current location
- Insurance value labeled as user-provided
- Attached supporting document list
- Provenance summary when provided
- Report generation date

### Included In Full Archive Export

- All artwork fields
- All attachment metadata
- All source states and source notes
- All user-confirmed values
- All document-extracted values
- Record state history when retained
- Export timestamp

### Excluded Or Carefully Labeled

- No export should imply authenticity certification.
- No export should present insurance value as an app-certified appraisal.
- No export should rename user-provided values as verified market value.
- Any AI-suggested field should be labeled as suggested unless the user has confirmed it.

### Mapping Notes

- PDF tables should visually separate confirmed values from suggestions and document extractions.
- Document lists should include type, date, and file label where available.
- Insurance PDFs should use plain labels such as `User-provided insurance value`.
- Export archives should preserve the original source state metadata so downstream tools can audit what was user-confirmed versus inferred.

## Data Lineage Expectations

- User-confirmed facts are the highest-trust source in the record.
- AI output is a drafting aid only.
- Document extraction supports review but does not supersede user confirmation.
- Unknown is an acceptable and documented state.

## Open Follow-Ups

- Define the exact serialization format for source state history in the database layer.
- Define attachment OCR and extraction confidence handling in a separate implementation spec.
- Define any future appraisal workflow as a separate product path so it does not leak into MVP wording.
