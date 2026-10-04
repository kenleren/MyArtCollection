# Schema10 history-only record component

This internal prerequisite for #180 captures an explicitly supplied SQLite
collection in memory, encodes its logical records, and decodes them into immutable
history-only records. It has no app entrypoint, database discovery, payload I/O,
plaintext file writer, network destination, encryption or restore operation.
It is **not a complete backup or app recovery**. Existing V1/V2 formats and
inspection behavior remain unchanged.

## Fidelity and inert history

The source-controlled descriptor in `lib/app/backup/backup_record_schema.dart`
accounts for 120 columns in 12 tables. Exactly 119 column values remain exact
TEXT, signed SQLite INTEGER or null. `attachments.relative_path` is deliberately
not portable: capture selects a fixed omission marker without fetching the
source path value. Every attachment receives the same reconstruct-later marker.
Recorded checksums and lengths are history, not verified payload evidence.

All job records survive, including their original pending/running/queued/completed
statuses, provider names, error text, consent summaries and child evidence.
`BackupHistoryRecord.executionDisposition` is always `history_only`; these DTOs
provide no model conversion, repository upsert, operation capability or retry
bridge. This proves only an inert codec boundary. Schema10 still lacks durable
restored-job provenance for future app activation.

Source strings are not trimmed or normalized. CSV amount `'100'` with null
currency, empty strings, provider-scoped `object_id`, and formatted comparable
amount/currency evidence retain their original values. Embedded JSON retains its
original text after validation. Group and reference invariants are validated,
not repaired. The v1 enum vocabulary is pinned locally and included in its schema
digest; future app enum additions do not silently extend this format.

Removed, unavailable and superseded attachment rows remain present. An active
derivative of a removed ancestor additionally receives
`removedAncestorPayloadPolicyUnresolved`. This is a diagnostic, not permission
to include or recover bytes. Payload coverage remains `not_evaluated`.

## Versioned wire contract

`BackupRecordCodec.encode/decode` consumes/returns bounded in-memory bytes. The
format is strict UTF-8 NDJSON with LF after every frame, including the last.
No BOM, blank/CR lines, duplicate JSON keys, trailing bytes or unknown fields.

1. Exact header: `kind:header`, `format:archivale-record-component-v1`,
   `sourceSchema:10`, pinned `schemaDigest`, `payloadCoverage:not_evaluated`,
   `devicePaths:reconstruct_later`, `historyExecution:inert`,
   `activation:unsupported`.
2. Exactly 12 table frames `{kind:table,table,rowCount}` in descriptor order:
   artworks, artwork_fields, artwork_groups, artwork_group_memberships,
   artwork_preferences, attachments, ai_draft_jobs, research_jobs,
   research_source_hits, candidate_attributions, comparable_value_signals,
   external_references. Each is followed by that many `{kind:row,values}` frames.
   Every declared column is present; missing is distinct from null.
3. Exact trailer `{kind:end,tableCount:12,rowCount,bodySha256}`. The digest covers
   every preceding byte including LF separators. It proves consistency, not
   authenticity, encryption or trust in historical claims.

TEXT is a JSON string or permitted null. INTEGER is
`{kind:sqlite_int64,decimal:"…"}`, a canonical signed decimal in the full native
int64 range; no floating-point/JSON-number conversion. Particular nonnegative
column domains still apply. The path cell is exactly
`{kind:device_path_not_portable}`. No payload or activation descriptor is valid.
This contract targets Flutter VM int64, not a double-backed web implementation.

Rows are strictly unique and ordered by primary-key tuples. String components
use unsigned UTF-8 byte ordering, matching SQLite BINARY; they do not use Dart
UTF-16 ordering or concatenated keys. Invalid UTF-8 and lone UTF-16 surrogates
are rejected before replacement encoding. UTC timestamps retain exact three-
or six-digit fractional spelling and require real calendar values (external
references retain their existing exact three-digit format).

The reader copies bounded input before its first await and returns no partial
result before checksum, counts, values and relationships pass. DTO maps/lists
are copied and immutable, cells are scalars, and no reusable file handle exists.

## Bounds and snapshot semantics

| Resource | Hard ceiling |
| --- | --- |
| Encoded bytes / captured raw text | 16 MiB each |
| Frame / row text / individual UTF-8 text | 512 KiB / 256 KiB / 64 KiB |
| Local IDs and field keys | 1 KiB |
| JSON depth / embedded container entries | 16 / 2,048 |
| Component JSON nodes including embedded trees | 300,000 |
| Total rows / SQLite batch | 131,072 / 128 |
| Artworks / fields / groups / memberships / preferences | 4,096 / 65,536 / 1,024 / 32,768 / 4,096 |
| Attachments / draft jobs / research jobs | 2,048 / 8,192 / 8,192 |
| Source hits / candidates / value signals / references | 16,384 each |
| Schema objects / names / DDL / total schema text | 128 / 256 B / 32 KiB / 256 KiB |
| Per-table PRAGMA columns, FK rows and index rows | 64 each |
| PRAGMA names / types / defaults / cumulative text | 256 B / 64 B / 1,024 B / 256 KiB |

Limits are simultaneous, reject rather than truncate, and are not advertised
phone capacity. The aggregate node budget counts every wire object/array node,
key and scalar plus the parsed nodes/keys of embedded JSON text. Both writer and
reader apply the same accounting; wire tags and framing are included. The
reader preflights frames and JSON allocation before decoding. A successful
writer result is accepted by this reader absent cancellation or mutation.

`BackupRecordSnapshot.capture(Database)` uses one actual supplied transaction
for schema validation, scalar type/length/count preflights and every row read.
Schema metadata is bounded before DDL/name/default projection; record text is
bounded in SQLite before transfer. Bounded TEXT is selected as bytes and strictly
decoded. There is no fallback unbounded read. Native SQLite execution is not
preemptible; cancellation is cooperative before/after SQL and through bounded
JSON/relationship/lineage checkpoints. The supplied sqflite transaction can
exclude concurrent writers (BEGIN IMMEDIATE in the tested FFI implementation).
It does not promise nonblocking capture. Tests prove committed WAL data is
visible, a competing writer cannot tear the snapshot, and a post-capture retry
appears in the next snapshot. No database/WAL/SHM file is copied.

Only exact schema10 semantic layouts are accepted: known fresh DDL and real
app-migrated layouts, ignoring physical column order. The sole evidenced
attachment-role default variation is absent fresh vs literal
`'supporting_document'` after old migrations. Existing values are never filled
or normalized. Known constraints/indexes/immutable-reference trigger are
required; extra or changed schema rejects. Explicit SQLite internal tables and
Android metadata are the only ignored platform objects. Capture never upgrades,
repairs or writes the supplied source.

Failures expose only fixed categories: invalidRecords, unsupportedSchema,
unsupportedResourceLimit, cancelled, sourceUnavailable. No raw SQL/source value
or exception text is returned. Caller-owned databases are never closed or
cleaned by the component. Tests alone own temporary synthetic databases.

## Validation and remaining work

Focused tests compare decoded values directly against actual SQLite rows for
all 119 portable columns, including fresh and real migrated v10. Migration tests
seed legacy attachments before real `openAt` upgrades. Actual CSV and injected
online-research/repository writers establish money/evidence/provider-history
fidelity. Tests cover wire attacks, bounds, Unicode/int64, graph corruption,
source schema variants, cancellation, immutability and concurrent transactions.

#180 still requires a destination/permission flow, encryption and lost-key
behavior, coherent payload capture/integrity and approved lifecycle policy,
durable inert-history activation design, native safe replacement/rollback/erasure,
conflict/disconnect/deletion UX, fresh-install restore and independent mobile,
privacy and readiness acceptance. This component chooses none of those policies
and changes no production app behavior.
