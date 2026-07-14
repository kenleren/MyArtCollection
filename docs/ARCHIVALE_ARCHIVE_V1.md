# Archivale Archive v1

Archivale archive v1 is the portable, local collection export owned by issue
#178. It is a ZIP file created in app-private storage and exposed only after the
collector chooses Open, Save a copy, or Share. It is not a backup or restore
format, and it is not encrypted.

## Root manifest

`manifest.json` is UTF-8 JSON with `contract` set to
`ARCHIVALE_ARCHIVE_V1`, integer `version` `1`, an ISO-8601 UTC creation time,
`archive_status` (`complete` or `with_warnings`), a trust notice, counts,
warning codes, checksummed structured-file entries, and explicit exclusions.
Paths never contain device paths, picker URIs, app-private storage keys, or
collector filenames.

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
before composition and again immediately before they are added. A collection
change during generation fails closed and asks the collector to retry. Completed
artifacts remain app-private and can be reopened after a dismissed native
destination flow.

Any incompatible root, manifest, path, or PDF semantics change requires a
versioned successor. The #179 attachment subsection cannot be changed by this
contract. Issue #180 may consume archive v1 unchanged inside a future encrypted
backup envelope.
