# Google Play Listing Prep

Issue: #53  
Project: https://github.com/users/kenleren/projects/1  
Scheduling evidence: https://github.com/kenleren/MyArtCollection/issues/53#issuecomment-4883635998

## Problem statement

Prepare a decision-ready Google Play listing package for MyArtCollection before
beta or public distribution. The listing must improve install conversion
without making trust, privacy, AI, authenticity, appraisal, or policy claims
that the product cannot support.

## Context and evidence

- No `AGENTS.md` was present in the repo at spec time.
- Repo positioning is consistent across [README.md](/Users/kenleren/Private/Ken/MyArtCollection/README.md),
  [docs/PRODUCT_PLAN.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/PRODUCT_PLAN.md),
  [docs/GTM_PLAN.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/GTM_PLAN.md),
  and [docs/NORTH_STAR.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/NORTH_STAR.md):
  this is a private art record app for serious hobby collectors, not an
  appraiser, authenticity engine, marketplace, or social network.
- Trust language is bounded by
  [docs/COPY_TRUST_SPEC.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/COPY_TRUST_SPEC.md):
  AI suggests, the user confirms; no authenticity certainty, market value
  certainty, or certification claims.
- Privacy and data-disclosure constraints are bounded by
  [docs/ARCHITECTURE.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/ARCHITECTURE.md),
  [docs/LOCAL_STORAGE_SPEC.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/LOCAL_STORAGE_SPEC.md),
  [docs/FIREBASE_TELEMETRY_POLICY.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/FIREBASE_TELEMETRY_POLICY.md),
  and
  [docs/FIREBASE_APP_DISTRIBUTION.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/FIREBASE_APP_DISTRIBUTION.md).
- Current Google Play primary-source constraints used here:
  - app name `30` chars, short description `80`, full description `4000`
  - app icon required: `512x512` PNG, max `1024 KB`
  - feature graphic required: `1024x500`, JPG or 24-bit PNG, no alpha
  - screenshots: up to `8` per supported device type; large-screen assets need
    at least `4` if provided
  - metadata must be clear, relevant, non-misleading, and non-spammy
  - custom store listings require an existing default store listing and a
    published app
  - new personal developer accounts created after November 13, 2023 must pass a
    closed-test gate with `12` opted-in testers for `14` consecutive days
    before production access

## Non-goals

- No Play Console submission or publishing.
- No app-code edits.
- No paid acquisition setup.
- No fabricated screenshots or claims beyond the current product behavior.
- No public promise of authenticity, appraisal certainty, market value, or
  stronger privacy guarantees than the repo currently supports.

## Requirements

1. Keep the store story centered on private records, fast intake, supporting
   documents, and exports.
2. Keep all AI language assistive and review-based.
3. Keep privacy language factual:
   - local-first by default
   - optional Google-account backup only when that shipped behavior exists in
     the release being listed
   - clear export and delete/disconnect controls
4. Use phone-first creative. Add large-screen assets only after real
   large-screen layouts are verified.
5. Treat Data safety answers and the privacy-policy URL as release gates, not
   copy afterthoughts.

## Options considered

| Decision | Option | Pros | Risks | Recommendation |
| --- | --- | --- | --- | --- |
| App title | `MyArtCollection` | Clean brand | Too generic for first-glance understanding | No |
| App title | `MyArtCollection: Art Records` | Brand plus clear function inside 30 chars | Slightly less elegant brand presentation | Yes |
| App title | `MyArtCollection: Art Inventory` | Strong search intent | "Inventory" can read generic or household-focused | Backup option |
| Category | `Art & Design` | Best matches art-specific discovery and collector intent | Slightly less obviously utilitarian | Yes |
| Category | `Productivity` | Signals utility and organization | Loses art-specific relevance | No |
| Listing emphasis | AI-first | Curiosity and demos | Attracts appraisal / identification expectations | No |
| Listing emphasis | privacy + records + export | Best match to repo truth and paid wedge | Slightly less flashy | Yes |

Recommendation could be wrong if beta evidence shows users primarily search for
generic home-inventory language rather than art-specific record language.

## Recommended main listing package

### App name guidance

Recommended:

- `MyArtCollection: Art Records`

Fallback:

- `MyArtCollection: Art Inventory`

Rule:

- Do not append ranking claims, pricing words, or AI buzzwords to the title.

### Short description draft

Recommended draft:

- `Private artwork records with AI-assisted drafts, documents, and export`

Why:

- Fits the `80`-character limit.
- States the job clearly.
- Avoids appraisal/authenticity/privacy overclaim.

### Full description draft

Recommended draft:

```text
Keep your artwork records private, organized, and easier to trust.

MyArtCollection helps serious hobby collectors turn photos, receipts, certificates, appraisals, and notes into clean artwork records without building a spreadsheet or hiring a registrar.

How it works:
- Add an artwork from a photo or import
- Review AI-assisted draft details
- Confirm the facts yourself
- Attach supporting documents
- Track what still needs review
- Generate exportable records and insurance-ready PDFs

Built for collectors who want:
- A private record of what they own
- Faster cataloging for small to mid-size collections
- Better document organization for insurance, moving, estate, or appraisal conversations
- Clear separation between AI suggestions and confirmed facts

Trust and privacy:
- AI suggests. You confirm.
- The app does not determine authenticity or appraise value.
- User-confirmed facts outrank AI suggestions.
- Supporting documents help document a record, but do not prove authenticity.
- Your records stay on your device by default.
- If backup is enabled in the shipped release, backup stays in your Google account.

Use MyArtCollection to build a calmer, cleaner record of your collection and keep your paperwork close to the artwork it supports.
```

Release note for this copy:

- Remove the backup sentence if optional Google-account backup is not actually
  enabled in the build being listed.

### Feature and value bullets

Use these as screenshot headlines, listing bullets in internal briefs, and
custom-listing variants:

- Private artwork records
- AI-assisted draft, user-confirmed facts
- Supporting documents with each artwork
- Incomplete queue for missing fields or documents
- Insurance-ready PDF and archive export
- Local-first storage with explicit backup and export controls

### Privacy and trust language

Allowed store-copy themes:

- Private record
- AI-assisted draft
- You confirm the facts
- Supporting documents
- User-provided insurance values
- Export your archive
- Insurance-ready PDF

Banned store-copy themes:

- Authenticity confirmed
- Appraised value
- Verified artist attribution
- Certified provenance
- Official insurance approval
- Fully private or encrypted unless the shipped build and legal copy prove it

## Category and tag recommendation

Recommended Play Console category:

- `App` -> `Art & Design`

Tag recommendation:

- Use the closest available Play tags to these five intents, in this order:
  - art / artwork
  - collection / catalog
  - productivity / organization
  - photo / camera import
  - documents / records

Notes:

- Play allows a maximum of five tags.
- Use exact Play tag names available in Console; do not force inaccurate tags
  for reach.
- Do not classify as Finance, Shopping, or Social.

## ASO and AEO intent map

| User intent | Example query family | What the user wants | Listing answer |
| --- | --- | --- | --- |
| Private art inventory | `art inventory app`, `private art collection app` | A collector-specific record tool | Lead with private records and art-specific organization |
| Insurance prep | `document artwork for insurance`, `art insurance inventory` | Proof-ready documentation workflow | Emphasize documents, completeness, PDF export, user-provided values |
| Fast cataloging | `catalog artwork from photos`, `art collection organizer` | Faster setup than spreadsheets | Emphasize photo intake and AI-assisted drafts |
| Provenance paperwork | `organize art receipts and certificates` | Keep related files with each artwork | Emphasize supporting documents and record completeness |
| Calm utility | `art collection records`, `collection documentation` | Trustworthy, non-hype tooling | Emphasize user confirmation and no fake certainty |

ASO rules:

- Put the art-specific job in the title and first sentence.
- Put the trust model in the first screenful of description.
- Avoid keyword repetition blocks.
- Do not chase valuation, appraisal, or authenticity search traffic with
  misleading copy.

## Screenshot and preview storyboard

### Phone screenshots

Recommendation:

- Ship `6` phone screenshots at launch; reserve `7-8` for later variants.

Storyboard:

1. Intro / onboarding  
   Headline: `Private artwork records`  
   Show: intro screen with `AI drafts. You confirm.`
2. Add artwork  
   Headline: `Start with a photo`  
   Show: add flow with capture/import choices
3. AI draft review  
   Headline: `Review AI-assisted details`  
   Show: suggested fields labeled for confirmation
4. Artwork details  
   Headline: `Confirm the facts yourself`  
   Show: confirmed record with user-reviewed fields
5. Documents  
   Headline: `Keep receipts and certificates together`  
   Show: document attachment screen with supporting-doc language
6. Reports / export  
   Headline: `Export records for insurance conversations`  
   Show: report preview or export surface

Rules:

- Use real app UI from the shipped build only.
- Keep screenshot text minimal and readable.
- Do not show fabricated appraisal values, artist certainty, or authenticity
  claims.
- Do not show personal artwork metadata from real private collections unless the
  images are approved fixtures.

### Large-screen screenshots

Recommendation:

- Do not block first listing prep on tablet or Chromebook creative.
- If large-screen assets are uploaded later, prepare at least `4` screenshots
  and verify the app is visually credible on those form factors first.

### Preview video

Recommendation:

- Optional, not phase-1 required.
- Only produce after the end-to-end flow looks polished on device.

Direction:

- `20-30` seconds
- show capture -> draft review -> document attach -> report/export
- no voiceover needed
- no promises beyond the shipped build
- use an unlisted, ad-free, not-age-restricted YouTube video if uploaded

## Feature graphic and icon direction

### App icon

Direction:

- Quiet premium, not playful.
- Abstract collection or frame motif is acceptable.
- No text in the icon.
- No ribbons, badges, `#1`, `AI`, price callouts, or install symbols.

Required spec:

- `512x512`
- `32-bit PNG`
- max `1024 KB`
- full square asset; let Google Play handle masking and shadow

### Feature graphic

Direction:

- Use a calm, high-contrast composition based on the app UI and art-record
  workflow, not decorative gallery photography alone.
- Center key elements.
- Avoid tiny details, pure white, pure black, and device mockups.
- Prefer one strong frame: artwork thumbnail, record details, and document cue.

Required spec:

- `1024x500`
- JPG or 24-bit PNG
- no alpha

Recommended message:

- `Private artwork records`

Secondary message for internal use only:

- `AI-assisted drafts. You confirm.`

## Store listing experiments

Run experiments only after baseline traffic exists.

Priority order:

1. Icon
2. Screenshots
3. Short description
4. Feature graphic

Initial hypotheses:

- H1: Privacy-first screenshot headlines outperform AI-first headlines for
  install conversion.
- H2: `Art Records` in the title outperforms `Art Inventory` for qualified
  installs.
- H3: Report/export proof beats generic collection-home visuals in screenshot
  set position `#1` or `#2`.
- H4: Document-organization framing increases conversion for insurance and
  estate-prep searchers.

Success metrics:

- install conversion
- retained installer quality once enough data exists
- no increase in policy-review risk or misleading-claim feedback

## Custom store listing segments

Important:

- Google requires a default store listing and a published app before custom
  store listings can be created. Treat these as post-baseline execution work.

Recommended segments:

1. Serious collectors  
   Emphasis: private records, collection overview, faster cataloging
2. Insurance / estate prep  
   Emphasis: supporting documents, completeness, exportable PDF
3. Provenance / paperwork organization  
   Emphasis: receipts, certificates, appraisals, notes in one record
4. Privacy-first inventory  
   Emphasis: local-first record, explicit backup/export controls

Recommended keyword or audience targeting once available:

- art inventory / art collection app
- document artwork for insurance
- organize art receipts
- private collection records

Do not create a custom listing around:

- AI appraisal
- authenticity checking
- market value tracking

## Policy and trust guardrails

1. Metadata must stay descriptive, relevant, and non-repetitive.
2. Do not use ranking, award, promotional, or pricing claims in title,
   screenshots, icon, feature graphic, or short description.
3. All listing assets must match actual app behavior.
4. Store listing text and assets must remain suitable for a general audience.
5. If the release uses AI-generated output, the app still needs reviewable
   feedback and safety handling consistent with Google Play AI policy.
6. Data safety answers must match actual collection, sharing, and protection
   practices in the shipped build.
7. If the app requests sensitive permissions or data, a real privacy-policy URL
   is a release gate.
8. If the Play developer account is a new personal account created after
   November 13, 2023, production launch is gated by the `12 testers / 14 days`
   closed-test requirement.

## Acceptance checks

- A final title, short description, and full description exist and fit Play
  limits.
- The listing clearly describes MyArtCollection as a private art-record app.
- The listing does not claim authenticity, appraisal certainty, unsupported AI,
  or stronger privacy than implemented.
- The screenshot shot list maps to real screens already defined in repo docs and
  app routes.
- Icon, feature graphic, screenshot, and preview-video requirements are
  documented.
- Custom listing opportunities and experiment hypotheses are documented without
  implying they should ship before the default listing exists.
- Data safety, privacy-policy, and account-testing gates are called out as
  follow-up requirements before submission.

## Task breakdown

### Ready for codex-task-work

1. Create fixture-safe artwork metadata and documents for store screenshots.
2. Capture real phone screenshots from the shipped build that match the
   storyboard.
3. Design icon and feature-graphic variants against the specs above.
4. Draft a public privacy-policy page and URL that matches actual shipped data
   behavior.
5. Prepare a Play Data safety worksheet from the repo telemetry and storage
   docs.
6. Set the Play category and exact tags in Console once the app exists there.

### Needs codex-visual-review

1. Verify screenshot readability on phone-sized assets.
2. Verify any later large-screen screenshot set against actual tablet layouts.
3. Review icon and feature graphic for misleading elements, cutoff risk, and
   readability.

### Needs codex-redteam-review

1. Review privacy-policy and Data safety answers against actual telemetry and
   storage behavior before submission.
2. Review listing copy for accidental overclaim around AI, privacy, insurance,
   provenance, and valuation.

### Needs codex-deployment-manager

1. Track Play Console gating items before any beta/public submission:
   privacy-policy URL, Data safety, target audience, content rating, and
   personal-account testing gate if applicable.

## Open decisions for humans

1. Final title choice:
   `MyArtCollection: Art Records` vs `MyArtCollection: Art Inventory`.
2. Whether the first public-facing listing should mention backup at all, based
   on the exact shipped beta scope.
3. Whether the first experiment should test title wording or screenshot order.
4. Whether large-screen screenshots should wait until tablet-specific polish is
   complete.

## Primary sources

- Google Play store setup and limits:
  https://support.google.com/googleplay/android-developer/answer/9859152
- Preview assets requirements:
  https://support.google.com/googleplay/android-developer/answer/9866151
- Store listing best practices:
  https://support.google.com/googleplay/android-developer/answer/13393723
- Metadata policy:
  https://support.google.com/googleplay/android-developer/answer/9898842
- Data safety:
  https://support.google.com/googleplay/android-developer/answer/10787469
- Custom store listings:
  https://support.google.com/googleplay/android-developer/answer/9867158
- Store listing experiments:
  https://developer.android.com/distribute/users/experiments.html
- Google Play icon spec:
  https://developer.android.com/distribute/google-play/resources/icon-design-specifications
- AI-generated content policy:
  https://support.google.com/googleplay/android-developer/answer/13985936
- AI-generated content overview:
  https://support.google.com/googleplay/android-developer/answer/14094294
- New personal-account testing requirement:
  https://support.google.com/googleplay/android-developer/answer/14151465
- App review and privacy-policy guidance:
  https://support.google.com/googleplay/android-developer/answer/9859455
