# AI Artwork Research Spec

## Problem

Archivale needs to move from fixture-backed AI language to a real
AI-assisted intake loop. The feature should help a collector identify candidate
artist, title, year, medium, subject, and source-backed comparable value signals
from a photo and optional local user notes, while preserving the product rule
that AI suggests and the user confirms.

The user goal is not automatic authentication or appraisal. The useful job is:

> Research likely matches from professional art sources, show the evidence, and
> let the collector decide what belongs in their private record.

## Current Product Constraints

- Private by default and local-first.
- AI suggestions are drafts until the user confirms them.
- User-confirmed facts outrank AI output and document extraction.
- Unknown is better than unsupported certainty.
- No authenticity, attribution certainty, certification, appraisal certainty,
  or market-value claims.
- Online research must be explicit and reviewable, because artwork photos and
  collection data can be sensitive.

## External Evidence

- Android supports on-device generative AI through ML Kit GenAI APIs powered by
  Gemini Nano and AICore. The Prompt API supports text plus image input and text
  output on supported devices.
- Google AI Edge / LiteRT-LM is a lower-level on-device model path for custom
  models, but it is heavier than the ML Kit Prompt API for this MVP.
- On-device AI cannot search live websites by itself. Internet research needs a
  network service or API layer.
- A user's consumer Google AI Pro / Gemini subscription should not be treated
  as the app's compute entitlement for Archivale. It raises access or
  usage limits inside Google's Gemini surfaces, while Gemini API usage is
  managed through API keys, tiers, billing, and Google Cloud projects. Treat
  bring-your-own-key as a possible advanced/admin option later, not the default
  MVP path.
- OpenAI's Responses API supports web search as a tool, but broad web search is
  too loose for this product unless it is constrained by allowlist, source
  classification, citations, and post-processing.
- Google's Custom Search Site Restricted JSON API is no longer a suitable new
  default because Google states that it stopped serving traffic on January 8,
  2025. Treat it as historical context only and evaluate Vertex AI Search /
  Agent Search or source-specific APIs instead.
- Firebase App Distribution is suitable for Android beta delivery to trusted
  testers, but it should be treated as a distribution layer before any broader
  Firebase data-platform decision.
- Professional public collection APIs exist for museum and cultural heritage
  metadata, including The Met Collection API, Art Institute of Chicago API,
  Harvard Art Museums API, and Europeana APIs.

References:

- https://developer.android.com/ai/gemini-nano
- https://developers.google.com/ml-kit/genai
- https://developers.google.com/ml-kit/genai/prompt/android
- https://one.google.com/about/google-ai-plans/
- https://ai.google.dev/gemini-api/docs/billing
- https://developers.google.com/edge
- https://developers.openai.com/api/docs/guides/tools-web-search
- https://developers.google.com/custom-search/v1/site_restricted_api
- https://docs.cloud.google.com/generative-ai-app-builder/docs/migrate-from-cse
- https://firebase.google.com/docs/app-distribution
- https://metmuseum.github.io/
- https://api.artic.edu/
- https://harvardartmuseums.org/collections/api
- https://api.europeana.eu/

## Recommendation

Use a hybrid architecture:

1. On-device first pass on Android using ML Kit GenAI Prompt API where
   available.
2. Explicit user-approved online research through a server-side research
   service.
3. Professional-source allowlist for search and collection APIs.
4. Source-backed candidate records with citations, not a single confident
   answer.
5. User review before any researched field becomes part of the artwork record.

This is the safest path because it keeps the private first pass local, avoids
shipping API keys in the mobile app, lets us enforce source allowlists centrally,
and gives us room to add licensing or paid source providers later.

For distribution, use Firebase App Distribution for Android beta delivery. Keep
Firebase as the tester distribution and crash-feedback layer first; add Firebase
Auth, Firestore, Storage, or Functions only behind explicit local-first/privacy
decisions so the app does not drift into cloud-first record storage by accident.

## Non-Goals

- No automatic authenticity determination.
- No app-certified appraisal or market valuation.
- No undisclosed scraping, paywall bypassing, or terms-of-service violations.
- No broad internet search from the client.
- No background online research without an explicit user action.
- No autonomous public posting or outreach.
- No production AI vendor integration without redteam review and credential
  handling.

## Requirements

### Monetization

AI research is a monetization opportunity, but the product should charge for
workflow value and professional-source evidence, not for unsupported certainty.

Potential paid value:

- deeper professional-source research after the free/on-device draft,
- saved source-citation packs for insurance, resale, estate, or appraisal
  conversations,
- comparable sale/estimate signal history when terms permit,
- multi-source research refreshes when a user adds documents or better photos,
- exportable research appendix attached to a PDF/archive,
- optional concierge or partner appraisal handoff once the user wants a human
  expert.

Free tier should probably include:

- local/on-device draft when supported,
- manual record creation,
- limited online research previews with strict source labels.

Paid tier candidates:

- monthly research credits,
- unlimited professional-source searches,
- saved citation history,
- comparable signal tracking,
- report/export appendices,
- higher limits for images/documents and collection size.

Future partner revenue:

- referral flow to vetted appraisers, conservators, insurers, framers, or
  collection-management experts,
- affiliate/partner relationships only with clear disclosure and no pressure on
  the record workflow,
- premium licensed-source integrations if source terms allow redistribution or
  display.

Monetization guardrails:

- Never sell "AI valuation" as if it were an appraisal.
- Do not gate export of user-owned records in a way that feels like hostage
  taking.
- Do not bias research candidates toward paid partners.
- Keep partner/referral actions separate from AI field confirmation.
- Make source/provider costs visible in product economics before promising
  unlimited live research.

### User Consent And Privacy

- The default import path may run on-device AI when supported.
- Online research must require a visible user action such as `Research online`.
- For v1 broker payload minimization, `docs/AI_BROKER_PAYLOAD_AND_TELEMETRY_SPEC.md`
  is the authoritative override for what may leave the device.
- Before the first online research request, the UI must explain the v1 broker
  payload in that spec:
  - selected image derivative,
  - only allowlisted structured hint fields after sanitization and mapping,
  - no raw notes, no free-text draft summaries, and no broad current-draft
    export.
- The user must be able to skip online research and still create a record.
- The app must not send the entire local collection for one-artwork research.
- Store research job metadata locally with source URLs and timestamps.

### On-Device Drafting

Use on-device AI for:

- visual description,
- visible signature transcription attempt,
- subject matter,
- medium/material hints,
- style or period hints,
- condition/frame/glass/mounting observations,
- candidate search terms for online research.

On-device output must map to `AI-suggested` or `unknown`, never
`user-confirmed`.

### Professional-Source Online Research

The server-side research service should query only allowed professional sources:

- museum and cultural heritage collection APIs,
- official artist/gallery/foundation/cultural institution pages after allowlist
  approval,
- reputable auction-house or price-database APIs/pages only when terms permit
  our use case,
- configured site-restricted search providers.

The first allowlist should start conservative:

- `metmuseum.org` / Met Collection API,
- `artic.edu` / Art Institute of Chicago API,
- `harvardartmuseums.org` / Harvard Art Museums API,
- `europeana.eu` / Europeana APIs,
- `getty.edu` vocabulary and research pages when useful,
- selected major auction houses only after terms review.

The service must return candidates with:

- source name,
- source URL or API object id,
- title,
- artist,
- year/date,
- medium,
- dimensions when present,
- image URL/thumbnail when terms permit,
- match reasons,
- fields matched,
- fields missing,
- confidence language bucket: `possible`, `likely`, `insufficient evidence`,
- raw evidence snippets capped and stored only when permitted.

### Comparable Value Handling

Value output is the highest-risk part. It must be framed as source-backed
comparables, not the value of the user's artwork.

Allowed labels:

- `Comparable sale signal`
- `Public estimate found`
- `User-provided insurance value`
- `Needs expert appraisal`
- `No reliable comparable found`

Disallowed labels:

- `Market value`
- `Appraised at`
- `Worth`
- `Certified value`
- `Authentic value`

Value comparable records should store:

- source,
- URL,
- sale/estimate date when available,
- currency,
- estimate range or hammer price when permitted,
- whether the value is public, licensed, or user-entered,
- caveat text: comparable data may not apply to this artwork.

## Architecture

### Mobile App

- `AiDraftService` interface.
- `OnDeviceAiDraftService` Android implementation via platform channel.
- `StubAiDraftService` fallback for unsupported platforms/devices and tests.
- `OnlineResearchClient` interface for server requests.
- `ResearchConsentScreen` or modal before first network research.
- Draft review UI extended with source-backed candidates and citations.

### Android Native Layer

- Kotlin bridge for ML Kit GenAI Prompt API.
- Feature availability check:
  - available,
  - downloadable,
  - unavailable.
- Clear fallback messaging when on-device AI is unavailable.
- Timeout and cancellation handling.

### Server Research Service

Keep API keys and source integrations off-device.

Endpoints:

- `POST /research/artwork`
- `GET /research/jobs/{id}`
- `POST /research/jobs/{id}/cancel`

Input:

- a dedicated broker request DTO defined by
  `docs/AI_BROKER_PAYLOAD_AND_TELEMETRY_SPEC.md`,
- no raw `artwork draft id`, `user-entered notes`, `consentSummary`, or
  `querySummary` fields in the v1 network payload,
- user-approved image derivative and allowlisted structured hints only,
- locale/currency preferences through the broker's allowed client-context
  fields.

Output:

- candidate matches,
- source hits,
- comparable value signals,
- source errors,
- review-required fields,
- terms/citation metadata.

### Data Model Additions

Add local entities:

- `AiDraftJob`
- `ResearchJob`
- `ResearchSourceHit`
- `CandidateAttribution`
- `ComparableValueSignal`

All user-visible researched fields remain regular artwork field values with
source state `AI-suggested`, `document-extracted`, or `unknown` until the user
confirms them.

## Options Considered

### Option A: On-Device Only

Pros:

- Best privacy.
- Works offline on supported devices.
- No server/API cost.

Cons:

- Cannot search professional sources.
- Weak for artist/title/year identification.
- No source citations or comparable records.

Decision: Use only for the private first pass.

### Option B: External Multimodal API Only

Pros:

- Faster to prototype.
- Stronger image understanding and structured output.

Cons:

- Sends artwork images off-device by default.
- Does not solve professional-source allowlisting by itself.
- API keys and terms must be handled carefully.

Decision: Not the default path, but can be used inside the server service after
consent and redteam.

### Option C: Hybrid On-Device Plus Server Research

Pros:

- Private first pass.
- Professional source citations.
- Central allowlist and API key control.
- Best fit for trust rules.

Cons:

- More moving parts.
- Requires backend and source-provider decisions.
- Live AI/search cannot be fully tested without credentials.

Decision: Recommended.

## Acceptance Checks

- A supported Pixel can produce an on-device AI draft or a graceful unsupported
  fallback without network access.
- The user can explicitly start online research and see what data will be sent.
- Research results show multiple candidates with source links, not a single
  asserted attribution.
- Candidate fields remain `AI-suggested` or `unknown` until user confirmation.
- The app can show `No reliable comparable found` without blocking the record.
- Comparable values are labeled as source-backed comparables or user-provided
  values, never as app-certified valuation.
- API keys are not embedded in the mobile app.
- Source allowlist is enforced server-side and covered by tests.
- Redteam review accepts privacy, valuation, and source-use guardrails before
  public or production use.

## Task Breakdown

1. Research/spec AI artwork identification and professional-source search.
2. Add AI research domain models and local job persistence.
3. Add Android on-device AI draft provider behind a feature flag.
4. Add stub/mock online research service and source-citation UI.
5. Build server-side professional-source search prototype with allowlist.
6. Add comparable-value guardrails and source-backed display.
7. Redteam privacy, valuation, attribution, and source-use risks.
8. Replace stub with production credentials only after explicit credential and
   deployment approval.

## Human Decisions Needed Later

- Which live search provider to pay for or provision.
- Which professional/auction sources are allowed after terms review.
- Whether artwork photos may be uploaded to a server for online research.
- Whether rough comparable values are in MVP or a later paid feature.
- Which default locale/currency set should be paired with localization work.
