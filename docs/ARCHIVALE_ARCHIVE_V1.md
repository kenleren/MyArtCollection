# Archivale Archive v1

Archivale archive v1 is the portable, local collection export owned by issue
#178. It is a ZIP file created in app-private storage and exposed only after the
collector chooses Open, Save a copy, or Share. It is not a backup or restore
format, and it is not encrypted.

## Root manifest

`manifest.json` is canonical UTF-8 JSON with no trailing newline. Object keys
appear in this exact order and have these exact types:

```text
contract:string, version:integer, created_at:string,
archive_status:string, trust_notice:string, counts:object,
warnings:list<string>, files:list<object>, exclusions:list<string>
```

`contract` is `ARCHIVALE_ARCHIVE_V1`; `version` is `1`; `created_at` is the
canonical UTC ISO-8601 instant emitted by Dart `toIso8601String`;
`archive_status` is `complete` or `with_warnings`. `counts` has exactly
`artworks`, `external_references`, `attachments_included`, and
`attachments_excluded`, in that order, as non-negative integers. Warning codes
are sorted and unique. Each `files` row has exactly `path`, `size_bytes`, and
`checksum_sha256`, in that order. The exclusions list is exactly:

```text
generated_reports_and_exports, ai_and_research_job_caches, telemetry,
billing_state, credentials_and_device_paths
```

Paths are unique canonical POSIX paths. They never contain device paths,
picker URIs, app-private storage keys, or collector filenames. The frozen
golden root is `test/fixtures/archive_v1/manifest.golden.json`.

## Artwork record schema

`records/artworks.json` is a canonical object with keys `contract`, `version`,
and `artworks`, in that order. `contract` is
`ARCHIVALE_ARTWORK_RECORDS_V1`; `version` is `1`; artwork rows are sorted by
opaque artwork ID. Every artwork row has exactly these keys in this order:

```text
artwork_id:string, record_state:string, lifecycle_status:string,
primary_image_attachment_id:string|null, created_at:string,
updated_at:string, fields:list<object>
```

Every field row is sorted by `field_key` and has exactly:

```text
field_key:string, value:string, source:string, source_note:string,
last_confirmed_at:string|null, money_amount:string|null,
money_currency_code:string|null
```

The allowed record states, artwork lifecycle values, and source labels are the
corresponding v1 app enums. Unknown values, duplicate IDs/field keys, non-UTC
timestamps, unknown keys, reordered keys, or non-canonical bytes are rejected.
The frozen artwork golden is
`test/fixtures/archive_v1/artworks.golden.json`.

## ZIP contents

- `manifest.json`
- `records/artworks.json`: every local artwork and field, including its source
  label and lifecycle state. User-confirmed values are not conflated with AI
  suggestions or document-extracted values.
- `records/external_references.json`: the canonical
  `EXTERNAL_REFERENCE_EXPORT_CONTRACT_V1` envelope.
- `records/attachments.json`: the frozen
  `supporting_record_attachment_export_contract_v1` subsection from
  `docs/SUPPORTING_RECORD_ATTACHMENT_EXPORT_CONTRACT_V1.md`.
- `attachments/<opaque-id>/payload.<approved-extension>`: verified original
  bytes for entries whose attachment status is `included`.

Generated reports/exports, AI and research job caches, telemetry, billing
state, credentials, local paths, and app-generated image derivatives are
excluded. Missing, unreadable, removed, superseded, unavailable, or
checksum-mismatched original attachments remain truthfully represented by their
contract-defined exclusion metadata; an archive never claims that every
original is present.

## Collector report PDF v1

The per-artwork report contains only user-confirmed fields, their source label,
report date, artwork lifecycle and record state, an index of supporting records,
and verified JPEG/PNG artwork or supporting images within a bounded size. It
states that supporting records do not prove authenticity, attribution,
provenance, ownership, value, appraisal status, legal status, or insurance
acceptance. AI-suggested and unconfirmed document-extracted field values are
omitted.

## Integrity and recovery

Both outputs use a temporary app-private file and atomic completion. Cancelled
or failed work deletes the temporary file. Archive payloads are checksum-checked
before composition, immediately before they are added, and immediately after
the streaming add. A collection
change during generation fails closed and asks the collector to retry. Completed
artifacts remain app-private and can be reopened after a dismissed native
destination flow.

The v1 decoder rejects corrupt ZIP data, duplicate or unlisted entries,
non-canonical paths/JSON, unknown or reordered fields, mismatched sizes or
checksums, invalid child-to-artwork links, and count mismatches. The golden,
round-trip, large-collection, corruption, TOCTOU, mid-flight cancellation, and
atomic-failure tests are in `test/real_export_service_test.dart`.

On Android, Save a copy uses the system `ACTION_CREATE_DOCUMENT` flow and
writes only to its returned URI. On iOS, it uses a document picker export copy.
Both native bridges accept only existing files under the app-private
`generated_exports` root and only PDF/ZIP MIME types. Deterministic bridge and
policy tests prove request, byte-copy, dismissal, and failure semantics; they
are not physical Pixel or iPhone evidence.

Any incompatible root, manifest, path, or PDF semantics change requires a
versioned successor. The #179 attachment subsection cannot be changed by this
contract. Issue #180 may consume archive v1 unchanged inside a future encrypted
backup envelope.
