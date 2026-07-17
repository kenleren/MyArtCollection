# Archivale archive v2

`ARCHIVALE_ARCHIVE_V2` is the full-archive successor used once local groupings
are supported. Archive v1 remains a frozen compatibility codec and fixture
surface; it is not selected by the application full-export flow.

The canonical ZIP order is `manifest.json`, `records/artworks.json`,
`records/external_references.json`, `records/attachments.json`, and mandatory
`records/groupings.json`, followed by lexically ordered attachment payloads.
The groupings envelope is `ARCHIVALE_GROUPINGS_V1` version 1 and always has
the ordered keys `contract`, `version`, `groups`, `memberships`, and
`preferences`; empty data uses empty arrays. It records local organization
only and does not establish provenance, authenticity, ownership, valuation, or
insurance acceptance.

If v2 cannot be safely generated and verified, export fails closed. Hiding the
local groupings UI does not make the app emit a lossy v1 replacement.
