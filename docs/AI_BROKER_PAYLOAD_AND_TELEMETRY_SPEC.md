# AI Broker Payload And Telemetry Spec

Status: Proposed
Issue: [#51](https://github.com/kenleren/MyArtCollection/issues/51)
Parent: [#42](https://github.com/kenleren/MyArtCollection/issues/42)
Related docs:
- [Architecture Plan](ARCHITECTURE.md)
- [AI Artwork Research Spec](AI_ART_RESEARCH_SPEC.md)
- [Costed AI Backend Gate Spec](COSTED_AI_BACKEND_GATE_SPEC.md)
- [AI Broker Auth And Quota Spec](AI_BROKER_AUTH_AND_QUOTA_SPEC.md)
- [Firebase Telemetry Privacy Policy](FIREBASE_TELEMETRY_POLICY.md)

## Problem statement

MyArtCollection needs a broker request/response contract before any paid AI
research path exists. The first approved provider path from [#42](https://github.com/kenleren/MyArtCollection/issues/42)
is a thin Firebase-hosted broker that calls OpenAI Responses API hosted
`web_search` with `gpt-5.4` and high reasoning by default. Before that can be
implemented, the repo needs a precise answer to seven questions:

- what is the smallest payload allowed to leave the device,
- which request fields are explicitly banned from leaving the device,
- what normalized response shape the app may trust,
- how citations and uncertainty are represented without overclaiming,
- what operational telemetry is allowed,
- what must never be logged or sent to Firebase telemetry,
- and what retention/deletion behavior is mandatory on both broker-owned state
  and OpenAI request settings.

This spec is intentionally about contract, minimization, and observability
boundaries only. Auth, quota, replay protection, and kill switch topology stay
in [AI Broker Auth And Quota Spec](AI_BROKER_AUTH_AND_QUOTA_SPEC.md) and
[#49](https://github.com/kenleren/MyArtCollection/issues/49). Provider
data-handling, Zero Data Retention eligibility, and source-rights review stay
in [#52](https://github.com/kenleren/MyArtCollection/issues/52).

## Context and evidence

### Repo-local evidence

- [Architecture Plan](ARCHITECTURE.md) says AI uploads must be explicit and
  minimal, AI must never be a direct vendor call from the app, and long-term AI
  payload retention is not allowed unless explicitly disclosed and justified.
- [Firebase Telemetry Privacy Policy](FIREBASE_TELEMETRY_POLICY.md) bans AI
  prompts, AI responses, source snippets, citations, research queries, source
  URLs, filenames, paths, and secrets from Firebase-bound telemetry.
- [AI Artwork Research Spec](AI_ART_RESEARCH_SPEC.md) requires source-backed
  candidates, explicit user review, confidence buckets, professional-source
  allowlists, and no authenticity/appraisal certainty claims.
- [AI Broker Auth And Quota Spec](AI_BROKER_AUTH_AND_QUOTA_SPEC.md) already
  assumes this issue will define the final request envelope, idempotency payload
  hash input, and log-safety rules before any provider call is allowed.
- Current local code in
  [lib/app/research/online_research_service.dart](/Users/kenleren/Private/Ken/MyArtCollection/lib/app/research/online_research_service.dart)
  and
  [lib/app/storage/ai_research_record.dart](/Users/kenleren/Private/Ken/MyArtCollection/lib/app/storage/ai_research_record.dart)
  already models:
  - explicit consent summary,
  - query summary,
  - professional-source allowlists,
  - confidence buckets,
  - source-backed candidate attributions,
  - and comparable-value caveats.

### Current vendor facts that shape this contract

- OpenAI's current latest-model page recommends `gpt-5.5` for new projects, but
  this repo deliberately keeps `gpt-5.4` as the first paid art-research default
  by product decision from [#42](https://github.com/kenleren/MyArtCollection/issues/42).
- OpenAI's web search guide says Responses API web-search output includes
  `web_search_call` items plus a `message` output item whose
  `message.content[0].annotations` contain cited URLs. It also requires inline
  citations to be clearly visible and clickable in end-user UI.
- OpenAI's reasoning guide says `high` reasoning is appropriate for complex
  workflows and long-horizon research, while `medium` and `high` should both be
  evaluated depending on task complexity.
- OpenAI's data-controls guide says `/v1/responses` retains application state
  for 30 days by default or when `store=true`, and says no data is retained for
  server-side compaction when `store="false"`.
- Structured Outputs can enforce a JSON Schema response contract, which is a
  better fit than free-form narrative for broker-to-app transport.

Primary sources:

- OpenAI latest model guidance:
  <https://developers.openai.com/api/docs/guides/latest-model>
- OpenAI web search output/citations:
  <https://developers.openai.com/api/docs/guides/tools-web-search#output-and-citations>
- OpenAI reasoning effort guidance:
  <https://developers.openai.com/api/docs/guides/reasoning#reasoning-effort>
- OpenAI data controls for `/v1/responses`:
  <https://developers.openai.com/api/docs/guides/your-data#v1responses>
- OpenAI Structured Outputs guide:
  <https://developers.openai.com/api/docs/guides/structured-outputs>

### Inference from the vendor docs

The vendor docs do not define MyArtCollection's exact application schema. They
do establish that OpenAI can return citation annotations and can enforce a
schema-constrained output. From that, this spec recommends a two-layer broker
contract:

1. provider response handling that preserves citation metadata from web search,
2. broker-normalized JSON returned to the app under a strict schema.

## Non-goals

- No paid broker implementation in this issue.
- No approval for direct mobile vendor calls.
- No approval for raw user notes, full artwork records, full documents, or
  collection-wide context to be sent by default.
- No approval for Firebase Analytics, Firebase Performance, custom Crashlytics
  keys, or custom Crashlytics logs for broker traffic.
- No decision here on OpenAI Zero Data Retention eligibility, organization
  settings, enterprise contract terms, or broader source-rights review. Those
  remain release blockers in [#52](https://github.com/kenleren/MyArtCollection/issues/52).
- No Android build config work and no l10n work.

## Requirements

Any approved broker implementation must satisfy all of the following:

- The mobile app sends only per-request minimum data for one artwork research
  job.
- The network contract must not include the local artwork record ID unless a
  later spec proves it is required. The app should map broker requests back to
  artworks locally.
- Raw user notes are banned from the v1 broker payload.
- Full local record exports, document bodies, PDF bodies, filenames,
  attachment/storage paths, EXIF dumps, checksums, collection summaries,
  current location, acquisition details, valuation history, contacts, and all
  secrets are banned from the broker payload.
- One request must correspond to one explicit user-approved research action.
- The broker must call OpenAI with `store=false` on every Responses request.
- The broker must not use background mode, remote MCP tools, file search, or
  any third-party network tool in the first paid art-research path.
- Broker-to-app responses must be schema-validated before the app trusts them.
- Every user-visible researched claim must carry visible source attribution and
  a confidence/uncertainty bucket.
- Operational telemetry must be content-free and fixed-vocabulary only.
- Firebase-bound telemetry must not contain prompts, responses, source URLs,
  citation titles, snippets, image data, or any other user/content-derived
  fields.
- Broker-owned transient data must be deleted after request completion or
  terminal failure, except for explicitly allowed derived identifiers and
  short-lived replay/idempotency state from [#50](https://github.com/kenleren/MyArtCollection/issues/50).

## Options considered

| Option | Summary | Pros | Cons | Outcome |
| --- | --- | --- | --- | --- |
| A. Send full artwork draft plus raw notes plus selected image | Maximize provider context | Highest match chance in some ambiguous cases | Violates minimization posture, expands privacy surface, increases logging risk, over-sends data irrelevant to source search | Reject |
| B. Send minimal image derivative plus structured search hints only | Strong minimization and easier redaction | Best fit for local-first/privacy posture, easier telemetry guarantees, lower accidental leakage | May miss useful nuance from long user notes | Recommended first path |
| C. Send raw user notes only after explicit consent | More recall than structured hints | Sometimes helpful for niche artist or inscription details | Free text is hard to sanitize, can leak names/locations/purchase history, and increases prompt/log redaction burden | Defer unless a later task proves material quality gain |
| D. Let the broker return free-form narrative and parse it later | Simplest first implementation | Fastest to prototype | Fragile parsing, weaker guarantees, harder redteam surface | Reject |

## Recommended approach

Decision:

1. Approve Option B as the only v1 broker payload contract.
2. Keep raw free-text notes out of the provider payload in v1.
3. Require strict broker-side schema validation and strict source allowlist
   validation before any result is stored locally or shown in UI.

### Why this is the right first contract

- It narrows what leaves the device more aggressively than the broader
  "selected image + notes + draft fields" wording in older research planning.
- It reduces the number of places where forbidden content could leak into logs,
  crash traces, or Firebase telemetry.
- It keeps the response aligned with the app's actual needs: candidates,
  source-backed evidence, uncertainty, caveats, and comparable-value guardrails
  instead of a prose answer.

### What would make this recommendation wrong

Revisit this contract if measured evals show that banning raw note text causes a
material quality failure that cannot be recovered with better on-device hint
extraction, image preprocessing, or more precise allowlists. Even then, the
next step should be a narrowly capped note-summary field, not unrestricted raw
notes by default.

## Request contract

### Broker request envelope

The app-facing broker request should be a dedicated network envelope, not the
same object as the local `OnlineResearchRequest`.

Required top-level fields:

| Field | Type | Purpose | May leave device |
| --- | --- | --- | --- |
| `request_id` | UUID string | Client-generated idempotency handle from [#50](https://github.com/kenleren/MyArtCollection/issues/50) | Yes |
| `consent_scope` | enum | Fixed enum describing what the user approved for this request | Yes |
| `image` | object | User-selected research image derivative | Yes |
| `draft_hints` | object | Minimal structured hints used for disambiguation | Yes |
| `client_context` | object | Non-content operational hints such as locale | Yes |

Allowed `consent_scope` values:

- `image_only`
- `image_plus_draft_hints`

No v1 consent scope may authorize raw note text.

### Allowed image payload

Allowed image object:

- one user-selected artwork image only,
- JPEG or WebP only,
- preprocessed client-side to remove unnecessary metadata,
- no EXIF payload forwarded,
- max 1600 px long edge,
- max 1.5 MB encoded size,
- optional second derived crop only for visible signature/mark details if the
  user explicitly selected it in the same request,
- no unrelated room/context photos,
- no document scans in v1.

Disallowed image inputs:

- original full-resolution binaries when the downscaled derivative is
  sufficient,
- multiple gallery-roll images,
- local attachment paths,
- exported ZIP/PDF/document files,
- checksums or filesystem-derived identifiers.

### Allowed structured draft hints

Allowed `draft_hints` fields are optional and must be omitted when empty:

- `title_hint`
- `artist_hint`
- `year_hint`
- `medium_hint`
- `dimensions_hint`
- `signature_text_hint`
- `visual_summary_hint`
- `search_terms` as a short list of locally derived tokens

Rules:

- Each hint must be capped to a short fixed length.
- Hints must describe only the single artwork under review.
- `search_terms` must be token-like phrases, not raw copied notes.
- `visual_summary_hint` should be an on-device summary, not raw user prose.

Explicitly banned from `draft_hints`:

- raw notes,
- provenance notes,
- purchase/sale/insurance values,
- location names,
- seller/buyer/gallery contact information,
- filenames, paths, hashes, or device identifiers,
- entire OCR dumps from documents,
- collection-wide summaries or multiple-artwork context.

### Allowed client context

Allowed `client_context` fields:

- `app_language`
- `country_hint` when needed for source/result localization
- `requested_source_profile` as a fixed enum such as
  `museum_only` or `museum_plus_auction_when_allowed`

Disallowed client context:

- timezone history,
- precise GPS or room location,
- stable device fingerprint,
- tester email,
- raw UID,
- raw Firebase/App Check tokens inside the request body,
- route names or local record IDs.

## Provider request rules

For the first paid OpenAI path, the broker request to OpenAI must:

- use Responses API,
- use model `gpt-5.4`,
- set `reasoning.effort=high` for the first approved research path,
- set `store=false`,
- use hosted `web_search`,
- use a strict JSON Schema output contract,
- pass only the minimal image derivative and allowed structured hints above,
- constrain the research prompt to approved professional-source behavior,
- and avoid sending any local identifiers not needed by OpenAI.

Additional provider-side rules:

- Domain filtering must enforce the MyArtCollection professional-source
  allowlist before user-visible output is accepted.
- The broker must not ask OpenAI to return or preserve full page text, raw HTML,
  or broad source dumps.
- The broker must not use `previous_response_id` or any stateful continuation
  that reintroduces stored conversation state for this flow.

## Response contract

### Broker response shape

The app should receive a normalized JSON object with this logical shape:

- `request_id`
- `status`
- `provider`
- `model`
- `reasoning_effort`
- `completed_at`
- `sources[]`
- `candidate_attributions[]`
- `comparable_value_signals[]`
- `warnings[]`
- `error` when terminal failure occurs

### Source object

Each `sources[]` item should contain only:

- `source_id`
- `source_name`
- `source_type`
- `source_url`
- `title`
- `accessed_at`
- `citation_excerpt`
- `matched_fields[]`

Rules:

- `source_url` must be https and allowlisted.
- `citation_excerpt` must be short, plain-text, and capped.
- No full article text, page HTML, or long snippets.
- Source images may be returned only when the source/license policy is later
  approved and the URL is allowlisted; otherwise omit them.

### Candidate attribution object

Each candidate must include:

- `candidate_id`
- `confidence` enum: `possible`, `likely`, `insufficient_evidence`
- `match_reason`
- optional candidate fields:
  - `title`
  - `artist`
  - `year`
  - `medium`
- `field_sources` map using existing local field-source semantics
- `source_refs[]` listing one or more `source_id` values

Rules:

- At least one validated `source_ref` is required for every candidate.
- No candidate may claim certainty, authenticity, or appraisal-grade value.
- If evidence conflicts or is weak, return `insufficient_evidence` instead of
  fabricating a decisive answer.

### Comparable value signal object

Comparable signals remain highest-risk output and must be conservative.

Allowed `kind` values:

- `public_estimate`
- `comparable_sale_signal`
- `user_provided_insurance_value`
- `no_reliable_comparable`

Rules:

- `source_refs[]` are required for any public estimate or comparable sale
  signal.
- Auction-house or price-data sources must already be approved by source-rights
  review before amounts may be surfaced.
- The response must include caveat text that the comparable may not apply to the
  user's artwork.
- Disallowed labels remain:
  - `market value`
  - `worth`
  - `appraised at`
  - `certified value`
  - `authentic value`

### Warning object

Warnings should use fixed enums only, for example:

- `insufficient_image_detail`
- `conflicting_sources`
- `no_allowlisted_match`
- `provider_refusal`
- `comparable_withheld_by_policy`

## Source attribution boundaries

- The app may show only broker-validated source metadata, not arbitrary raw
  provider narrative.
- Inline citations must be visible and clickable in UI, consistent with OpenAI's
  web-search documentation.
- The broker may preserve short citation excerpts and titles for user review,
  but must not persist full source text bodies or downloaded pages.
- A source URL may be stored locally in the user's own research record because
  the feature requires source-backed review. That allowance does not extend to
  telemetry, logs, or Firebase-bound evidence.
- Provider annotation URLs or titles that do not pass allowlist validation must
  be discarded from user-visible output and treated as a policy failure.

## Operational telemetry policy for the broker

### Allowed broker operational events

Allowed broker logs/metrics must use fixed names and fixed small-value classes
only. Example event families:

- `broker_request_accepted`
- `broker_request_rejected`
- `broker_provider_call_started`
- `broker_provider_call_completed`
- `broker_provider_call_failed`
- `broker_response_validation_failed`
- `broker_request_replayed`
- `broker_quota_denied`

Allowed fields:

- `event_name`
- `timestamp`
- `status_code_class`
- `fixed_reason_code`
- `provider=openai`
- `model=gpt-5.4`
- `reasoning_effort=high`
- `request_payload_bucket` such as `image_only_small`, `image_plus_hints_medium`
- `image_size_bucket`
- `duration_ms_bucket`
- `source_count_bucket`
- `candidate_count_bucket`
- `comparable_count_bucket`
- `retry_count`
- `replayed_request` bool
- one-way-derived identifiers only:
  - `quota_subject_v1`
  - `request_fingerprint_v1`

### Explicitly banned log and telemetry fields

The following must never appear in broker logs, Cloud Logging payloads,
structured metrics labels, Crashlytics keys/logs, Firebase Analytics events,
Firebase Performance traces, App Distribution release notes, screenshots, or
operator-written summaries:

- raw prompts or prompt fragments,
- raw Responses output text,
- raw citation titles if used as labels or logs,
- source URLs,
- source excerpts/snippets,
- research queries or search terms,
- raw user notes,
- visual summary text,
- OCR/signature text,
- local artwork IDs,
- filenames or local/cloud paths,
- image bytes, thumbnails, or image URLs derived from user uploads,
- raw App Check tokens,
- raw Firebase Auth tokens,
- raw UID,
- tester emails,
- API keys, secrets, service-account paths, or credential hints.

## Retention and deletion behavior

### Broker-owned retention

Allowed retention:

- idempotency tuple state from [#50](https://github.com/kenleren/MyArtCollection/issues/50) for up to 24 hours,
- one-way-derived quota subject and request fingerprint,
- content-free operational telemetry for up to 30 days,
- aggregate cost/latency metrics with no user-content fields.

Required deletion:

- uploaded image derivatives deleted from broker-controlled temp storage
  immediately after request completion or terminal failure,
- normalized prompt assembly buffers deleted after completion,
- provider raw response bodies deleted after schema validation and local result
  assembly,
- rejected requests that fail policy validation must not be persisted except as
  fixed reason codes plus derived identifiers.

### OpenAI request settings

Required:

- every Responses request sets `store=false`.

Important limitation:

- `store=false` reduces retained application state but does not by itself prove
  Zero Data Retention or settle all provider data-handling concerns. Those stay
  blocked on [#52](https://github.com/kenleren/MyArtCollection/issues/52).

### Firebase-bound telemetry

- No AI broker payloads, source URLs, prompts, responses, or images may be sent
  to Firebase telemetry products.
- Existing Firebase crash telemetry remains governed by
  [FIREBASE_TELEMETRY_POLICY.md](FIREBASE_TELEMETRY_POLICY.md) and must stay on
  its current fixed sanitized error-category contract.

## Error handling contract

Client-visible broker errors should use a small fixed shape:

- `code`
- `retryable`
- `message_key`
- optional `retry_after_seconds`

Allowed error codes:

- `unauthorized`
- `forbidden`
- `payload_invalid`
- `payload_too_large`
- `unsupported_media`
- `policy_blocked`
- `rate_limited`
- `upstream_timeout`
- `upstream_refusal`
- `upstream_invalid_output`
- `temporarily_unavailable`

Rules:

- Do not echo source URLs, search terms, prompt text, token claims, or allowlist
  internals in client-visible errors.
- Use fixed reason codes in logs and fixed localization keys in UI.
- Treat provider schema mismatch, non-allowlisted sources, or missing citations
  as policy failures, not soft successes.

## Acceptance checks and test evidence

No paid implementation should proceed until the future code proves all of the
following:

1. Request serialization excludes raw notes, full record data, source URLs,
   filenames, and secrets.
2. The network payload omits the local artwork ID and uses only the broker
   request handle.
3. Image preprocessing strips EXIF and enforces the configured size cap before
   broker upload.
4. Every OpenAI Responses request sets `store=false`.
5. Broker prompt assembly rejects banned fields even when the local record
   contains them.
6. Response parsing rejects any candidate without at least one validated source
   reference.
7. Response parsing rejects non-allowlisted source URLs and deceptive hosts.
8. Comparable values are withheld unless the source type and policy allow them.
9. Broker logs contain only fixed event names, fixed reason codes, buckets, and
   derived identifiers.
10. Firebase/Crashlytics wrappers prove that prompts, images, source URLs,
    query text, and citation text are not sent.
11. Failure paths do not leak payload content into exceptions, logs, or
    telemetry.
12. Temp files and in-memory buffers are deleted or dropped after completion.

Recommended future test packs:

- unit tests for payload builder allowlist/denylist behavior,
- unit tests for schema validation and allowlisted citation enforcement,
- unit tests for telemetry facade denylisting,
- integration tests with fake OpenAI client proving `store=false`,
- integration tests with fake Firebase crash backend proving no banned fields
  are emitted.

## Task breakdown

1. Define the broker request DTO, image preprocessing limits, and payload
   builder denylist in the implementation plan.
   - Skills: `codex-task-plan`, `codex-task-work`
   - Required review: `codex-redteam-review`

2. Define the broker response DTO, schema validation, and source allowlist
   validation layer.
   - Skills: `codex-task-plan`, `codex-task-work`
   - Required review: `codex-redteam-review`

3. Implement content-free broker telemetry facade and fixed reason-code
   taxonomy.
   - Skills: `codex-task-work`, `codex-task-review`
   - Required review: `codex-redteam-review`

4. Implement test coverage for payload minimization, `store=false`, temp-file
   deletion, and Firebase telemetry denial proofs.
   - Skills: `codex-task-work`, `codex-task-review`
   - Required review: `codex-redteam-review`, `codex-deployment-manager`

5. Run independent review focused on privacy contract fidelity before any paid
   provider traffic is enabled.
   - Skills: `codex-task-review`, `codex-redteam-review`

## Open decisions for humans

1. Is banning raw user notes in v1 acceptable, or does the product owner want a
   later measured exception for a capped note-summary field?
2. Is the proposed image cap of 1600 px / 1.5 MB acceptable for initial
   quality, or should the implementation benchmark a slightly higher cap before
   rollout?
3. Is 30-day retention acceptable for content-free broker operational telemetry,
   or should operators enforce a shorter window?
4. Should the first source profile be `museum_only` until auction-house rights
   review is accepted, even if comparable-value output then stays mostly empty?
5. Should broker request/response DTOs intentionally diverge from the current
   local `OnlineResearchRequest` and `ResearchJob` shapes now, or should the app
   add explicit mapping types at the broker boundary?

## Recommendation summary

Do not implement the paid broker until this spec, [#50](https://github.com/kenleren/MyArtCollection/issues/50),
[#49](https://github.com/kenleren/MyArtCollection/issues/49), and
[#52](https://github.com/kenleren/MyArtCollection/issues/52) are accepted.
When implementation starts, the first broker contract should be:

- one user-selected minimized image derivative,
- structured draft hints only,
- no raw notes,
- `store=false` on every OpenAI Responses request,
- strict JSON response validation,
- allowlisted source attribution,
- content-free operational telemetry only,
- and explicit tests proving prompts, images, and source URLs never reach
  Firebase telemetry.
