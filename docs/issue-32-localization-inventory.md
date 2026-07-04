# Issue #32 Localization Inventory And Key Map

Stopped at inventory/key-map stage to avoid a half-migrated UI. The owned
surfaces contain substantially more MVP copy than the current ARB set covers,
and landing code-only key wiring without native-locale review for all supported
languages would recreate the mixed-language state that #32 is meant to remove.

## Audited surfaces

- `lib/app/app.dart`
- `lib/app/app_router.dart`
- `lib/app/screens/prototype_flow.dart`
- `lib/app/screens/placeholders.dart`
- `lib/l10n/app_*.arb`
- generated `lib/l10n/app_localizations*.dart`
- `test/widget_test.dart`

## User-facing literal inventory

### Localize

- App shell and route fallback copy:
  - app title generation
  - loading artwork / opening local record
  - route not found fallback
  - placeholder `Next actions`
- Intro and onboarding:
  - private-record positioning
  - AI suggests / AI drafts / you confirm language
  - privacy/storage explainer copy
  - no-authenticity / no-appraisal disclaimer
- Collection/incomplete/reports/settings:
  - empty states
  - free-limit preview
  - supporting-document and incomplete-queue messaging
  - report/export settings copy
- Add/import/capture:
  - import vs capture titles
  - upload-failure state
  - picker/camera actions
  - interrupted import recovery
  - review-draft / back-to-collection actions
- Draft review and online research:
  - AI draft status panels
  - evidence-photo checklist
  - research consent
  - research disabled / unavailable / retry states
  - candidate-match review controls
  - comparable/source-backed signal explanations
- Artwork details / lifecycle / edit form:
  - lifecycle labels and descriptions
  - remove-from-holdings confirmation
  - edit-field labels, helper text, amount/currency helpers
  - save errors for structured money input
- Documents / report / export:
  - supporting-records disclaimer
  - missing-file state
  - included / excluded report content
  - ZIP/PDF preview wording
- Record-derived display strings:
  - record state badges
  - attachment type labels
  - fallback values such as `Untitled artwork`, `Unknown`,
    `Could not determine`, `Needs review`, `Not set`
  - default notes such as `Confirm this field before using it in a report.`

### Intentionally English or non-localized tokens

- `MyArtCollection` brand
- `AI`
- `Google`, `Google Drive`
- `PDF`, `ZIP`, `ISO`
- currency codes such as `USD`, `EUR`, `NOK`
- route tokens and storage values such as `artwork`, `draft`, `edit`,
  `documents`, `report-preview`, `export`, `capture`, `import`, and enum
  storage values
- backend-only consent summary string passed to online research

### Non-user-facing

- widget keys
- route names
- attachment/research IDs
- regex patterns and normalization errors before they are mapped to UI

## Existing locale quality issues found

Current ARB files already contain placeholder or transliterated copy that needs
native-locale replacement, including at least:

- `Unvollstaendig`
- `hinzufuegen`
- `beloep`
- `Reglages`
- `oeuvre`
- multiple ASCII-fallback forms across `da`, `de`, `es`, `fi`, `fr`, `is`,
  `pl`, `pt`, and `sv`

## Required key families

The missing key expansion is larger than the current shared ARB shape. At a
minimum, add keys for:

- Shell/navigation/fallback states
- Intro/onboarding/privacy copy
- Collection, incomplete queue, reports, settings
- Add/import/capture actions and status panels
- Draft review / AI status / evidence checklist
- Research consent, research states, source-backed candidates, comparables
- Lifecycle labels and lifecycle descriptions
- Edit form labels, helper text, save errors
- Documents, report preview, export preview
- Attachment type labels
- Record state labels
- Fallback display values and default notes
- Pluralized strings for:
  - citation counts
  - comparable signal counts
  - supporting-document counts
  - incomplete-queue item counts
  - fields needing confirmation
  - missing core-field counts
  - completeness progress

## Trust/legal meaning notes that still need committed wording review

Keep these wording families aligned across all supported locales:

- AI suggestion vs user confirmation:
  - suggestions stay suggestions until saved/confirmed
  - no silent promotion of AI values into confirmed record facts
- Insurance value:
  - always user-provided / user-confirmed
  - not market value, not appraisal
- Comparable/source-backed research:
  - source context only
  - not authentication, not attribution certainty, not appraisal
- Privacy/local-first/backup:
  - local-first by default
  - backup only when enabled into the user’s Google account
  - no broad photo-library access claim drift
- Authenticity / appraisal / market-value disclaimers:
  - do not weaken the negative claim in translation

## Verification still required once implementation resumes

- `flutter analyze`
- `flutter test`
- locale screenshots for `en-US`, `nb-NO`, `de-DE`, `fr-FR`, plus `fi-FI` or
  another longest-risk locale
- mobile-width or emulator evidence if physical Pixel screenshots are not
  available

## Recommended follow-up sequencing

Promote `#54` first: localize hardcoded MVP UI strings and generate the missing
key map in one reviewable branch.

Keep these behind it:

- `#55` native-locale replacement of placeholder/transliterated copy
- `#56` trust-sensitive translation review
- `#57` mobile long-string visual QA
