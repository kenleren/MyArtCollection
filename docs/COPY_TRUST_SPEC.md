# Copy and Trust Rules

This spec defines the language used anywhere the app talks about AI output, privacy, storage, export, and valuation-adjacent content.

## Core Rules

- AI suggests; the user confirms.
- User-confirmed facts outrank AI output.
- Private records stay in the user’s own Google account when backup is enabled.
- Export and report language must be explicit about what is included and what is not.
- Never imply authenticity, appraisal certainty, market value, or attribution certainty.
- When the system is unsure, say so plainly.

## Allowed Language

Use these phrases or close equivalents:

- Possible
- Likely
- Could not determine
- Please confirm
- Visible condition issue
- Signature may read
- Looks extracted from attached receipt
- User confirmed
- Backed up in your Google account
- Export your archive
- Preview the collector report PDF
- Private record
- This document supports the record, but does not prove authenticity
- This saved document is unavailable. You can replace it when ready.

## Disallowed Language

Do not use these phrases or anything that means the same thing:

- This is by
- Authentic
- Authenticity confirmed
- Appraised at
- Market value is
- Certified
- Guaranteed
- Proven
- Original by
- Verified artist attribution
- Insurance-approved valuation
- Official appraisal
- All original documents are included
- This archive is complete

## Surface Examples

### Onboarding

Allowed:

- "Take a photo. AI drafts the record. You confirm the facts."
- "Keep your collection privately organized in your own Google account."
- "This app does not determine authenticity or appraise value."

Avoid:

- "We identify the artist for you."
- "Get instant authenticity checks."
- "Appraisal-grade valuation in minutes."

### AI Draft Review

Allowed:

- "Possible medium: oil on canvas"
- "Signature may read: J. Smith"
- "Could not determine the year"
- "Please confirm the title before saving"

Avoid:

- "This is by J. Smith"
- "Market value is $2,000"
- "Certified medium"

### Settings

Allowed:

- "Back up your records in your Google account"
- "Disconnect Google Drive"
- "Delete local data"
- "Export your archive"
- "Privacy and storage"

Avoid:

- "Syncs all your art forever"
- "Automatic cloud ownership"
- "Certified secure backup"

### Document Attachment

Allowed:

- "Attach a receipt, certificate, appraisal, or provenance note"
- "This document supports the record, but does not prove authenticity"
- "Looks extracted from attached receipt"

Avoid:

- "This document proves authenticity"
- "Certified provenance"
- "Appraisal verified by this file"

When a saved document cannot be reopened, say that it is unavailable and offer
replacement. Do not show device paths, picker URIs, or technical storage
details. Archive wording must identify excluded attachment statuses without
claiming completeness.

### Empty States

Allowed:

- "No artworks yet. Add artwork to start your first record."
- "No documents attached yet. Add supporting documents for insurance and provenance records."
- "No insurance values yet. These values are user-provided, not app-certified appraisals."

Avoid:

- "Your collection is complete"
- "Documents prove ownership"
- "Insurance value confirmed"

### Export / Report

Allowed:

- "Preview the collector report PDF"
- "Export your archive as ZIP"
- "Includes confirmed fields, attached documents, and report date"
- "User-provided insurance values only"

Avoid:

- "Insurance-ready PDF"
- "Insurance-approved report"
- "Appraised collection report"
- "Proof of authenticity"
- "Guaranteed coverage"

## Field-Level Guidance

- Artist, title, year, medium, dimensions, notes, and location can be suggested by AI, but only user confirmation makes them verified.
- Insurance value must be labeled as user-provided unless a future dedicated appraisal workflow exists.
- Provenance, certificate, and document references should be described as records or supporting documents, not proof.
- If the app cannot read something from an image or document, say "Could not determine" or "Please confirm" rather than guessing.

## Required Copy Constraints

- Onboarding must mention privacy or storage ownership.
- AI draft review must visibly separate suggestions from confirmed data.
- Settings must expose backup, disconnect, delete, and export paths.
- Report and export surfaces must explain contents without claiming valuation or authenticity.
- Empty states may encourage the next action, but must not overstate confidence or completeness.
