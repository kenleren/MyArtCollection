# Product Plan

## Problem

Collectors with meaningful home collections often have records scattered across photos, receipts, PDFs, emails, notes, and memory. The pain is not just manual cataloging. It is the uncertainty of not knowing what is documented, where documents live, and whether an insurance or estate conversation could be supported quickly.

Archivale should reduce the initial friction from:

> I need to manually inventory my art collection.

to:

> I photograph each piece and the app does most of the boring work.

## Recommended MVP

Build a private, premium mobile collection register with AI-assisted intake and insurer-ready outputs.

The first paid-worthy job is:

> Help a serious hobby collector create a clean, insurer-ready private record of each artwork in under two minutes, with AI assisting but never overclaiming.

## Core Flow

1. Capture or import an artwork photo.
2. AI drafts candidate metadata:
   - artwork type
   - visible signature notes
   - subject matter
   - style or period hints
   - medium guess
   - condition notes
   - frame, glass, and mounting notes
   - suggested descriptive title
3. User confirms or adds:
   - artist
   - title
   - year
   - medium
   - dimensions
   - purchase price
   - purchase date
   - seller or gallery
   - current location
   - insurance value
   - notes
4. User attaches documents:
   - receipt
   - certificate of authenticity
   - appraisal
   - auction record
   - provenance note
5. App creates:
   - private artwork record
   - document-backed completeness status
   - PDF insurance report
   - exportable archive

## Record States

- Draft
- Needs review
- Verified by you
- Missing documents

These states are important because users need to distinguish AI-suggested data from personally confirmed records.

## AI UX Rules

Allowed language:

- Possible
- Likely
- Could not determine
- Please confirm
- Looks extracted from attached receipt
- Visible condition issue
- Signature may read

Disallowed language:

- This is by
- Authentic
- Appraised at
- Market value is
- Certified
- Guaranteed

Do not show fake percentage confidence unless the confidence is genuinely calibrated and tested.

## Must-Have Screens

- Onboarding welcome
- Privacy and storage explainer
- Camera/import flow
- AI draft review
- Artwork detail
- Document attachment
- Collection home/list
- Incomplete records queue
- Report generation
- Export/settings
- Paywall after free limit

## Empty States

No artworks yet:

- Show a direct "Add artwork" action and a small preview of the finished record/report value.

No documents attached:

- Explain that supporting documents strengthen insurance and provenance records.

No insurance values:

- Explain that values are user-provided, not app-certified appraisals.

Search empty:

- Offer filter reset and add-new actions.

No report yet:

- Show a report preview and explain why the report is useful.

## Pricing And Entitlements

Initial hypothesis:

- Free: up to 5 artworks, photo intake, AI draft suggestions, manual edits, basic collection view
- Paid Collector: unlimited artworks, document storage, insurance PDF, full archive export, completeness queue
- Paid Collector Plus later: larger collections, household sharing, advanced exports, priority document extraction

Suggested starting price:

- USD 8 to 12 monthly
- USD 79 to 99 yearly
- Later plus tier at USD 149 to 199 yearly

Do not price around Google storage volume. Google owns that layer in the user's mind.

Do not make export feel hostage-taking. A cancelled user should still have a clear path to retrieve their data.

## Acceptance Checks

- A new user can create and verify the first artwork record in under two minutes.
- Every AI-populated field is distinguishable from user-confirmed data.
- A user can attach at least one supporting document per artwork.
- A user can generate a clean PDF suitable for insurance conversations.
- A user can export their full archive without ambiguity.
- Privacy and storage language is visible in onboarding and settings.
- No screen implies authenticity or appraisal-grade valuation.
- Empty states guide the next useful action.
- The app feels premium on mobile, not like a database form.
- The first five-artwork journey clearly demonstrates why paid is worth it.

## Visual Review Surface

Visual review should cover mobile first, then tablet if the app supports tablet layouts.

Required states:

- Low-confidence AI field
- No-data empty state
- Upload failure
- Offline or interrupted save
- Complete artwork with metadata and documents
- Report ready state
- Free-tier limit reached

Required evidence:

- Screenshots for the main routes
- End-to-end trace from add artwork to confirm to attach document to generate report
- Screenshots of empty, partial, and complete records

## Open Product Decisions

- Should paid conversion trigger at the free artwork limit or first report/export attempt?
- Should backup setup happen during onboarding or after the first verified artwork?
- Should insurance value be strictly user-entered in MVP? Recommendation: yes.
- Should household sharing be in MVP? Recommendation: no.
- Should the brand lean luxury or quiet-premium? Recommendation: quiet-premium.

