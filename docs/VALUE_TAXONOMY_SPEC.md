# MVP Value Taxonomy Spec

## Problem

Issue #68 asks whether MyArtCollection should model separate retail and private
prices, low/high bands, and optional settings. The underlying MVP decision is
how to represent value-adjacent information without implying that the app
determines market value, appraisal certainty, insurance approval, or currency
conversion.

Recommendation: do not add first-class retail/private/resale value fields in
MVP. Keep three distinct value concepts:

1. `purchase_price`: user or document-backed acquisition record.
2. `insurance_value`: user-provided record field only.
3. `comparable_value_signals`: source-backed research context, not the value of
   the user's artwork.

## Local Evidence

| Evidence | Current rule or behavior |
| --- | --- |
| [Artwork Record Schema](ARTWORK_RECORD_SCHEMA.md) | `purchase_price` and `insurance_value` are optional artwork fields; money values require currency and source context; exports must not rename user-provided values as verified market value. |
| [AI Artwork Research Spec](AI_ART_RESEARCH_SPEC.md) | Value output is high risk and must be framed as source-backed comparables. Allowed labels include `Comparable sale signal`, `Public estimate found`, `User-provided insurance value`, and `No reliable comparable found`. |
| [AI Broker Payload And Telemetry Spec](AI_BROKER_PAYLOAD_AND_TELEMETRY_SPEC.md) | Broker comparable output allows `public_estimate`, `comparable_sale_signal`, and `no_reliable_comparable`; `user_provided_insurance_value` is client-local only and must not traverse broker/provider/log surfaces. |
| [Copy and Trust Rules](COPY_TRUST_SPEC.md) | Never imply authenticity, appraisal certainty, market value, or attribution certainty. Insurance value must be labeled user-provided unless a future appraisal workflow exists. |
| [Product Plan](PRODUCT_PLAN.md) and [Mobile IA](MOBILE_IA.md) | MVP is an insurer-ready private record with AI assistance and user confirmation. Existing open decision recommends insurance value stays strictly user-entered. |
| `lib/app/storage/artwork_record.dart` | `ArtworkFieldValue` already stores `moneyAmount` and `moneyCurrencyCode` for artwork fields; `purchase_price` and `insurance_value` are current field keys. |
| `lib/app/storage/ai_research_record.dart` | `ComparableValueSignal` stores `kind`, source, optional `amountLow`, `amountHigh`, `currency`, date, and caveat separately from artwork field values. |
| `lib/app/research/online_research_service.dart` and tests | Online research rejects user-entered insurance values, rejects non-auction monetary comparables, sanitizes unsafe "market value" language, and preserves `No reliable comparable found`. |
| `test/widget_test.dart` | Details, report, and export surfaces already assert structured purchase and insurance money display without FX conversion; comparable cards display allowed auction ranges and suppress unsafe labels. |

## Non-Goals

- No AI valuation, appraisal, "worth", or market-value estimate.
- No FX conversion, normalized currency, converted collection totals, or
  cross-currency aggregation in MVP.
- No settings that let users choose "retail", "private", or "resale" as app
  valuation modes.
- No derived low/high bands for an artwork unless a source explicitly provides a
  range or a single source-backed amount.
- No automatic copying of research comparable amounts into `insurance_value`.
- No production implementation in this spec task.

## Requirements

### First-Class MVP Fields

- `purchase_price`
  - Meaning: what the user paid or what a receipt/document says was paid.
  - Source states: user-confirmed or document-extracted; AI may only help
    draft/extract and must remain reviewable.
  - Display/export label: `Purchase price`.
  - Preserve original amount and original currency only.

- `insurance_value`
  - Meaning: value the user wants recorded for insurance conversations.
  - Source states: user-confirmed, or document-extracted from an attached
    appraisal/insurance document only after review.
  - Display/export label: `User-provided insurance value`.
  - Must not be shown as app-certified, insurer-approved, appraised, market,
    retail, private, or resale value.

- `comparable_value_signals`
  - Meaning: research evidence from approved sources that may inform the user's
    later expert/appraisal/insurance conversation.
  - Source requirement: source URL/reference is required for any public estimate
    or comparable sale signal.
  - Display/export label family: `Comparable source signals`, `Comparable sale
    signal`, `Public estimate found`, `No reliable comparable found`.
  - Always include a caveat that comparable data may not apply to the user's
    artwork.

### Retail, Private, And Resale Wording

Retail/private/resale labels are not first-class MVP fields. They may be
preserved as source wording only when they appear in a cited source or user
note, for example in a source snippet, source note, attachment note, or future
`source_context_label`.

Implementation rule: if a source says "retail estimate", display it only as
source context near the citation. Do not create `retail_value`,
`private_sale_value`, `resale_value`, or a user setting that changes how the app
interprets values.

### Low/High Bands

Low/high bands are allowed only for `ComparableValueSignal` when source-backed:

- Use `amountLow` and `amountHigh` when a source gives an estimate range.
- Use one side only when the source gives a single amount and the product copy
  still calls it a comparable amount, not a band.
- Do not infer a high/low range from one amount, user-entered insurance value,
  purchase price, generic retail/private wording, or currency conversion.
- Preserve the original source currency code and date when present.

### UI, Report, And Export Labels

Allowed labels:

- `Purchase price`
- `User-provided insurance value`
- `Comparable source signals`
- `Comparable sale signal`
- `Public estimate found`
- `No reliable comparable found`
- `Source context`
- `Needs expert appraisal`

Disallowed labels:

- `Market value`
- `Retail value`
- `Private sale value`
- `Resale value`
- `Worth`
- `Appraised at`
- `Certified value`
- `Insurance-approved value`

Report/export guidance:

- Reports may include purchase price and user-provided insurance value when
  present.
- Reports may include comparable source signals in a separate research appendix
  or clearly separated section only after source-rights review permits display.
- Exports should preserve original currency, source name, source URL, source
  type, signal date, low/high amount fields, and caveat text.
- No PDF, ZIP, CSV, or UI surface should claim conversion, total collection
  value, retail/private market price, or appraisal-grade certainty.

## Options Considered

| Option | Pros | Cons | Decision |
| --- | --- | --- | --- |
| Add first-class retail/private/resale value fields | Gives collectors more categories for future sale planning. | High copy risk, weak MVP explanation, source semantics vary by market, and it looks like app valuation. | Reject for MVP. |
| Add optional low/high bands on artwork value fields | Simple mental model for estimated value. | Encourages unsupported ranges and conflates insurance, sale, and market signals. | Reject for MVP. |
| Keep purchase and insurance fields, with source-backed comparable signals | Matches current schema/tests, keeps value claims auditable, and is reversible later. | Users who want resale planning must store notes until a future workflow exists. | Recommended. |
| Remove comparable amounts from MVP entirely | Lowest trust risk. | Loses useful auction/estimate evidence already guarded by source checks. | Do not remove; keep conservative and source-backed. |

## Recommended MVP Approach

1. Treat `purchase_price` and `insurance_value` as the only editable artwork
   money fields in MVP.
2. Treat comparable values as research records, not artwork facts.
3. Preserve retail/private/resale wording as source context only, without
   schema-level interpretation.
4. Allow low/high bands only on source-backed comparable signals.
5. Keep all currency display as original-currency display. Do not convert,
   aggregate, or imply current value.
6. Use "Needs expert appraisal" only as guidance, never as a value result.

What would make this recommendation wrong:

- User research shows MVP users cannot complete insurance/report workflows
  without a separate resale or retail planning field.
- A vetted appraisal/insurance partner workflow introduces an authoritative
  source type with explicit legal/copy review.
- Source-rights review approves a paid price database with precise field
  semantics that users can understand without overclaiming.

## Data Model Implications

No new MVP schema is required for issue #68 if current fields are used as
documented:

- Keep `ArtworkFieldKeys.purchasePrice` and
  `ArtworkFieldKeys.insuranceValue`.
- Keep `ArtworkFieldValue.moneyAmount` and `moneyCurrencyCode` as original
  amount/currency storage.
- Keep `ComparableValueKind.publicEstimate`,
  `ComparableValueKind.comparableSaleSignal`, and
  `ComparableValueKind.noReliableComparable` for broker/research output.
- Keep `ComparableValueKind.userProvidedInsuranceValue` client-local only. It
  should not appear in broker requests/responses.
- Keep `ComparableValueSignal.amountLow`, `amountHigh`, `currency`, and
  `signalDate` as source-backed fields.

Possible later addition, not MVP: `sourceContextLabel` on comparable signals or
attachments to preserve terms like "retail estimate" without making them value
types. Add only if implementation finds cited sources where the wording is
important and cannot be preserved cleanly in the existing caveat/source note.

## Risks And Mitigations

| Risk | Mitigation |
| --- | --- |
| Users read comparable amounts as the artwork's value. | Keep comparable signals visually separate from artwork fields and repeat "source context only, not an appraisal." |
| Retail/private wording becomes inconsistent across locales. | Do not promote it into localized first-class labels in MVP. Preserve exact source wording only where cited. |
| Reports look insurance-approved. | Use `insurance-ready PDF` and `User-provided insurance value`; avoid `insurance-approved` and appraisal wording. |
| AI/provider output returns unsafe value language. | Keep sanitizer tests for `market value`, `worth`, `appraised at`, `certified`, and related terms. |
| Currency formatting implies conversion or current value. | Prefix original ISO currency and formatted original amount only; do not total across currencies. |

## Acceptance Checks

- Schema/docs state that purchase price, insurance value, and comparable
  research signals are distinct.
- No user-facing label introduces first-class `retail value`, `private value`,
  `resale value`, `market value`, or `worth` in MVP.
- UI/report/export tests assert:
  - purchase price label remains `Purchase price`;
  - insurance label remains `User-provided insurance value`;
  - comparable ranges render only in `Comparable source signals`;
  - unsafe comparable labels are suppressed;
  - no FX conversion or collection total is shown.
- Research service tests assert:
  - broker/provider output cannot provide `user_provided_insurance_value`;
  - non-approved/non-auction sources cannot surface monetary comparable amounts;
  - low/high comparable amounts require validated source linkage;
  - `No reliable comparable found` has no amount/currency/date.
- Storage tests assert original amount/currency/source context round-trips for
  both artwork money fields and comparable signals.

## Follow-Up Implementation Tasks

1. Update schema and trust docs to reference this taxonomy.
   - Skill: `$codex-task-work`.
   - Scope: docs only, no production code.

2. Audit UI/report/export labels against this spec.
   - Skill: `$codex-task-plan` first if labels move across multiple screens,
     then `$codex-task-work`.
   - Evidence: widget tests for details, report preview, export preview, and
     research comparable cards.
   - Visual review: `$codex-visual-review` only if layout or visible UI changes,
     not for copy-only docs.

3. Add/adjust model tests for the value taxonomy.
   - Skill: `$codex-task-work`.
   - Evidence: `flutter test test/local_artwork_repository_test.dart
     test/ai_research_storage_test.dart test/online_research_service_test.dart`.

4. Add export/report assertions for "no appraisal certainty/no FX conversion".
   - Skill: `$codex-task-work`.
   - Evidence: targeted widget tests around report/export preview labels.

5. Decide later whether `sourceContextLabel` is needed.
   - Skill: `$codex-research-spec` if real source examples show ambiguous
     retail/private wording that cannot be represented as caveat/source note.
   - Human decision required before schema change.

## Open Human Decisions

- Should any comparable source signals appear in MVP insurance PDFs, or only in
  local research review until source-rights review is complete?
- Is "Needs expert appraisal" acceptable as an allowed guidance label in MVP
  reports, or should it remain research-screen-only?
- Should future resale planning be a separate post-MVP workflow rather than
  more fields on the core artwork record?
