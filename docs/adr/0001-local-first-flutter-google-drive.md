# ADR 0001: Local-First Flutter With Google Drive Backup

## Status

Proposed

## Context

Archivale needs to be a slick paid mobile app for iPhone and Android. Its trust story depends on privacy, data ownership, and portability.

The product promise is:

> Take a photo of your artwork. AI drafts the record. You confirm the facts. Your collection stays privately organized and backed up in your own Google account.

The app should not require the user to trust a new vendor-owned collection database before they receive value.

## Decision

Build the MVP as:

- Flutter mobile app
- Local-first data model
- SQLite for structured records
- App-private encrypted file storage for attachments
- Optional encrypted Google Drive `appDataFolder` backup/restore
- Explicit export to user-selected visible destinations
- Thin server-side AI broker for opt-in AI extraction

Do not use Google Photos as primary storage.

Do not make Google login mandatory for the app itself. Google Drive should be an optional backup connection.

## Rationale

Flutter allows one high-quality mobile codebase for iOS and Android.

Local-first behavior supports:

- offline use
- fast capture
- privacy
- user trust
- reduced backend complexity

Google Drive `appDataFolder` supports the trust story while avoiding broad Drive access. A visible Google Drive folder is more transparent but creates metadata leakage and user-editing risk. The product can preserve transparency through explicit ZIP/PDF export.

Google Photos is not a good storage substrate because API access is limited and not designed for private app database semantics.

A server-side AI broker protects vendor secrets, allows schema validation, and creates one controlled point for consent, retention, redaction, and provider changes.

## Consequences

Positive:

- Strong privacy and ownership story
- Works offline
- Easier first app-store posture than building a full app account system
- Lower backend scope
- Backup is optional and understandable

Negative:

- Cross-device sync is more complex than a central cloud database
- Key recovery UX must be designed carefully
- Cross-store purchase portability is harder without an app account
- Conflict handling must be conservative
- App-store privacy disclosures must be precise

## Follow-Up Decisions

- Encryption library and envelope format
- Recovery passphrase UX
- AI vendor and retention terms
- Free tier versus trial-only
- Billing and entitlement architecture
- Whether cross-store purchases matter in MVP

