# Attachment Custody API v1

Issue #220 owns this frozen Android/iOS API. Issue #221 consumes it for v9
lifecycle, reconciliation, and whole-store coordination and must not change
the Dart bridge, native entry points, native geometry, or native build wiring.

## Boundary

`AttachmentCustodyBridge` exposes capability/self-test, publication,
publication status/recovery/rollback/cleanup, removal, scan, and erasure-control
operations.

- Destination operations accept only opaque operation, artwork, and attachment
  IDs plus an approved canonical payload name.
- `sourcePath` is a one-time import input. It is never persisted and never
  controls a destination, cleanup, scan, or removal path.
- Android anchors at `Context.getDir("flutter")`; iOS anchors at the app
  Documents directory. Native code opens canonical descendants
  descriptor-relatively and with no-follow behavior.
- `unsafeNode`, `unsupported`, `ioFailure`, `publicationConflict`,
  `publicationPartial`, `erasurePending`, `erasureConflict`, and
  `erasureUnsafe` are blocked
  work. Callers must not substitute Dart path traversal, deletion, or success.

## Publication Protocol

Each import has a caller-owned opaque `operationId`. Native staging is
deterministic and intent-associated:

- `attachments/.staging/publication-<operationId>.data`
- `attachments/.staging/publication-<operationId>.tmp`
- `attachments/.staging/publication-<operationId>.json`

The canonical JSON descriptor fixes v1, operation/artwork/attachment IDs,
canonical name, byte size, SHA-256, and the `staged` phase. Android publishes
each transition with runtime-probed
`renameat2(RENAME_NOREPLACE)` and Apple uses
`renameatx_np(RENAME_EXCL)`. The descriptor moves `.tmp` → `.json` →
`<attachment>/.publication.json`; the payload moves `.data` → the canonical
name. There is no overwrite, pathname, check-then-rename, copy/unlink, or
hard-link fallback.

Every rename, unlink, and directory prune performs anchored prevalidation,
the mutation, immediate result validation, all required directory fsyncs, and
a final anchored named-path validation before another mutation or success.
Publication copies and verifies staged bytes and fsyncs every new directory
entry and created ancestry level. Recovery accepts only the enumerated current
rename states and exact two-link legacy states, then re-verifies descriptor
bytes, payload size/SHA-256, inode bindings, and final single-link geometry.
Rollback removes only state owned by the exact operation and prunes only
validated empty canonical ancestry. Cleanup and all non-benign rename, unlink,
rmdir, and fsync failures are reported, never ignored.
Status and recovery validate both exact-operation `.json` and `.tmp` metadata
before target lookup, so malformed owned staging cannot be reported as
absence even when target ancestry is missing.

The operations are:

- `publish`
- `publicationStatus`
- `recoverPublication`
- `rollbackPublication`
- `cleanupPublication`
- `remove`
- `scan`

`scan` accepts committed single-link payloads, bounded descriptor-free staged
payload orphans, and validated recoverable publication descriptors, including
the descriptor `.tmp` crash window. It
binds every descriptor filename to its operation ID and, once a descriptor
exists, verifies the staged or canonical payload size and SHA-256. Attachment
claims are bound to exact descriptor bytes and the canonical payload's declared
size and SHA-256. The only accepted two-link geometries are the three legacy pairs:
`.tmp`+`.json`, `.json`+claim, and `.data`+canonical payload. They must be the
same inode with exactly two links and the exact descriptor/content binding.
Unexpected geometry, third links, identifiers, claim targets, or staging nodes
fail closed.

`claim + canonical payload` without staged data is commit-only. Recovery may
remove the claim only after opening and proving a call-local payload identity.
Rollback and cleanup preserve both names and return `publicationPending`; the
v1 descriptor does not persist an inode identity that could authorize payload
deletion.

## Erasure Control

Whole-store coordination uses `erasure-control/current.json`, outside the
attachment root. Its canonical content is:

```json
{"version":1,"owner":"<opaque operationId>","phase":"erasing"}
```

Native code fsyncs a deterministic owner staging file and exclusively renames
it to `current.json` with the platform primitive above. Status validates
version, owner, phase, file type, and link count. An exact two-link
temp+current inode pair is accepted only as legacy recovery input. Outcomes
distinguish exact ownership, recoverable pending staging, conflict, unsafe
state, and absence. Only the
exact owner may recover, clean staging, or clear `current.json`; clear also
fsyncs and prunes empty control ancestry. Native erasure operations serialize
on the app-private root and retain one validated control-directory descriptor
from status through mutation. Immediately before each owner-sensitive rename,
unlink, or directory removal, they revalidate the named directory and entry
inodes through those descriptors and fail closed if identity changed.

The operations are:

- `writeErasureControl`
- `readErasureControl`
- `recoverErasureControl`
- `clearErasureControl`
- `cleanupErasureControl`

The native API does not delete SQLite, WAL/SHM, exports, shared files, backups,
or remote data.

## Capability And Compatibility

`capabilities` and `selfTest` probe secure randomness, advisory locking,
descriptor-relative directory/file creation, no-follow traversal,
same-directory and cross-directory exclusive rename, collision no-overwrite,
file and directory fsync, file unlink, descriptor-relative directory removal,
and cleanup on the actual app-private volume. A failed required primitive
returns `unsupported` or `ioFailure`; availability is never inferred and no
fallback is attempted.

v1 operation names, request fields, geometry, canonical phases, and outcomes
are wire identifiers. Additive response fields are permitted. Renaming or
weakening them requires a new versioned channel. Issue #221 must preserve
`missing`, `publicationAbsent`, and `erasureAbsent` as idempotent absence and
must never describe them as proof that deletion occurred.
