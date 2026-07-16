# Archivale Archive v1

Archivale archive v1 is the portable, local collection export owned by issue
#178. The sole archive entry point is Settings; artwork and report screens do
not offer collection export. The screen states before generation that the ZIP
contains every local artwork record and every available original supporting
file. It is created in app-private storage and exposed only after a separate,
just-in-time confirmation for Open, Save a copy, or Share. It is not a backup
or restore format, and it is not encrypted.

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

Both outputs use randomized temporary app-private files and an exclusive
single-winner commit. Cancelled, failed, or losing concurrent work deletes only
its own temporary files. Archive payloads are read from one opened input stream;
every ZIP encoder pass hashes the exact bytes it consumes and must match the
indexed size and checksum. The completed ZIP is then streamed back through the
v1 decoder, and its exact entry set, sizes, and checksums are validated before
commit. Bounded report images are likewise sized and hashed from the exact byte
buffer consumed by the PDF generator. Same-inode rewrite/restore races and
path replacement fail closed. A collection change during generation asks the
collector to retry.

A completed payload becomes destination-eligible only beside a strict metadata
record with these exact ordered fields:

```text
metadata_version, state, artifact_id, kind, subject_id, file_name, mime_type,
byte_size, checksum_sha256, created_at, warnings
```

`metadata_version` is `1` and `state` is `complete`. Identity, kind, artwork
scope for reports, normalized app-private geometry, filename, MIME type, size,
SHA-256 checksum, canonical UTC timestamp, and warning types must all match.
Legacy, partial, arbitrary, symlinked, malformed, or mutated files are never
surfaced. Destination APIs accept only this store-issued capability and repeat
the exact named-path, metadata, size, and checksum validation immediately
before dispatch. Completed artifacts remain app-private and available after a
dismissed destination flow.

The v1 decoder rejects corrupt ZIP data, duplicate or unlisted entries,
non-canonical paths/JSON, unknown or reordered fields, mismatched sizes or
checksums, invalid child-to-artwork links, and count mismatches. The golden,
round-trip, large-collection, corruption, TOCTOU, mid-flight cancellation, and
atomic-failure tests are in `test/real_export_service_test.dart`.

On Android, Save a copy traverses from a held app-documents descriptor and opens
every export parent, payload, and sidecar descriptor-relative with no-follow
semantics before launching the system `ACTION_CREATE_DOCUMENT` flow. Named and
opened inode identity, regular-file type, and single-link custody must match.
Strict native policy derives the name and MIME type from semantically validated
metadata, retains the payload descriptor across the picker, and closes it on
every terminal success, failure, cancellation, null-destination, and teardown
path. It revalidates and hashes that same descriptor while copying to the
returned URI. A changed source fails closed and the bridge attempts to remove
or truncate the provider destination.

On iOS, the shared native policy applies the same descriptor-relative parent,
payload, sidecar, inode, and single-link checks. It validates the same semantic
metadata contract and copies the held payload descriptor through held temporary
root and call-local directory descriptors into an exclusive `0600` file. The
document picker receives only that verified copy; descriptor-relative cleanup
removes it on completion, cancellation, failure, or object teardown without
following replacement ancestry.

Deterministic bridge/policy tests cover metadata, semantic UTC timestamps,
geometry, static and repeated intermediate/leaf symlink and swap races,
hard-links, checksums, same-inode mutation, path replacement, concurrent
collision, byte-copy, exact-once descriptor closure, dismissal, and failure
semantics. iPhone Simulator XCTest covers the iOS policy. Physical Pixel
evidence is deferred to issue #228 and is not claimed as passed; physical iPhone
destination interaction also remains unverified.

Any incompatible root, manifest, path, or PDF semantics change requires a
versioned successor. The #179 attachment subsection cannot be changed by this
contract. Issue #180 may consume archive v1 unchanged inside a future encrypted
backup envelope.
