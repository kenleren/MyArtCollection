# Google Play Listing Prep

Issue: #53  
Project: https://github.com/users/kenleren/projects/1  
Scheduling evidence: https://github.com/kenleren/MyArtCollection/issues/53#issuecomment-4883635998

## Problem statement

Prepare a decision-ready Google Play listing package for Archivale before
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
   documents, and review workflow.
2. Keep all AI language out of the default listing unless the shipped build
   actually exposes that feature to users.
3. If a shipped build includes off-device AI, disclose it in plain language:
   AI suggestions require an explicit user action and upload only the selected
   content needed for that request to the app AI service.
4. Keep privacy language factual:
   - local-first by default
   - optional Google-account backup only when that shipped behavior exists in
     the release being listed
   - delete/disconnect controls only when those controls exist in the shipped
     release
   - export/report language only when generation, sharing, or save flows are
     actually usable in the shipped release
5. Treat privacy-policy URL, Play Data safety worksheet, and SDK/track review
   as unconditional submission gates before any open, closed, or production
   Play track is used.
6. No Play Console asset upload until human approval is recorded, external
   marketing review is complete, and screenshots/graphics have been reviewed
   against the exact release candidate build.
7. Experiments and custom store listings must not vary privacy, AI-processing,
   backup, authenticity, appraisal, insurance-value, or similar trust claims
   unless the claim is true for every distributed build under the package.
8. Use phone-first creative. Add large-screen assets only after real
   large-screen layouts are verified.
9. Treat Data safety answers and the privacy-policy URL as release gates, not
   copy afterthoughts.

## Options considered

| Decision | Option | Pros | Risks | Recommendation |
| --- | --- | --- | --- | --- |
| App title | `Archivale` | Clean, distinctive brand | Needs a descriptor for first-glance store understanding | No |
| App title | `Archivale: Art Records` | Brand plus clear function inside 30 chars | Slightly less elegant brand presentation | Yes |
| App title | `Archivale: Art Inventory` | Strong search intent | "Inventory" can read generic or household-focused | Backup option |
| Category | `Art & Design` | Best matches art-specific discovery and collector intent | Slightly less obviously utilitarian | Yes |
| Category | `Productivity` | Signals utility and organization | Loses art-specific relevance | No |
| Listing emphasis | AI-first | Curiosity and demos | Attracts appraisal / identification expectations | No |
| Listing emphasis | privacy + records + documents | Best match to current shipped-safe truth | Slightly less flashy | Yes |

Recommendation could be wrong if beta evidence shows users primarily search for
generic home-inventory language rather than art-specific record language.

## Recommended main listing package

### App name guidance

Recommended:

- `Archivale: Art Records`

Fallback:

- `Archivale: Art Inventory`

Rule:

- Do not append ranking claims, pricing words, or AI buzzwords to the title.

### Short description draft

Recommended draft:

- `Private artwork records with photos, notes, and documents`

Why:

- Fits the `80`-character limit.
- States the job clearly.
- Avoids appraisal/authenticity/privacy overclaim.
- Avoids promising AI or export behavior that the shipped build may not expose.

### Full description draft

Recommended draft:

```text
Keep your artwork records private, organized, and easier to trust.

Archivale helps serious hobby collectors turn photos, receipts, certificates, appraisals, and notes into clean artwork records without building a spreadsheet or hiring a registrar.

How it works:
- Add an artwork from a photo or import
- Review the record details yourself
- Attach supporting documents
- Track what still needs review

Built for collectors who want:
- A private record of what they own
- Faster cataloging for small to mid-size collections
- Better document organization for insurance, moving, estate, or appraisal conversations

Trust and privacy:
- The app does not determine authenticity or appraise value.
- Supporting documents help document a record, but do not prove authenticity.
- Your records stay on your device by default.

Use Archivale to build a calmer, cleaner record of your collection and keep your paperwork close to the artwork it supports.
```

Release note for this copy:

- This default listing copy is the shipped-safe baseline while AI, backup, and
  export/report flows remain absent, preview-only, or otherwise not user-usable
  in the listed build.

### Future-gated copy blocks

These lines are optional and may be used only when the exact shipped release
supports them:

- AI-enabled build add-on:
  - `AI suggestions are optional. When you choose an AI action, the app sends only the selected content for that request to the app AI service.`
- Backup-enabled build add-on:
  - `If backup is enabled in the shipped release, backup stays in your Google account.`
- Export/report-enabled build add-on:
  - `If export or report generation ships in the listed build, describe only the exact generated output and avoid insurance-ready or proof-ready language unless the flow is truly available.`

### Feature and value bullets

Use these as screenshot headlines, listing bullets in internal briefs, and
custom-listing variants for the default listing:

- Private artwork records
- Photo-first record setup
- Supporting documents with each artwork
- Incomplete queue for missing fields or documents
- Local-first storage on your device by default

Future-gated bullets for AI/export/backups:

- AI-assisted draft, user-confirmed facts
- Export/report generation available in this build
- Backup available in this build

### Privacy and trust language

Allowed store-copy themes:

- Private record
- You confirm the facts
- Supporting documents
- User-provided insurance values
- On-device by default

Allowed only when the shipped build supports them:

- AI-assisted draft
- Export your archive
- Generate a PDF report
- Backup in your Google account

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
| Insurance prep | `document artwork for insurance`, `art insurance inventory` | Documentation workflow for later conversations | Emphasize documents, completeness, and user-provided values without promising reports or PDFs unless shipped |
| Fast cataloging | `catalog artwork from photos`, `art collection organizer` | Faster setup than spreadsheets | Emphasize photo intake and record review; add AI wording only if the listed build exposes it |
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
   Show: intro screen without unshipped AI, backup, or export claims
2. Add artwork
   Headline: `Start with a photo`
   Show: add flow with capture/import choices
3. Artwork details
   Headline: `Confirm the facts yourself`
   Show: confirmed record with user-reviewed fields
4. Documents
   Headline: `Keep receipts and certificates together`
   Show: document attachment screen with supporting-doc language
5. Review queue
   Headline: `See what still needs review`
   Show: needs-review list or record completeness cues
6. Privacy / storage
   Headline: `Stored on your device by default`
   Show: a real shipped settings or trust surface only if it exists in the
   release candidate

Rules:

- Use real app UI from the shipped build only.
- Keep screenshot text minimal and readable.
- Do not show fabricated appraisal values, artist certainty, or authenticity
  claims.
- Do not show preview-only AI, backup, export, or PDF surfaces in public
  listing assets.
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
- show capture -> record review -> document attach
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

- `Review and organize your records`

## Store listing experiments

Run experiments only after baseline traffic exists and the trust-claim parity
rule below is satisfied.

Priority order:

1. Icon
2. Screenshots
3. Short description
4. Feature graphic

Initial hypotheses:

- H1: Privacy-first screenshot headlines outperform review-workflow headlines for
  install conversion.
- H2: `Art Records` in the title outperforms `Art Inventory` for qualified
  installs.
- H3: Documents-plus-review proof beats generic collection-home visuals in
  screenshot set position `#1` or `#2`.
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
   Emphasis: supporting documents, completeness, and user-provided values
3. Provenance / paperwork organization  
   Emphasis: receipts, certificates, appraisals, notes in one record
4. Privacy-first inventory  
   Emphasis: local-first record and calm review workflow

Recommended keyword or audience targeting once available:

- art inventory / art collection app
- document artwork for insurance
- organize art receipts
- private collection records

Do not create a custom listing around:

- AI appraisal
- authenticity checking
- market value tracking

Trust-claim parity rule:

- Experiments and custom listings may vary positioning, ordering, or visuals,
  but may not vary privacy, AI-processing, backup, authenticity, appraisal,
  insurance-value, exportability, or similar trust claims unless those claims
  are true for every build distributed under the package.

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
7. A real privacy-policy URL is a release gate before any open, closed, or
   production Play submission.
8. If the Play developer account is a new personal account created after
   November 13, 2023, production launch is gated by the `12 testers / 14 days`
   closed-test requirement.
9. Complete a Data safety worksheet and SDK/track review before any open,
   closed, or production Play submission.
10. Do not upload Play listing assets until human approval is recorded,
   external marketing review is complete, and screenshots/graphics have been
   reviewed against the exact release candidate.
11. A Play-ready Android release requires owner-held upload-key decisions,
    secret storage outside the repository, and sanitized signed-AAB verification
    from the configured release-signing path before any Play track upload.

## Acceptance checks

- A final title, short description, and full description exist and fit Play
  limits.
- The listing clearly describes Archivale as a private art-record app.
- The listing does not claim authenticity, appraisal certainty, unsupported AI,
  unsupported export/PDF/report capability, or stronger privacy than
  implemented.
- The screenshot shot list maps to real screens already defined in repo docs and
  app routes, and excludes preview-only surfaces from public assets.
- Icon, feature graphic, screenshot, and preview-video requirements are
  documented.
- Custom listing opportunities and experiment hypotheses are documented without
  implying they should ship before the default listing exists.
- Data safety, privacy-policy, SDK/track review, human approval, and
  release-candidate asset review are called out as mandatory gates before any
  Play submission or asset upload.
- Owner-held upload-key decisions, out-of-repo signing secrets, and sanitized
  signed-AAB verification are called out as mandatory gates before any Play
  track upload.

## Task breakdown

### Ready for codex-task-work

1. Create fixture-safe artwork metadata and documents for store screenshots.
2. Capture real phone screenshots from the shipped build that match the
   storyboard and exclude preview-only AI/export/report screens.
3. Design icon and feature-graphic variants against the specs above.
4. Draft a public privacy-policy page and URL that matches actual shipped data
   behavior.
5. Prepare a Play Data safety worksheet from the repo telemetry and storage
   docs.
6. Complete SDK/track review and confirm which claims are true in the release
   candidate before any asset upload.
7. Set the Play category and exact tags in Console once the app exists there.

### Needs codex-visual-review

1. Verify screenshot readability on phone-sized assets.
2. Verify any later large-screen screenshot set against actual tablet layouts.
3. Review icon and feature graphic for misleading elements, cutoff risk, and
   readability.

### Needs codex-redteam-review

1. Review privacy-policy and Data safety answers against actual telemetry and
   storage behavior before submission.
2. Review listing copy for accidental overclaim around AI, privacy, insurance,
   provenance, valuation, export, and report/PDF capability.

### Needs codex-deployment-manager

1. Track Play Console gating items before any beta/public submission:
   privacy-policy URL, Data safety, SDK/track review, target audience, content
   rating, human approval, release-candidate asset review, personal-account
   testing gate if applicable, and the first owner-run signed-AAB verification.

## Open decisions for humans

1. Final title choice:
   `Archivale: Art Records` vs `Archivale: Art Inventory`.
2. Whether any AI, backup, export, or PDF wording becomes eligible for the
   first public-facing listing, based on the exact shipped beta scope.
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
