# Attachment Custody API v1

Issue #220 owns this frozen Android/iOS API. Issue #221 consumes it for v9
lifecycle, reconciliation, and whole-store coordination and must not change
the Dart bridge, native entry points, or native build wiring.

## Boundary

`AttachmentCustodyBridge` exposes `capabilities`, `selfTest`, `publish`,
`remove`, `scan`, and whole-store marker read/write/clear operations.

- `publish` and `remove` accept only opaque artwork and attachment IDs plus an
  approved canonical payload name (`payload.jpg`, `payload.jpeg`,
  `payload.png`, `payload.heic`, `payload.heif`, or `payload.pdf`).
- `sourcePath` is a one-time import input for publication. It is not persisted,
  never controls a destination, and cannot be used by removal or scanning.
- Roots are platform-owned: Android anchors at `Context.getDir("flutter")` and
  iOS anchors at the app Documents directory. The native core opens every
  canonical component descriptor-relatively with no-follow behavior.
- A result of `unsafeNode`, `unsupported`, or `ioFailure` is blocked work.
  Callers must not substitute Dart path deletion, recursive cleanup, or a
  success state.

## Durability And Recovery

Publication copies to a native `.staging` leaf, fsyncs the leaf and staging
directory, then publishes with exclusive no-replace semantics and fsyncs the
destination directory. Platforms without `renameat2` use an atomic `linkat`
no-replace publication followed by stage unlink; scanners accept its bounded
two-link crash window without following it.

`scan` traverses only canonical geometry and reports safe payload tuples. Any
link, hard-linked payload, unexpected node, invalid ID, or noncanonical
directory geometry fails closed as `unsafeNode`. It is the orphan-discovery
input for #221, not permission to recursively remove arbitrary files.

The whole-store marker is outside `attachments`, is written exclusively and
fsynced, and is cleared only by its owning opaque operation ID after the v9
coordinator has completed its own database/output verification. The native API
does not delete SQLite, WAL/SHM, exports, shared files, backups, or remote data.

## Compatibility

v1 outcomes are wire identifiers. Additive response fields are permitted;
renaming an operation, outcome, canonical name, or request field requires a
new versioned channel. #221 must preserve a `missing` result as idempotent
absence rather than claim a deletion occurred.
