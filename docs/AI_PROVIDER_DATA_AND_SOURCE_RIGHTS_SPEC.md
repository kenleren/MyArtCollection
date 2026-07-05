# AI Provider Data And Source Rights Spec

Status: Proposed  
Issue: [#52](https://github.com/kenleren/MyArtCollection/issues/52)  
Parent: [#42](https://github.com/kenleren/MyArtCollection/issues/42)  
Scheduling evidence: [issue comment](https://github.com/kenleren/MyArtCollection/issues/52#issuecomment-4883704767)  
Vendor facts verified: July 4, 2026

Related docs:
- [Architecture Plan](ARCHITECTURE.md)
- [AI Artwork Research Spec](AI_ART_RESEARCH_SPEC.md)
- [Costed AI Backend Gate Spec](COSTED_AI_BACKEND_GATE_SPEC.md)
- [AI Broker Auth And Quota Spec](AI_BROKER_AUTH_AND_QUOTA_SPEC.md)
- [AI Broker Payload And Telemetry Spec](AI_BROKER_PAYLOAD_AND_TELEMETRY_SPEC.md)
- [Firebase Telemetry Privacy Policy](FIREBASE_TELEMETRY_POLICY.md)
- [Copy and Trust Rules](COPY_TRUST_SPEC.md)

## Problem statement

Archivale needs a provider-data and source-rights gate before any real
collector content is sent to an AI or research provider. The preferred first
paid path is still OpenAI Responses API hosted `web_search` with `gpt-5.4` and
high reasoning by default, but that path is only acceptable if data-use,
retention, search-source handling, attribution, deletion, and professional
reuse rights are explicit.

This issue is not asking whether AI research is useful. That was already
decided. This issue asks what provider posture is acceptable for paid art
research without drifting into uncontrolled retention, dataset sharing, or
source-rights misuse.

## Context and evidence

### Repo-local evidence

- [Architecture Plan](ARCHITECTURE.md) requires explicit, minimal AI upload and
  bans direct vendor calls from the app.
- [AI Artwork Research Spec](AI_ART_RESEARCH_SPEC.md) frames the feature as
  professional-source research with citations, not authenticity or appraisal.
- [AI Broker Payload And Telemetry Spec](AI_BROKER_PAYLOAD_AND_TELEMETRY_SPEC.md)
  already requires `store=false`, content-free telemetry, and strict source
  allowlists, but leaves provider retention and rights policy to this issue.
- [Firebase Telemetry Privacy Policy](FIREBASE_TELEMETRY_POLICY.md) bans AI
  prompts, responses, research queries, citations, and source URLs from
  Firebase-bound telemetry.
- Current local code in
  [lib/app/research/online_research_service.dart](/Users/kenleren/Private/Ken/MyArtCollection/lib/app/research/online_research_service.dart)
  already models an allowlist for `metmuseum.org`, `artic.edu`,
  `harvardartmuseums.org`, `europeana.eu`, and `getty.edu`. This spec tightens
  which of those are acceptable for paid production use.
- Current prototype consent copy in
  [lib/app/screens/prototype_flow.dart](/Users/kenleren/Private/Ken/MyArtCollection/lib/app/screens/prototype_flow.dart)
  still mentions sending local notes. That is broader than the v1 provider
  posture accepted by [AI Broker Payload And Telemetry Spec](AI_BROKER_PAYLOAD_AND_TELEMETRY_SPEC.md).

### Current vendor facts that shape the decision

- OpenAI's API business-data position is opt-out by default for training:
  business/API inputs and outputs are not used to train models unless the
  organization explicitly opts in to sharing.
- OpenAI exposes separate org/project data-sharing controls for feedback,
  eval/fine-tuning data, and API inputs/outputs. Those controls can be enabled
  later by humans, so this repo must require them to stay disabled.
- OpenAI `/v1/responses` retains application state for at least 30 days by
  default or when `store=true`. With `store=false`, server-side compaction does
  not retain data, but default abuse-monitoring retention still applies unless
  OpenAI approves Modified Abuse Monitoring or Zero Data Retention.
- OpenAI ZDR and Modified Abuse Monitoring are not self-serve defaults. They
  require prior approval and add endpoint/capability constraints.
- OpenAI prompt caching is automatic. On `gpt-5.4`, `prompt_cache_retention`
  can still be set to `in_memory`, which typically keeps cached prefixes for
  minutes and at most one hour. Extended prompt caching can retain encrypted
  tensors for up to 24 hours.
- OpenAI's current latest-model guidance points new projects to `gpt-5.5`, but
  `gpt-5.4` remains the product decision here and still supports the
  lower-retention `in_memory` cache mode. That is a real data-handling reason
  not to silently upgrade the default model yet.
- OpenAI hosted `web_search` supports domain filtering and returns citations and
  full `sources` lists, but OpenAI's data-controls guide states that data sent
  to third-party services over network connections is subject to those third
  parties' retention policies.
- Google's Gemini paid-service terms say paid prompts and responses are not used
  to improve products, but Gemini's own ZDR page says Grounding with Google
  Search stores prompts, contextual information, and generated output for 30
  days and that this storage cannot be disabled.
- Google's current Interactions API is the recommended interface for new Gemini
  projects and stores interaction state by default unless `store=false` is set.
- Google's logs/datasets tooling can keep API logs for 55 days by default and
  optionally share datasets with Google for product improvement and training if
  humans opt in.

### Professional-source rights facts

| Source | Current rights posture | Attribution / reuse implication | V1 status |
| --- | --- | --- | --- |
| The Met API / `metmuseum.org` | Open Access dataset and OA images are CC0/public-domain for commercial and noncommercial reuse; non-OA materials remain restricted | Keep source URL/object ID; only display/store images marked OA/Open Access | Allow |
| Art Institute of Chicago / `artic.edu` | Public API exposes license metadata; much data is CC0, but some fields such as `description` are CC-BY and some records include third-party Getty attribution | Preserve per-field/per-record license metadata; do not strip required attribution | Allow with license-aware field handling |
| Europeana / `europeana.eu` | Metadata is CC0, but digital objects/previews are governed by per-item rights statements; Europeana logs API use for a limited time | Preserve provider, aggregator, rights statement, and source link; only display previews/objects when per-item rights allow | Allow with rights-statement enforcement |
| Getty vocabularies / `getty.edu` | Getty vocabulary data is ODC-By 1.0 | Cite Getty plus contributor/source where required | Allow as reference vocabulary source |
| Harvard Art Museums / `harvardartmuseums.org` | API is public-key based, but website image licensing says website images are for personal, noncommercial use | Paid-product image/display reuse is not clearly approved from current public docs | Defer for paid production allowlist until explicit terms review |
| Auction houses / price databases | Rights vary widely; sale images and text are often restricted | No v1 allowlist entry without written terms review or contract | Block by default |

### Inference from the sources

The vendor docs do not provide a turnkey privacy posture for Archivale.
They do show that the first acceptable live-content path needs more than
`store=false`. It also needs:

1. provider-side sharing controls kept off,
2. explicit approval for ZDR or a documented accepted fallback,
3. minimal request content because hosted search touches third parties,
4. per-source rights enforcement instead of a single blanket allowlist.

## Non-goals

- No implementation in this issue.
- No approval for direct mobile vendor calls.
- No approval to send live collector content under default provider settings.
- No approval for Google Search grounding, Gemini datasets sharing, or auction
  house sources in the first paid path.
- No legal conclusion that every museum or art source in the current code
  allowlist is safe for paid reuse.

## Requirements

### 1. Paid-service mode only

- The first paid provider path must use a billed OpenAI API organization/project
  controlled by Archivale, not a consumer ChatGPT subscription and not a
  tester's personal account.
- Human owners must record the OpenAI organization, project, billing owner, and
  data-controls owner before any live-content call.
- OpenAI org/project sharing toggles for:
  - model feedback,
  - eval/fine-tuning data sharing,
  - API inputs/outputs sharing
  must all be disabled.
- If Gemini is ever evaluated later, logs/datasets sharing must remain disabled
  and no dataset contribution may contain collector content.

### 2. OpenAI retention posture

- Every broker request must use `store=false`.
- The first live-content path must not use:
  - background mode,
  - Conversations API,
  - `previous_response_id` statefulness,
  - remote MCP,
  - file search,
  - hosted containers,
  - multi-artwork context.
- Default target posture for live collector content is:
  - OpenAI Zero Data Retention approved for the project or organization,
  - `store=false`,
  - no stateful features,
  - no broadened tool surface.
- If OpenAI ZDR is not approved, the only acceptable fallback for limited beta
  consideration is:
  - OpenAI Modified Abuse Monitoring approved,
  - `store=false`,
  - `prompt_cache_retention="in_memory"` on `gpt-5.4`,
  - explicit human acceptance that this is not true zero retention because
    short-lived caching and third-party search retention still exist.
- OpenAI default 30-day abuse-monitoring retention without ZDR or Modified
  Abuse Monitoring is not acceptable for live collector content.

### 3. Prompt cache decision

- For the `gpt-5.4` default path, set `prompt_cache_retention="in_memory"` for
  live-content requests unless OpenAI-approved ZDR policy requires another
  value.
- Do not upgrade the default model to `gpt-5.5` or newer until the retention
  consequences of mandatory extended prompt caching are reviewed in a follow-up
  spec.

### 4. Hosted web-search rules

- Hosted `web_search` is allowed only with a professional-domain allowlist.
- Search requests must contain only the minimum one-artwork payload already
  narrowed by [AI Broker Payload And Telemetry Spec](AI_BROKER_PAYLOAD_AND_TELEMETRY_SPEC.md).
- Raw notes, provenance text, insurance values, collection-wide context,
  contacts, and location names remain banned from provider prompts.
- Citations and the full reviewed source list must be preserved locally for user
  review.
- Broker-normalized source/result metadata may be kept locally only as
  user-review evidence. Raw provider tool traces and raw search-result payloads
  must be discarded after normalization.
- The app must disclose before first use that online research may involve
  third-party web/source services with their own retention policies.

### 5. Professional-source rights policy

- The provider/source allowlist is not just a trust list. It is a rights list.
- Each allowlisted domain must have a recorded rule for:
  - metadata reuse,
  - image/preview reuse,
  - attribution text,
  - per-item rights exceptions,
  - whether commercial/premium in-product display is allowed.
- The v1 paid allowlist may include:
  - `metmuseum.org`
  - `artic.edu`
  - `europeana.eu`
  - `getty.edu`
- `harvardartmuseums.org` must be removed from the paid-production allowlist
  unless a human legal/rights review confirms the intended paid use.
- Auction-house, gallery, foundation, or price-database domains require
  separate written terms review before use.
- Per-item rights always outrank domain-level allowlisting.

### 6. Deletion behavior

- Broker-owned request bodies, derived images, temp files, and provider raw
  responses must be deleted after request completion or terminal failure.
- The app may keep only sanitized, user-reviewable local research records,
  citations, rights statements, and audit-safe job metadata.
- No Firebase telemetry surface may receive prompts, responses, source URLs,
  citation snippets, or source titles.
- Humans must document any provider-side deletion limitation that cannot be
  controlled by API settings.

### 7. Review evidence

- Before any live collector content is sent, the issue set must include evidence
  of:
  - paid-service mode,
  - OpenAI sharing controls disabled,
  - ZDR approval or explicitly accepted fallback,
  - `store=false`,
  - prompt-cache decision,
  - professional-source rights matrix,
  - deletion behavior,
  - redteam/privacy review.

## Options considered

| Option | Summary | Pros | Cons | Outcome |
| --- | --- | --- | --- | --- |
| A. OpenAI with approved ZDR, `store=false`, hosted `web_search`, `gpt-5.4`, high reasoning | Strictest first paid path that still matches repo preference | Best fit for live-content privacy posture; reduces retained provider content; keeps preferred product path | Requires approval process and may constrain future capabilities | Recommended |
| B. OpenAI with Modified Abuse Monitoring, `store=false`, `prompt_cache_retention="in_memory"` | Accepted fallback if ZDR is unavailable | Can still avoid default 30-day abuse logs and broad app-state retention | Not zero retention; still leaves short-lived cache and third-party search retention | Accept only with explicit human sign-off for limited beta |
| C. OpenAI default API settings plus `store=false` | Minimal operational work | Easiest to implement | Still leaves default abuse-monitoring retention; not strong enough for live collector content | Reject |
| D. Gemini with Google Search grounding | Google-native alternate | Paid prompts/responses are not training data by default | Search grounding stores prompt/context/output for 30 days and cannot be disabled; current API surfaces also add state/logging tradeoffs | Reject for first live-content path |
| E. Do not send live collector content yet | Delay provider use until controls are approved | Lowest privacy and rights risk | Delays real-provider research | Correct outcome until this spec and the sibling blockers are accepted |

## Recommended approach

Decision:

1. Do not send live collector content to any provider until this spec and the
   other [#42](https://github.com/kenleren/MyArtCollection/issues/42) blockers
   are accepted.
2. Approve only Option A as the target first live-content path:
   OpenAI Responses API, hosted `web_search`, `gpt-5.4`, high reasoning,
   `store=false`, OpenAI ZDR approval, strict professional-source allowlist,
   and license-aware citation handling.
3. Allow Option B only as a written human exception for a tightly controlled
   beta if ZDR is unavailable and redteam accepts the residual risk.
4. Defer Google/Gemini provider search and grounding until a separate approved
   review accepts their unavoidable storage tradeoffs.

### What would make this recommendation wrong

Revisit this recommendation if:

- OpenAI refuses ZDR and humans do not accept Modified Abuse Monitoring plus
  in-memory caching as sufficient for beta,
- OpenAI changes `gpt-5.4` cache behavior so `in_memory` is no longer
  available,
- or the product later requires source classes whose rights posture is too
  restrictive for hosted web-search aggregation.

## Risks and mitigations

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| Silent provider drift | A human can later enable sharing toggles or upgrade models | Require recorded screenshots/evidence of disabled controls and model pin review |
| Third-party search retention | Hosted search touches systems outside app control | Minimize payload, disclose this explicitly, and keep domain allowlist narrow |
| Source-rights mismatch | Paid product display may exceed source permissions | Store per-source rights rules and fail closed on missing rights metadata |
| Harvard/Auction-house misuse | Current code allowlist is broader than safe paid reuse | Remove or defer those domains in paid-production rules |
| Overbroad prompt content | Collection or ownership details can leak into provider/search systems | Keep raw notes and broader record context banned in v1 |
| Future model upgrade changes retention | GPT-5.5+ latest-model guidance may tempt an upgrade | Treat model upgrade as a new data-handling review gate |

## Review gates

Before live collector content is allowed:

1. [#48](https://github.com/kenleren/MyArtCollection/issues/48) must record the
   paid provider owner, project/billing posture, and cost controls.
2. [#49](https://github.com/kenleren/MyArtCollection/issues/49) must record the
   kill-switch and rollback evidence for the paid backend path.
3. [#50](https://github.com/kenleren/MyArtCollection/issues/50) must be
   accepted so only approved app/user identities can reach the broker.
4. [#51](https://github.com/kenleren/MyArtCollection/issues/51) must be
   accepted so the broker payload remains minimal and telemetry-safe.
5. This issue must be accepted with a human answer to the ZDR versus Modified
   Abuse Monitoring decision.
6. `$codex-redteam-review` is mandatory before any live-provider beta.

## Acceptance checks

- A concise provider-data spec exists at this path.
- Paid-service mode is required.
- OpenAI sharing/dataset/training controls are required to remain disabled.
- ZDR is the target decision, with Modified Abuse Monitoring plus documented
  residual-risk acceptance as the only fallback candidate.
- `store=false` is mandatory.
- Prompt-cache retention policy is explicit.
- Web-search source/result retention handling is explicit.
- Hosted web-search third-party retention is explicitly called out.
- Google Search grounding is explicitly rejected for the first live-content
  path because of unavoidable 30-day retention.
- Professional-source allowlist rules and rights/attribution constraints are
  explicit.
- Deletion behavior is explicit.
- Redteam/privacy review evidence is required.

## Task breakdown

1. Human/provider admin task:
   confirm OpenAI paid org/project ownership, disable all sharing toggles, and
   request ZDR or Modified Abuse Monitoring.
   - Follow-up owner: human
   - Review: `$codex-redteam-review`

2. Broker contract alignment task:
   align implementation plan with `store=false`, `prompt_cache_retention`,
   no stateful Responses features, and no broader tool surface.
   - Follow-up owner: `$codex-task-work`
   - Review: `$codex-task-review`

3. Source-rights registry task:
   create a machine-readable allowlist/rights matrix for allowed domains and
   remove or defer blocked sources such as Harvard paid-image reuse.
   - Follow-up owner: `$codex-task-plan` then `$codex-task-work`
   - Review: `$codex-redteam-review`

4. Consent/copy task:
   update research consent copy so it matches the real provider payload and
   discloses third-party search retention and citation/source handling.
   - Follow-up owner: `$codex-task-plan` then `$codex-task-work`
   - Review: `$codex-visual-review`

5. Privacy/redteam gate task:
   verify retention posture, deletion paths, telemetry bans, and rights-fail
   behavior before any live-provider beta.
   - Follow-up owner: `$codex-redteam-review`

## Open decisions for humans

1. Is live collector content strictly blocked until OpenAI ZDR is approved, or
   is Modified Abuse Monitoring plus `store=false` plus in-memory caching
   acceptable for a limited beta?
2. Should `harvardartmuseums.org` remain metadata-only, or be fully removed
   from the paid-production allowlist until explicit written permission exists?
3. Does the first paid beta allow Europeana previews only when the per-item
   rights statement is permissive, or should Europeana be metadata-only until
   the UI can display rights labels cleanly?
4. Which human signs the provider/source rights matrix: product owner only, or
   product plus legal/privacy review?
