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
canonical name, byte size, SHA-256, and the `staged` phase. The descriptor is
published from `.tmp` by an exclusive hard link. The same descriptor inode is
then linked as `<attachment>/.publication.json`, providing attachment-wide
exclusion even when concurrent attempts use different extensions.

Publication copies and verifies the staged bytes, fsyncs every new directory
entry and created ancestry level, links the payload with no-replace semantics,
verifies descriptor and payload inode relationships, and commits by removing
the attachment claim. Recovery reconciles the bounded two-link states by inode
and re-verifies size and SHA-256 before success. Rollback removes only state
owned by the exact operation and prunes empty canonical ancestry. Cleanup and
all non-benign unlink, rmdir, and fsync failures are reported, never ignored.

The operations are:

- `publish`
- `publicationStatus`
- `recoverPublication`
- `rollbackPublication`
- `cleanupPublication`
- `remove`
- `scan`

`scan` accepts committed single-link payloads and validated recoverable
publication descriptors. Unexpected geometry, links, identifiers, or staging
nodes fail closed.

## Erasure Control

Whole-store coordination uses `erasure-control/current.json`, outside the
attachment root. Its canonical content is:

```json
{"version":1,"owner":"<opaque operationId>","phase":"erasing"}
```

Native code fsyncs a deterministic owner staging file, publishes
`current.json` with an exclusive hard link, fsyncs the directory, and removes
the staging link. Status validates version, owner, phase, file type, link
count, and the inode relationship in a two-link recovery window. Outcomes
distinguish exact ownership, recoverable pending staging, conflict, unsafe
state, and absence. Only the
exact owner may recover, clean staging, or clear `current.json`; clear also
fsyncs and prunes empty control ancestry.

The operations are:

- `writeErasureControl`
- `readErasureControl`
- `recoverErasureControl`
- `clearErasureControl`
- `cleanupErasureControl`

The native API does not delete SQLite, WAL/SHM, exports, shared files, backups,
or remote data.

## Capability And Compatibility

`capabilities` and `selfTest` probe secure randomness, descriptor-relative
directory/file creation, no-follow traversal, exclusive hard links, link-count
inspection, file and directory fsync, unlink, and cleanup. A failed required
primitive returns `unsupported` or `ioFailure`; availability is never inferred.

v1 operation names, request fields, geometry, canonical phases, and outcomes
are wire identifiers. Additive response fields are permitted. Renaming or
weakening them requires a new versioned channel. Issue #221 must preserve
`missing`, `publicationAbsent`, and `erasureAbsent` as idempotent absence and
must never describe them as proof that deletion occurred.
