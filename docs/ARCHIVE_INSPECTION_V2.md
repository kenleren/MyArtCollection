# Read-only V2 archive inspection

This is the first local prerequisite for issue #180 backup/recovery. It does
not restore, replace, decrypt or upload a collection. It does not change the
V1/V2 export codecs, wire formats, attachment inclusion rules or UI. In
particular, successful inspection is neither authentication of the sender nor
proof of authenticity, ownership or a complete backup.

## API and source binding

`ArchiveInspectionReader.inspect` accepts a file and caller-owned app-private,
backup-excluded scratch directory. It creates one private temporary snapshot,
validates a restricted ZIP profile, streams entry hashes, preflights JSON
allocation, and invokes existing component validators. It compares snapshot
and source byte hashes/lengths and source modification/change timestamps before
returning. Source symlinks are rejected. Changes observed during inspection
fail closed. All owned handles and temporary copies are cleaned on completion,
failure and cancellation; unrelated files are never selected for cleanup.

The immutable result contains a source fingerprint and typed metadata, not a
trusted filesystem path, payload bytes or an activation capability. Later use
of the original path requires a new inspection. This does not promise to
detect an adversarial same-content rename/rewrite that leaves no observable
state change; its binding is to the exact copied and verified bytes. The caller
must protect its private scratch directory. No live database is opened.

Inspection accepts single-disk, contiguous ordinary ZIP entries using stored
or deflate compression, with matching central/local declarations and exact
canonical V2 entry names/order. Encryption, ZIP64, data descriptors, extra
fields, per-entry comments and other ZIP features not emitted by the bounded
current exporter are unsupported. Directories, symlinks, duplicate/overlapping
entries, traversal, undeclared payloads and mismatched checksums/counts fail.
ZIP container comments are bounded by their uint16 length. Payload inspection
checks bytes and metadata consistency; it does not decode images/PDFs or
certify their safety for a future renderer.

## Fixed inspection ceilings

| Resource | Limit |
| --- | --- |
| Input / cumulative expanded bytes | 128 MiB / 512 MiB |
| Single payload | 64 MiB |
| Manifest / other structured entry / total structured bytes | 1 MiB / 8 MiB / 16 MiB |
| ZIP entries / UTF-8 path / path components | 2,048 / 256 bytes / 4 |
| JSON nesting / decoded UTF-8 string / values per section | 16 / 64 KiB / 300,000 |
| Artworks / attachment rows / external references | 4,096 / 2,048 / 16,384 |
| Groups / memberships / preferences | 1,024 / 32,768 / 4,096 |
| Artwork field rows across artwork section | 65,536 |
| File copy / compressed input buffer | 64 KiB |
| Deflate blocks per entry / code length entries | 65,536 / 318 |

Headers are checked before allocating variable data. Inflation is consumed in
native output chunks and rejected before accumulation if actual output exceeds
the bounded declaration. JSON preflight checks depth, strings, duplicate keys,
row counts and total values before constructing the object graph; it yields
periodically for cancellation. The normal decoder/component codecs then work
only on bounded metadata. Unknown or oversized inputs never return partial
success. These are conservative inspection ceilings, not a device-memory
benchmark or a promised public backup capacity.

## Strict compressed-stream completion

The locked `archive` 4.0.9 inflater exposes neither a strict completion result
nor consumed-input state: its block parser uses the same stop result for final
completion and several malformed/truncated cases. Dart `RawZLibFilter` likewise
does not expose that state. A preserved minimal regression is raw bytes `03`: the
native decoder accepts empty output, although the final fixed-Huffman end marker
is truncated (`03 00` is complete). The reader test also removes the final
compressed byte from a real export and repairs ZIP offsets/sizes; decoded bytes
and checksums alone previously accepted it.

A separate [RFC 1951](https://www.rfc-editor.org/rfc/rfc1951.html) structural pass
therefore verifies stored, fixed-Huffman and dynamic-Huffman blocks before
native inflation. It retains no decoded content or sliding output window. It
counts expanded bytes, verifies distance history, code-table completeness, final
end markers and exact compressed-byte consumption. Unused final-byte padding
is allowed; trailing bytes/streams, reserved codes and malformed tables fail.
The pass uses one 64 KiB input buffer, at most 318 code lengths and sixteen bounded
Huffman maps; the number of blocks is capped above. It checks cancellation per
input buffer and yields every 4,096 data symbols or 256 blocks. Native inflation
remains responsible for producing bytes for CRC/SHA checks. This extra parser
needs independent correctness/security review; valid stored/fixed/dynamic and
seeded multiblock inputs are tested against the native decoder, alongside strict
truncation, invalid-code and history tests.

## Explicit fidelity and relationship coverage

Every inspected field is `present`, `presentNull` or
`notRepresentedByVersion`. Attachment rows are deliberately not reconstructed
with `AttachmentRecord` defaults. `archiveV2SchemaCoverage` inventories every
column of all twelve current SQLite schema-10 tables, with a schema test that
fails when a new table/column lacks an explicit policy.

V2 carries artwork values/source labels/confirmation timestamps, external
references, groups, memberships and preferences. Included original attachment
rows carry identity/type/role, file description/hash, import time and lifecycle.
They omit capture time, source state, notes, extraction/transform summaries,
lifecycle change time and supersession/derivation links. Excluded original
rows omit still more metadata. All derivative rows and all five persisted
AI/research history tables are absent. Their original counts are unknown,
not zero. Some of that history is displayed after restart, so it cannot simply
be assumed disposable when specifying a future backup.

Known child/group links and included payload links are validated. An existing
primary attachment with the wrong artwork/type/role is invalid. A primary ID
whose row is absent is unprovable because V2 filtered derivative rows; no row
is invented. Lineage and supersession links are likewise unprovable. Known
payload absence or lifecycle exclusion is separate from unknown field coverage.
`supportsCompleteRecovery` is always false for this inspector.

## Validation and follow-up boundary

Tests compare a rich synthetic source SQLite database directly with inspected
values and explicit missingness. Re-export round trips alone would hide data
already lost by V2. Hostile fixtures exercise header/expansion/allocation caps,
duplicate and malformed structures, relationships, source/snapshot mutations,
cancellation and cleanup. Existing export and attachment-contract tests remain
compatibility checks.

A richer versioned archive contract must address the omitted durable fields,
history rights/retention and removed/superseded payload policy before any full
recovery claim. V1/V2 cannot be silently upgraded by filling missing fields.
Activation remains a separate reviewed design: fixed-root migration, native
selected-root authority, durable pointer/journal ordering, retained-handle and
stale-operation fences, recovery precedence, and erasure control outside
replaceable generations. No generation staging, custody changes, V3 writer,
Google connection, encryption or new app flow is included here.
