# Prototype Storyboard

This document is the docs-only prototype storyboard for issue #5. It defines the screens, fixtures, and state coverage that the later build task must implement and visually verify.

The storyboard is intentionally concrete so a future UI build can be checked against it without reinterpreting the product intent.

## Scope

Prototype coverage:

- Add artwork from photo capture or import
- AI draft review
- Confirm and edit fields
- Attach document
- Completeness status and incomplete queue
- Report preview and export preview
- Free-limit and paywall hint
- Success, partial-data, no-document, upload-failure, and offline or interrupted-save states

Out of scope for this prototype spec:

- Final visual design details
- Implementation code
- Real billing integration
- Claiming authenticity, appraisal, or market value

## Primary Product Constraints

The storyboard must stay aligned with the repo's product and trust docs:

- `docs/PRODUCT_PLAN.md`
- `docs/COPY_TRUST_SPEC.md`
- `docs/MOBILE_IA.md`
- `docs/ARTWORK_RECORD_SCHEMA.md`
- `docs/ARCHITECTURE.md`

The key rule is still: AI suggests; the user confirms.

## Storyboard Sequence

### 1. Collection Home

Entry point for the prototype flow.

On screen:

- A collection list or empty state
- Primary action: `Add artwork`
- Secondary actions: `Incomplete records`, `Generate report`, `Export archive`, `Settings`
- Free limit hint when the user is at or near the initial limit

Storyboard note:

- The free-limit hint is a teaser only, not a functional billing surface.
- The hint should make the paid threshold visible without blocking the first record.

Maps to:

- Product Plan: `Must-Have Screens`, `Pricing And Entitlements`, `Acceptance Checks`
- Mobile IA: `Collection Home`
- Architecture: `Export is a first-class recovery path`

### 2. Add Artwork

User chooses how to start.

On screen:

- `Take photo`
- `Import photo`
- `Attach document`
- `Cancel`

Storyboard note:

- Capture and import are the first split in the flow.
- The screen should feel like the start of one intake path, not three unrelated tools.

Maps to:

- Product Plan: `Core Flow`, `Must-Have Screens`
- Mobile IA: `Add Artwork`
- Architecture: `AI upload must be explicit and minimal`

### 3. Capture or Import

The user supplies the primary artwork image.

On screen:

- Camera capture state
- Imported photo state
- Immediate handoff into draft creation

Required fixtures:

- Success capture
- Partial-data image, where the subject is present but some details are unclear
- Upload-failure state
- Offline or interrupted-save state

Maps to:

- Product Plan: `Core Flow`, `Visual Review Surface`
- Mobile IA: `Capture`
- Schema: `primary_image` requirement
- Architecture: offline capture and local-first behavior

### 4. AI Draft Review

The system presents suggested metadata beside empty or user-entered fields.

On screen:

- Suggested title, artist, year, medium, dimensions, condition notes, and related descriptive fields
- Visual distinction between AI-suggested, document-extracted, user-confirmed, and unknown values
- Controls to confirm, edit, reject, or leave unknown

Required fixtures:

- Success draft with multiple AI suggestions
- Partial-data draft with several unknown fields
- Low-confidence or unclear field labels
- No-document state surfaced alongside the draft

Maps to:

- Product Plan: `Core Flow`, `AI UX Rules`, `Acceptance Checks`
- Copy/Trust: allowed language such as `Possible`, `Likely`, `Could not determine`, `Please confirm`
- Schema: field source states and trust validation
- Architecture: schema-validated AI responses and user confirmation

### 5. Confirm And Edit

The user reviews the draft and makes it their own record.

On screen:

- Editable fields for artist, title, year, medium, dimensions, purchase price, purchase date, seller or gallery, current location, insurance value, and notes
- Clear user-confirmed state after edits
- No language implying certainty around authenticity or appraisal

Storyboard note:

- This state must show the transition from suggestion to user-confirmed data.
- The prototype should make it obvious which fields are still unresolved.

Maps to:

- Product Plan: `Core Flow`, `Acceptance Checks`
- Copy/Trust: `User-confirmed facts outrank AI output`
- Schema: `user-confirmed` as authoritative
- Mobile IA: `Artwork Details`, `AI Draft Review`

### 6. Attach Document

The user attaches support material to the record.

On screen:

- Attach receipt
- Attach certificate of authenticity
- Attach appraisal
- Attach auction record
- Attach provenance note
- Document list with type and state

Required fixtures:

- Success attach
- No-document state before attachment
- Upload-failure state

Storyboard note:

- The screen should say documents support the record, not prove authenticity.
- The document type label should remain descriptive, not evaluative.

Maps to:

- Product Plan: `Core Flow`, `Empty States`, `Acceptance Checks`
- Copy/Trust: document attachment language and disallowed claims
- Schema: attachment types and source states
- Mobile IA: `Document Attachment`

### 7. Completeness And Incomplete Queue

The app summarizes what still needs attention.

On screen:

- Record state badge such as `Draft`, `Needs review`, `Verified by you`, or `Missing documents`
- Incomplete queue with records needing review or documents
- Direct actions to resolve missing fields or attach documents

Required fixtures:

- Success record marked complete or verified by you
- Partial-data record in needs-review state
- Missing-documents record

Maps to:

- Product Plan: `Record States`, `Acceptance Checks`
- Mobile IA: `Incomplete Queue`
- Schema: `Record States` and `Completeness Rules`
- Architecture: no silent overwrite; offline-capable local data

### 8. Report Preview

The user previews what will be included in the insurance-ready output.

On screen:

- Confirmed fields
- User-provided insurance value
- Attached documents list
- Report date
- Inclusion and exclusion note

Required fixtures:

- Report-ready success state
- Partial record where the preview explains missing inputs
- No-report-yet empty state that still points to the next action

Maps to:

- Product Plan: `Core Flow`, `Must-Have Screens`, `Empty States`, `Acceptance Checks`
- Copy/Trust: `Generate an insurance-ready PDF`, `User-provided insurance values only`
- Schema: export and insurance PDF mapping
- Mobile IA: `Report Preview`
- Architecture: local report generation and export

### 9. Export Preview

The user prepares the final archive or PDF export.

On screen:

- Export PDF
- Export ZIP archive
- Export summary that makes contents explicit
- Recovery-oriented language, not hostage-style gating

Maps to:

- Product Plan: `Pricing And Entitlements`, `Acceptance Checks`
- Copy/Trust: `Export your archive`
- Mobile IA: `Export`
- Architecture: export as a first-class recovery path

### 10. Free Limit And Paywall Hint

The prototype includes a calm upsell hint when the free limit is reached or nearly reached.

On screen:

- Free-tier limit reached message
- Clear path to continue using paid features
- No implication that export or recovery is trapped behind the paywall

Storyboard note:

- The hint should support the business model without undermining trust.
- It should still leave a valid path to retrieve user data.

Maps to:

- Product Plan: `Pricing And Entitlements`, `Acceptance Checks`
- Copy/Trust: avoid hostage-taking export language
- Architecture: export remains easy and obvious

## Prototype Fixtures

These fixtures are the concrete states the later build task must render and capture.

1. `collection-empty`
   - No artworks yet
   - Add-artwork action visible
   - Small preview of the finished record or report value
2. `capture-success`
   - Primary image captured or imported
   - Draft creation begins
3. `draft-partial`
   - Some fields are `AI-suggested`
   - Some fields are `unknown`
   - User-confirmed and suggested values remain visually distinct
4. `draft-no-document`
   - Draft exists without attachments
   - UI explains that supporting documents are optional but useful
5. `draft-upload-failure`
   - Document or photo upload failed
   - Retry action visible
6. `save-interrupted-offline`
   - Local save interrupted or offline
   - Draft persists locally and shows recovery state
7. `record-confirmed`
   - Core fields confirmed by the user
   - Record marked `Verified by you`
8. `record-missing-documents`
   - Record is usable but incomplete
   - Queue surfaces what is still needed
9. `report-ready`
   - Insurance-ready preview is available
   - Export actions visible
10. `free-limit-reached`
   - Free-tier hint visible
   - Paid upgrade path visible without blocking recovery

## State Matrix

The following matrix shows how the prototype fixtures map to the product-plan states that matter for acceptance.

| Prototype fixture | Product-plan state or check | Trust / copy rule |
| --- | --- | --- |
| `collection-empty` | Empty state guidance, add-artwork entry | Next action must be obvious |
| `capture-success` | First usable artwork record | AI assist must not overclaim |
| `draft-partial` | Draft and needs-review flow | AI-suggested must remain distinct |
| `draft-no-document` | Missing documents surfaced without blame | Supporting docs are records, not proof |
| `draft-upload-failure` | Upload failure state | Retry must be explicit |
| `save-interrupted-offline` | Offline / interrupted-save state | Local-first and recoverable |
| `record-confirmed` | Verified by you state | User-confirmed outranks AI |
| `record-missing-documents` | Missing documents queue | No appraisal requirement |
| `report-ready` | Insurance-ready PDF preview | User-provided insurance values only |
| `free-limit-reached` | Paid worth demonstration | Export and recovery stay explicit |

## Visual Evidence Requirements For The Future Build Task

The implementation task that follows this storyboard should gather visual evidence for these states:

- Mobile first, then tablet if the layout supports it
- Add artwork
- Draft review
- Confirm/edit
- Attach document
- Incomplete queue
- Report preview
- Export preview
- Free-limit hint
- No-data empty state
- Partial-data state
- No-document state
- Upload-failure state
- Offline or interrupted-save state

Evidence should include:

- Screenshots of the main routes
- An end-to-end trace from add artwork to confirm to attach document to generate report
- Screenshots of empty, partial, and complete records
- A note on any browser, device, or rendering limitations

## Review Handoff Notes

This storyboard is ready for the implementation task to build against.

Residual risks:

- The exact visual treatment of the paywall hint is still open, as long as it does not trap export or recovery.
- The later build task will need to keep the copy aligned with the trust rules while translating this storyboard into actual UI text.
- The future visual-review pass must verify the states listed above because the acceptance check depends on them.

