# Supporting Record Attachment Export Contract v1

This contract is the attachment subsection for Archivale archive v1. It is
owned by issue #179. Issue #178 owns the archive root, ZIP container, and root
manifest; issue #180 consumes archive v1 unchanged. This contract does not
define backup, restore, cloud transfer, encryption, or report generation.

## Contract Boundary

- This subsection describes only original, user-selected attachment payloads
  and their attachment-index metadata.
- The archive root/manifest may reference this subsection but must not change
  its field names, lifecycle values, payload paths, checksums, or inclusion
  rules.
- v1 becomes frozen when this committed artifact has independent task review
  and is merged to `main`. Any v1 change requires a versioned successor and a
  serialized #179/#178 plan review.

## Attachment Index

Every attachment index entry uses these fields:

```json
{
  "attachment_id": "opaque attachment id",
  "artwork_id": "opaque artwork id",
  "attachment_type": "receipt",
  "attachment_role": "supporting_document",
  "file_name": "original-file-name.pdf",
  "mime_type": "application/pdf",
  "file_size_bytes": 12345,
  "checksum_sha256": "lowercase hex sha-256",
  "imported_at": "2026-07-10T16:00:00.000Z",
  "lifecycle_status": "active",
  "archive_status": "included",
  "payload_path": "attachments/a1/payload.pdf"
}
```

`attachment_id` and `artwork_id` are opaque. `payload_path` is archive-relative
and opaque; it is not an app-private storage key. Never include device paths,
picker URIs, FileProvider URIs, staging paths, or other local locations.

`attachment_type` is one of `photo`, `receipt`, `certificate`, `appraisal`,
`auction_record`, `provenance_note`, or `other_supporting_document`.
`attachment_role` is one of `primary_artwork_photo`, `supporting_photo`, or
`supporting_document`.

## Lifecycle And Archive Status

The authoritative attachment lifecycle is:

- `active`: current attachment record. Its verified payload may be archived.
- `unavailable`: current record whose app-private payload is missing,
  unreadable, or checksum-mismatched. Its metadata remains recoverable.
- `superseded`: prior record retained after a replacement commits.
- `removed`: record retained after an explicit user remove action.

Replacement and removal are soft-removal operations for the prototype. They
retain metadata and app-private bytes until a separately specified purge or
data-erasure task. `superseded` and `removed` records are excluded from active
UI, archive payloads, and future backup inputs.

Archive statuses are exactly:

- `included`: an active payload was reopened and SHA-256 verified; include it
  exactly once at `payload_path`.
- `excluded_missing`: an active/unavailable payload is absent or unreadable.
- `excluded_checksum_mismatch`: an active/unavailable payload is readable but
  differs from `checksum_sha256`.
- `excluded_superseded`: a superseded record; retain only approved exclusion
  metadata, not its payload.
- `excluded_user_removed`: a removed record; retain only approved exclusion
  metadata, not its payload.

For every excluded entry, retain only `attachment_id`, `artwork_id`,
`attachment_type`, `attachment_role`, `lifecycle_status`, and `archive_status`.
Do not retain `file_name`, MIME, size, checksum, timestamps, notes, source
state, local paths, or payload bytes for excluded entries. Archives must never
claim that all attachment originals are present or complete.

## Inclusion Rules

- Include only `active` attachments whose payload can be reopened and whose
  SHA-256 matches the stored checksum.
- Use the selected original bytes without conversion or recompression.
- Preserve the original filename only as approved metadata for an included
  attachment; it does not determine an archive path.
- Exclude generated reports and exports, AI/research caches, telemetry,
  credentials, and all app-private paths.
- A supporting record is user-provided context. It does not prove authenticity,
  attribution, provenance, ownership, value, appraisal, or insurance approval.
