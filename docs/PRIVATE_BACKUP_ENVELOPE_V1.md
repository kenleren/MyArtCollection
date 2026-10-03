# Private backup envelope and content V1

Issue #180. These codecs are a source-only foundation, not an available backup
or restore feature. They do not access Drive, stage files, open a database,
activate records or grant provider/billing authority. The app must not wire
them into a successful backup/restore screen until the accepted capture lease,
durable recovery journal, native custody and history-execution fences exist.

## Encrypted framing

`PrivateBackupEnvelope` uses cryptography 2.9.0 and cryptography_flutter 2.3.4,
PBKDF2-HMAC-SHA256 at exactly 600,000 iterations, and AES256-GCM with 16-byte
tags. Passphrases are exact strict UTF8, 12–1,024 bytes, without trimming or
normalization. They are never stored or uploaded. Temporary key/input buffers
are released where the library supports it; Dart strings and phone memory
cannot be promised securely erased.

The 48-byte header is:

| Offset | Size | Value |
| --- | --- | --- |
| 0 | 8 | ASCII `ARCBK001` |
| 8 | 4 | Big-endian iterations, exactly 600000 |
| 12 | 16 | Fresh secure random salt |
| 28 | 8 | Fresh secure random nonce prefix |
| 36 | 4 | Big-endian chunk size, exactly 1048576 |
| 40 | 8 | Big-endian total plaintext length, at most 512MiB |

Each frame is length u32, ciphertext of that exact length, and tag16. All data
frames except the last contain exactly 1MiB; the last is the exact positive
remainder. The mandatory final frame has length0, including for an empty
plaintext. Nonce = prefix8 || index u32. AAD = full header48 || index u32 ||
length u32 || marker u8 (data0, final1). Require exact total, final tag and EOF.
Reordering, duplicates, alteration, truncation and trailing data fail closed.
Ciphertext length is 48 + plaintext + 20 * (ceil(plaintext/1048576) + 1).

Read header/parameters/bounds before key derivation. Incoming stream chunks are
at most2MiB. Source-read inactivity is bounded to30 seconds; cancellation wakes
blocked source reads. Stream-subscription close is bounded to1 second and
failure is reported. Cancellation does not claim to stop an already running
crypto primitive. A crypto operation rechecks cancellation before yielding.

Decrypted chunks are provisional even when individually authenticated. Only an
already-owned private quarantine may receive them. No activation or native
publication may occur until the complete final/EOF and every content check
succeed and the controller revalidates its durable operation ownership.

## Content framing

`PrivateBackupContentCodec` V1 explicitly contains the immutable schema10
`archivale-record-component-v1` codec. It never labels schema11 as schema10;
future schema11 recovery requires a separately versioned content contract.

Plaintext = manifest-length u32 || manifest JSON || exact record bytes ||
manifest-ordered eligible payload bytes. Manifest≤512KiB, records≤16MiB,
attachments≤2048, each image≤25MiB/PDF≤50MiB, total≤512MiB. The strict bounded
JSON parser rejects duplicate keys; unexpected fields, inconsistent record
format/schema/digest/hash/length and inconsistent descriptors are rejected.

Manifest keys are `format` (`archivale-private-backup-content-v1`), opaque
UUID4 `snapshotId`, canonical UTC `snapshotAt`, `recordFormat`, `sourceSchema`,
`schemaDigest`, `recordLength`, `recordSha256`, `payloadPolicy`
(`eligible_active_only`), `omissions` (removed/unavailable/superseded counts)
and `payloads`. Each payload authenticates exact artwork/attachment IDs,
MIME, approved canonical target name, length and SHA256. IDs used for attachment
targets must match the existing native opaque-ID grammar. Input paths and
collector filenames never control a destination. JPEG targets use
`payload.jpg`; other supported MIME types use the existing canonical names.

Only active attachment bytes are included. Historical rows retain their exact
values while removed/unavailable/superseded bytes are omitted with counts.
An active descendant of a removed attachment rejects the snapshot; no usable
attachment with silently absent bytes is invented. Missing, changed, extra or
checksum-mismatched source bytes cannot seal successfully. MIME declarations
and hashes do not independently prove a file is semantically valid; the future
controller must retain existing payload-format validation before publication.

An inspector's stager must fully consume and verify each payload, use the same
cancellation/operation ownership before every write, and own its private stage
before invocation. Waiting for a stager is bounded; timing out invalidates the
shared cancellation token and reports failure. It does not erase or authorize
files. The controller retains recovery ownership until pending
writes stop and owned provisional cleanup is proved. `supportsActivation` is
always false. Historical AI/research jobs remain record data; these codecs
cannot schedule or authorize them.

## Evidence and remaining integration

Tests use only synthetic records/content/passphrases. The independent fixture
is produced with Python hashlib PBKDF2 and cryptography AESGCM using the exact
runtime work factor/framing, including the final tag. Runtime salt/nonce inputs
are always freshly secure-random; fixed fixture values are test-only.

The accepted implementation plan lives in the ignored beta-validation evidence.
Still required: schema11 operation and restored-job controls, capture/removal
fencing, durable PREPARING before plaintext staging, empty-target recovery,
finish-forward native publication, interruption/startup tests, encrypted-file
app controls, mobile acceptance and separately authorized Drive configuration.
No source-only codec result is evidence of physical-device recovery or cloud
backup availability.
