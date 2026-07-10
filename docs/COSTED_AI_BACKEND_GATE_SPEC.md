# Costed AI Backend Gate Spec

Status: Proposed
Issue: [#42](https://github.com/kenleren/MyArtCollection/issues/42)
Billing/topology reconciliation: #190
Scheduling evidence: [issue comment](https://github.com/kenleren/MyArtCollection/issues/42#issuecomment-4883398463)
Initial implementation evidence: [issue comment](https://github.com/kenleren/MyArtCollection/issues/42#issuecomment-4883425657)
First review-block reconciliation: [issue comment](https://github.com/kenleren/MyArtCollection/issues/42#issuecomment-4883461683)
OpenAI provider-change notice: [issue comment](https://github.com/kenleren/MyArtCollection/issues/42#issuecomment-4883485006)
Current implementation evidence: [issue comment](https://github.com/kenleren/MyArtCollection/issues/42#issuecomment-4883490307)

## Problem statement

Archivale needs a hard decision gate before any paid AI or backend path is
implemented. The repo already wants a thin server-side AI broker, but #42
exists because paid backend work changes privacy, abuse, deployment, and cost
risk immediately. The owner preference after the first review pass is to use
OpenAI/ChatGPT web research as the preferred model path, with `gpt-5.4` as the
default art-research model and high reasoning by default.

The decision is not just "which model?". The decision is:

- whether any paid AI/backend workflow should be allowed now,
- which architecture is allowed first,
- what cost ceiling and shutoff controls exist before rollout,
- what abuse controls and retention limits are mandatory,
- and what product claims are banned.

## Context and evidence

### Repo-local evidence

- [docs/ARCHITECTURE.md](ARCHITECTURE.md) recommends a local-first Flutter app
  with a thin server-side AI broker and says AI is opt-in and never a direct
  vendor call from the app.
- [docs/AI_ART_RESEARCH_SPEC.md](AI_ART_RESEARCH_SPEC.md) already frames AI
  value as source-backed research, not authentication, appraisal certainty, or
  market value.
- [docs/FIREBASE_TELEMETRY_POLICY.md](FIREBASE_TELEMETRY_POLICY.md) bans AI
  prompts, responses, research queries, and source URLs from Firebase-bound
  telemetry.
- [docs/FIREBASE_APP_DISTRIBUTION.md](FIREBASE_APP_DISTRIBUTION.md) treats App
  Distribution as separate from broader Firebase data-platform decisions.

### Current vendor facts to anchor the gate

- Cloud Functions deployment requires Blaze: Firebase says to "upgrade your
  project to the pay-as-you-go Blaze pricing plan" before deploying functions.
- OpenAI recommends the Responses API with the hosted `web_search` tool for new
  web search integrations. The tool can return citations, complete source
  lists, domain filters, live-access controls, and image results.
- OpenAI web search supports agentic search with reasoning models. OpenAI's
  docs describe higher reasoning as better suited to complex, multi-step web
  research, but with longer latency and higher cost.
- OpenAI web search domain filtering supports allowlists or blocklists of up to
  100 domains, which fits this repo's professional-source-only art research
  constraint.
- OpenAI's current docs identify `gpt-5.5` as the latest model and recommend it
  for new web-search integrations, but this repo chooses `gpt-5.4` as the MVP
  default by product decision. `gpt-5.5` remains a later benchmark/escalation
  candidate, not the MVP baseline.
- Firebase AI Logic is a direct-from-app SDK path: its get-started guide says
  it makes Gemini API calls "directly from your app", and its App Check guide
  says direct mobile/web calls are vulnerable to abuse by unauthorized clients.
- Firebase AI Logic itself is free, but underlying Gemini usage and some related
  Firebase products can still cost money.
- Firebase AI Logic provides a default per-user quota surface, but the default
  is high: 100 RPM per user, project-wide, and shared across all apps/IPs on
  that Firebase project.
- Firebase/Cloud budget alerts are not caps; Google explicitly says alerts can
  arrive after spend is incurred.
- Google Cloud can be configured to disable billing automatically when a budget
  threshold is reached, but Google also warns that this shuts down project
  services and recovery may require manual work.
- Gemini API billing is tied to projects, API keys, and billing accounts. API
  keys do not have independent billing; they inherit project and billing-account
  state.
- Gemini API spend caps can be set at both billing-account tier and project
  level. Project-level caps are useful when multiple projects share one billing
  account, but Google labels spend caps experimental and warns that processing
  latency can allow spend beyond the configured cap.
- Gemini API billing mode must be chosen explicitly. A Prepay plan can stop API
  keys after credits run out, subject to billing-system latency; a Postpay plan
  should be treated as advisory unless paired with separate quota and shutdown
  controls.
- Google AI Plus / Google AI Pro consumer plans increase Gemini app usage limits
  in Google's consumer products; they are not app-side API entitlements for
  this repo.
- Vertex/Gemini Enterprise Agent Platform adds regional/global endpoint control,
  org-level throughput controls, and broader GCP governance, but its global
  endpoint explicitly does not guarantee data residency.
- Provider data-handling controls are release-critical. Paid-service mode,
  provider logging/sharing settings, Zero Data Retention eligibility, and any
  grounding/search storage behavior must be decided before real collector
  content is sent to a provider.

Primary sources:

- Firebase Functions overview: <https://firebase.google.com/docs/functions>
- Firebase pricing plans: <https://firebase.google.com/docs/projects/billing/firebase-pricing-plans>
- Firebase avoid surprise bills: <https://firebase.google.com/docs/projects/billing/avoid-surprise-bills>
- Firebase AI Logic get started: <https://firebase.google.com/docs/ai-logic/get-started>
- Firebase AI Logic pricing: <https://firebase.google.com/docs/ai-logic/pricing>
- Firebase AI Logic App Check: <https://firebase.google.com/docs/ai-logic/app-check>
- Firebase AI Logic quotas: <https://firebase.google.com/docs/ai-logic/quotas>
- Firebase AI Logic monitoring: <https://firebase.google.com/docs/ai-logic/monitoring>
- Cloud Functions runtime controls: <https://firebase.google.com/docs/functions/manage-functions>
- OpenAI latest model guidance: <https://developers.openai.com/api/docs/guides/latest-model.md>
- OpenAI tools guide: <https://developers.openai.com/api/docs/guides/tools>
- OpenAI web search guide: <https://developers.openai.com/api/docs/guides/tools-web-search>
- Gemini API billing: <https://ai.google.dev/gemini-api/docs/billing>
- Gemini API pricing: <https://ai.google.dev/gemini-api/docs/pricing>
- Gemini API rate limits: <https://ai.google.dev/gemini-api/docs/rate-limits>
- Gemini API terms: <https://ai.google.dev/gemini-api/terms>
- Google One plans: <https://one.google.com/about/plans>
- Cloud Billing budgets: <https://docs.cloud.google.com/billing/docs/how-to/budgets>
- Disable billing with notifications: <https://docs.cloud.google.com/billing/docs/how-to/disable-billing-with-notifications>
- Cloud quota alerts: <https://docs.cloud.google.com/docs/quotas/set-up-quota-alerts>
- Agent Platform pricing: <https://cloud.google.com/gemini-enterprise-agent-platform/generative-ai/pricing>
- Agent Platform throughput tiers: <https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/standard-paygo>
- Agent Platform endpoints: <https://docs.cloud.google.com/gemini-enterprise-agent-platform/resources/locations>

## Non-goals

- No code implementation in this issue.
- No approval for mobile client secrets.
- No approval for direct mobile AI calls unless a later human decision
  explicitly overrides this spec.
- No authenticity, appraisal certainty, or market-value claims.
- No commitment yet to unlimited research, Google Search grounding, or paid
  third-party data sources.
- No reuse of a user's Google AI Plus / Google AI Pro / Gemini consumer
  subscription as the app's backend spend model.
- No reuse of a user's ChatGPT Plus / Pro / Team / Enterprise subscription as
  the app's backend spend model unless OpenAI later ships an explicit app
  entitlement path and a separate spec approves it.

## Requirements

Any approved paid AI/backend implementation must satisfy all of the following:

- Local-first product posture remains intact.
- No mobile client secrets.
- No direct mobile AI calls by default.
- Paid AI/backend traffic runs only through the isolated broker codebase and
  controls in the owner-approved `my-art-collections` project; payloads and
  broker telemetry remain separated from App Distribution and crash triage.
- Default paid research provider is OpenAI via a server-side broker using the
  Responses API with hosted web search, not direct calls from Flutter.
- Default paid research model is `gpt-5.4` with high reasoning for art
  identification/research jobs. Lower reasoning is allowed only for explicitly
  classified quick lookups; higher or newer models require measured quality and
  cost evidence before becoming the default.
- User action is explicit before any image, notes, or draft data leave the
  device.
- Backend logs and telemetry exclude artwork content, prompts, responses,
  research queries, citations, and source URLs.
- Retention defaults to no server-side storage of user-submitted images,
  prompts, or model outputs after request completion.
- Abuse controls exist before rollout: app attestation, per-install or per-user
  quotas, payload caps, concurrency caps, and rollout gating.
- Billing controls exist before rollout: budget alerts, quota alerts, written
  kill-switch, and documented rollback.
- Named human billing ownership and deployment ownership exist before rollout.
- Product copy sells workflow and professional-source evidence, not certainty.
- No "unlimited research" promise before measured per-job cost exists.
- Hosted web search must be constrained to an allowlist of professional art,
  museum, gallery, auction, artist-estate, catalogue raisonne, institution, or
  other approved source domains before any paid research job can run.
- Citations and source metadata must be preserved and shown to the user for any
  researched claim.
- Redteam review and deployment-manager review are required before any paid
  backend is released beyond tightly controlled beta.

## Hard release blockers

The following are not recommendations. They are release blockers before any
paid backend implementation, Blaze enablement, live Firebase Functions broker,
provider API billing, provider call, or external-source automation can be
started:

- [#48](https://github.com/kenleren/MyArtCollection/issues/48): paid AI
  backend approval, provider choice, and billing topology decision record.
- [#49](https://github.com/kenleren/MyArtCollection/issues/49): kill-switch,
  rollback, monitoring, alerting, and deployment evidence runbook.
- [#50](https://github.com/kenleren/MyArtCollection/issues/50): broker auth,
  App Check, quota identity, revocation, and replay-control topology.
- [#51](https://github.com/kenleren/MyArtCollection/issues/51): broker
  contract, payload minimization, telemetry redaction, and log-safety rules.
- [#52](https://github.com/kenleren/MyArtCollection/issues/52): provider data
  handling, Zero Data Retention, professional-source rights, and grounding
  tradeoff guardrails.

Each blocker must have accepted specialist review in its own issue before it
can be used as evidence for paid backend rollout. If a blocker is rejected,
paid AI/backend work remains stopped.

## Options considered

| Option | Summary | Pros | Cons | Gate outcome |
| --- | --- | --- | --- | --- |
| A. Firebase AI Logic directly from app | Use Firebase AI Logic client SDKs in Flutter/mobile | Fastest path, Firebase App Check support, Firebase-managed client SDK | Conflicts with current architecture and #42 rule because calls are direct from app; default Firebase AI Logic quota is high; still creates paid client attack surface | Reject by default |
| B. Thin server broker on Firebase Functions 2nd gen using OpenAI Responses API with hosted web search | App sends minimal payload to broker; broker calls OpenAI `gpt-5.4` with high reasoning and hosted `web_search` constrained by professional-source allowlists | Best match for owner preference and repo architecture; stronger fit for grounded search, citations, source lists, domain filters, image search, structured outputs, and model reasoning controls; secrets remain server-side | Requires paid OpenAI API account/project controls and measured per-job cost; hosted web search/source behavior and provider data handling must be reviewed; long research can be slower and costlier | Recommended first paid path, but only after gate approval |
| C. Thin server broker on Firebase Functions 2nd gen using Gemini Developer API | Same broker pattern, but provider is Gemini Developer API | Keeps a Google-only stack and may be useful as a later provider fallback | No longer owner-preferred default; requires Gemini billing controls; spend caps are not the only control because project and billing-account caps are experimental and can overrun during latency; no enterprise residency guarantees | Defer as alternate provider |
| D. Thin server broker on Firebase Functions 2nd gen using Vertex / Gemini Enterprise Agent Platform | Same broker pattern, but provider is Vertex/Agent Platform | Better org-level governance, regional endpoint choice, richer GCP controls, can use some Google Cloud credits | More platform complexity; interactive pricing is not simpler; global endpoint does not guarantee residency; overkill for MVP beta | Defer unless separate human need for governance/residency outweighs complexity |
| E. Do not build paid backend yet | Hold all paid AI/backend work until monetization and operations are clearer | Lowest risk, no billing exposure, no new privacy surface | Delays AI research feature work | Correct stance until this gate is accepted |

## Recommended approach

Decision:

1. Do not implement any paid AI/backend workflow until this spec is accepted.
2. When accepted, approve only Option B as the first paid path:
   Firebase Functions 2nd gen broker, server-side OpenAI Responses API,
   `gpt-5.4`, high reasoning, hosted `web_search`, structured output, and
   professional-source allowlists.
3. Keep Gemini Developer API, Vertex, and Gemini Enterprise Agent Platform as
   later provider alternatives, not the starting point.

### Why this is the recommended first path

- It matches the existing repo architecture and privacy posture.
- It avoids shipping secrets or a paid API surface directly in the app.
- OpenAI web search provides the exact research controls this product needs:
  citations, complete source lists, domain allowlists, image search, live-access
  control, longer reasoning research, and structured response orchestration.
- It preserves room to add allowlisted professional-source lookups, schema
  validation, retention controls, monetization, and alternate provider
  benchmarks later.

### Default model and search configuration

- Provider: OpenAI.
- API: Responses API.
- Model: `gpt-5.4` by product decision.
- Reasoning: high by default for artwork identification and source-backed art
  research. Use `xhigh` only for explicitly approved expensive deep-research
  runs after measured beta economics exist.
- Tooling: hosted `web_search`, not generic unrestricted browsing.
- Search controls:
  - `filters.allowed_domains` must be configured for approved professional art
    domains before live beta,
  - `blocked_domains` must include obvious low-trust/community sources such as
    forums, Q&A sites, generic mirrors, and social platforms unless a later
    source-specific review approves them,
  - `include` must request source metadata when available,
  - citations must be stored with the draft and visible in the UI,
  - `tool_choice` must require search for any answer presented as researched,
  - image search may be used only to support visual comparison and must not be
    presented as proof of attribution, authenticity, or value.
- Output: structured fields with uncertainty, citation bindings, and
  "needs human confirmation" status for title, artist, year, medium,
  dimensions, provenance, and rough comparable-value hints.
- Cost controls: cap search context, returned-token budget, number of source
  opens, background/deep-research use, and repeated retries per artwork.
- Fallback: if OpenAI provider controls fail closed, the app must return a
  local/manual draft state rather than silently using another provider.

### Mandatory architecture guardrails

- Use the owner-approved Firebase/GCP project `my-art-collections` for App
  Distribution, anonymous Auth, App Check, and the broker Function. Earlier
  `myartcollection-ai-beta` / `myartcollection-ai-prod` project proposals are
  obsolete and must not be provisioned from this plan.
- Preserve isolation inside the one approved project with a separate broker
  Functions codebase, server-only provider credentials, versioned Firestore
  control/entitlement/credit records, owner/app allowlists, a broker breaker,
  hard provider and credit caps, and broker-only telemetry boundaries.
- Play Billing uses its own `play-billing` codebase, callable, runtime identity,
  named `archivale-play-billing` Firestore database, database-conditioned IAM,
  deny-all client rules, collections, Android Publisher IAM, fingerprint
  domain, and rollback target in that same project, as defined by
  `PLAY_BILLING_GATE_SPEC.md`. The research broker must not call Android
  Publisher APIs or access the billing database, and
  `brokerDurableEntitlements` has no payment authority.
- Anonymous Auth is shared identity infrastructure, not shared authority. The
  billing disclosure authorizes only purchase verification/refresh and must be
  represented by a current purpose-bound server assertion before a Play call;
  it does not create research consent. Research consent does not prove purchase
  or create the billing assertion.
- Blaze enablement, billing attachment, provider credentials, Functions deploy,
  and production rollout each require explicit owner action and
  deployment-manager review under #155. The one-project decision does not
  weaken those gates or authorize account mutation.
- Configure project-level provider spend controls and billing-account-level
  alerts where available, and treat both as supplementary because billing and
  processing latency can permit overrun before shutdown takes effect.
- Record the paid provider billing model before rollout. For OpenAI, #48 must
  name the OpenAI project/account owner, budget/quota limits, API key custody,
  usage alerts, and whether billing/project limits make the `USD 25/month`
  ceiling a hard or policy-only control. For Gemini fallback, #48 must record
  whether Gemini API billing is Prepay or Postpay before rollout. If any
  provider path is policy-only, separate quota and shutdown controls must
  enforce the ceiling.
- Broker-only architecture:
  - app -> broker,
  - broker -> OpenAI Responses API,
  - OpenAI hosted web search -> allowlisted professional/public sources,
  - broker -> app with structured citations and uncertainty.
- No generic direct model access from Flutter.
- No Google Search grounding in the first paid rollout. Start with
  allowlisted professional/public sources and free/public collection APIs first.
- No provider fallback is allowed at runtime unless the provider is explicitly
  approved in #48 and covered by #50-#52.

### Approval record required before any paid work

No paid backend task may start until #48 records all of the following:

- named human billing owner,
- named human deployment owner,
- explicit approval or rejection of Blaze for the approved
  `my-art-collections` project,
- confirmation of the approved Firebase/GCP project ID,
- approved billing account topology,
- approved OpenAI project/account and API-key custody posture,
- approved fallback-provider billing posture if any fallback provider is
  enabled,
- approved monthly policy ceiling,
- accepted deployment-manager review,
- accepted redteam/privacy review when the decision changes data boundaries.

Chat approval is not sufficient unless it is copied into the linked GitHub
issue with the decision, date, owner, and scope.

### Recommended beta cost ceiling

- Internal total ceiling for the isolated broker workload inside
  `my-art-collections`: `USD 25/month`.
- Do not raise that ceiling until:
  - at least 30 completed research jobs have measured cost evidence,
  - the per-job median and p95 cost are documented,
  - and monetization or beta value is re-reviewed.

Rationale:

- This repo has no validated paid research demand yet.
- Cloud Functions can idle at zero; the dominant variable cost should be model
  calls and any paid source/provider usage.
- The ceiling is intentionally small because #42 is a gate, not launch
  approval.
- The ceiling must be implemented with the strongest available combination of
  Prepay/Postpay decision, project-level spend caps, billing-account controls,
  quotas, function limits, server-side breaker, and operator monitoring. It must
  not be described to users or operators as a guaranteed hard stop unless the
  selected billing mode and tests prove that behavior.

### Recommended cost controls before rollout

- `minInstances = 0` for all broker functions in beta.
- Small `maxInstances` ceiling in beta, with conservative concurrency, so a bug
  cannot fan out uncontrolled cost.
- Budget alerts for `my-art-collections` at 50%, 70%, 80%, and 90% of the
  monthly broker ceiling.
- Gemini API project-level spend cap configured for `my-art-collections` when
  available, plus billing-account-level caps or alerts according to the chosen
  billing topology.
- OpenAI project/account usage limits, alerts, and API-key custody controls
  configured according to #48 before any paid OpenAI call is reachable.
- Quota alerts for the broker workload and any Gemini-related quotas in the
  approved project through Cloud Monitoring.
- Quota alerts for OpenAI request count, token use, web-search tool calls,
  search context budget, error rates, and model/provider failures.
- Server-side breaker before client-side controls: the broker must be able to
  reject paid research requests at the server before calling a provider, even
  if a stale app build still shows the research entry point.
- Written manual kill switch, in order:
  1. set server-side breaker to reject all paid research traffic,
  2. set product/Remote Config flag `online_research_enabled=false`,
  3. disable or deny the broker route/function,
  4. disable, rotate, or revoke OpenAI/provider credentials/API keys,
  5. lower provider quotas where possible,
  6. only with explicit owner/deployment approval, disable billing on
     `my-art-collections` as a last resort after accounting for the impact on
     every service sharing the approved project.
- Every kill-switch step requires a verification command or console check and a
  recovery note. Rollback is not complete until a new request is rejected before
  provider spend is incurred.
- If automatic billing shutoff is implemented, keep it documented as a last
  resort only, because Google warns it can shut down project services and may
  require manual recovery.

### Recommended abuse controls before rollout

- Require valid app attestation for broker access, but do not treat App Check as
  user authentication or revocation. It proves app integrity, not user identity.
- Reject anonymous raw internet access to the broker.
- Require the #50 auth topology to define tester/user identity, token audience,
  wrong-project token rejection, replay prevention, revocation, quota-key
  derivation, and negative tests before any paid endpoint is deployed.
- Limit the beta rollout to approved testers / controlled distribution only.
- Enforce server-side request quotas per install or per user before any paid
  request is sent.
- Cap payload size, payload type, and request frequency.
- Allow one research job in flight per install/user at a time.
- Keep provider/model allowlist explicit and remote-switchable.
- Default-off product switch for online research must remain available.

### Monitoring and post-deploy evidence required before rollout

Before a paid beta is exposed to any tester, #49 must define and verify:

- alert recipients and escalation channel,
- budget, quota, error-rate, latency, and provider-failure alert thresholds,
- dashboard or console locations for spend, requests, model tokens, function
  errors, and rejected breaker traffic,
- release-window monitoring duration,
- smoke checks for flag off, breaker on, breaker off, provider success, quota
  rejection, and credential failure,
- rollback triggers for cost, abuse, privacy, model/provider failure, and user
  confusion,
- evidence template to paste into the deployment issue after each beta rollout.

### Retention and deletion policy

- Default server retention: none for submitted images, notes, prompts, raw model
  outputs, or source result bodies after the request completes.
- Allowed operational records:
  - timestamp,
  - broker endpoint,
  - model id,
  - token counts,
  - latency,
  - status code,
  - coarse quota key,
  - coarse build/environment markers.
- Operational log retention: 30 days max unless a later privacy review approves
  something else.
- Research citations and accepted field values remain a client-side concern by
  default.
- Any future server-side job queue, dead-letter store, prompt template store,
  or research result cache requires a separate spec.
- Paid-service provider mode is mandatory before sending real collector
  content. Any provider setting that shares prompts, responses, files, logs, or
  datasets for product improvement, human review, training, or abuse-monitoring
  beyond the accepted provider terms must be disabled or explicitly accepted in
  #52 before rollout.
- Zero Data Retention eligibility and tradeoffs must be recorded in #52 before
  rollout. For MVP collector-content OpenAI calls, ZDR approval for the exact
  rollout org/project is required; `store=false`, Secret Manager, owner
  allowlists, cost approval, and deployment-manager approval do not waive this
  gate.
- OpenAI data handling, model training/evals storage settings, prompt cache
  retention, web-search source/result retention, and ZDR compatibility must be
  documented in #52 before live collector content is sent through OpenAI.
- Google Search grounding remains banned for first paid rollout unless a later
  reviewed spec accepts its provider storage and citation behavior. Do not add
  grounding as an implementation detail under this issue.

### Monetization guardrails

- Sell:
  - professional-source research workflow,
  - source-backed evidence packs,
  - saved citations and export appendices,
  - deeper or repeated research passes,
  - and later expert handoff.
- Do not sell:
  - appraisal certainty,
  - authenticity certainty,
  - "market value",
  - or unlimited research without measured economics.
- Free/promo research must be explicitly capped.
- Billing or entitlement copy must state that AI suggestions are draft research
  aids and may require human expert review.
- Google Play plan access is accepted only through the server-verified,
  15-minute, memory-only lease in `PLAY_BILLING_GATE_SPEC.md`. The AI broker
  cannot mint, persist, restore, or extend that lease, and a paid plan cannot
  bypass research consent, broker breaker, credits, or provider controls.
- Billing first commits verified entitlement-delivery state in its named
  database, then acknowledges Play, and returns a lease only after
  acknowledged final state is durable/recoverable. That delivery record is not
  an AI entitlement or offline/client-authoritative lease.
- Token-fingerprint single-flight uses a server-issued attempt generation and
  nonce distinct from request identity. Leased delivery/acknowledgement phases,
  exact-owner-and-phase CAS, monotonic acknowledged finalization, per-subject
  call ceilings, and client request/UID/generation fences are payment controls
  and must not be reused as research quota or consent authority.
- A failed/expired billing lease downgrades to Free while all existing artwork
  records remain viewable, editable, reportable, and exportable.

### Explicit answer: can a user's Gemini Pro / AI Pro subscription be used by the app?

No, not as the default architecture for Archivale.

Evidence-backed reason:

- Google One / Google AI Plus / Google AI Pro plan pages describe higher Gemini
  app usage limits and Gemini features in Google products.
- Gemini API billing docs say API usage is tied to projects, API keys, and
  billing accounts; API keys inherit project billing and have no independent
  billing settings.

Inference from those sources:

- A user's consumer Gemini subscription is not an app-side API billing
  entitlement for this repo.
- A future bring-your-own-API-key admin feature is a separate decision and is
  out of scope for MVP/default behavior.

### Explicit answer: can a user's ChatGPT subscription be used by the app?

No, not as the default architecture for Archivale.

Evidence-backed reason:

- The OpenAI API docs describe API requests, model choice, hosted tools, and web
  search as API/project-backed integrations configured by the application.
- OpenAI's web search docs describe Responses API hosted `web_search` as a tool
  configured in the API request, with model, reasoning, sources, and pricing
  controls attached to that API integration.

Inference from those sources:

- A user's ChatGPT Plus / Pro / Team / Enterprise subscription is not an
  app-side API billing entitlement for this repo unless OpenAI provides an
  explicit future user-granted entitlement path and #48/#52 approve it.
- A future bring-your-own-OpenAI-key or user-connected OpenAI account feature is
  a separate product, privacy, support, and abuse-control decision and is out of
  scope for MVP/default behavior.

## Risks and mitigations

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| Direct client AI abuse | Paid surface can be replayed or scripted | Do not approve Firebase AI Logic direct client calls by default |
| Surprise spend | Budgets are alerts, spend caps are experimental, and processing latency can overrun limits | Isolated broker codebase and service quotas inside the approved project, low policy ceiling, Prepay/Postpay decision, project spend cap, server breaker, manual kill switch, optional last-resort billing disable |
| Billing-account cross-talk | Shared billing accounts can blur ownership and blast radius | Prefer dedicated billing account; if shared, configure both project-level and billing-account controls and record the weaker isolation |
| Shared-project shutdown blast radius | Project-wide billing disablement can stop AI, Play verification, Auth/App Check, telemetry, and distribution surfaces together | Use codebase, runtime-IAM, route, and provider controls first; reserve project-wide billing action for explicit owner-approved last resort |
| Database authority cross-talk | Project-level Firestore roles would let billing and broker runtimes cross data boundaries despite different collection names | Put billing state in `archivale-play-billing`, condition runtime IAM per database, deny clients with database rules, and test both directions negatively |
| Privacy drift in logs | AI queries and citations are sensitive | Keep broker telemetry content-free and align with `FIREBASE_TELEMETRY_POLICY.md` |
| Provider data retention drift | External providers may retain or inspect data under terms/settings | Require #52 provider data-handling/ZDR decision before real content leaves device |
| App Check misunderstanding | App Check is attestation, not identity or revocation | Require #50 auth topology, tester/user identity, replay controls, and negative tests |
| Kill switch fails open | Client flags alone cannot stop stale builds from spending | Require server-side breaker and deployment-manager-reviewed rollback runbook in #49 |
| Product overclaim | Art users may read AI as appraisal/authentication | Constrain copy to evidence-backed research workflow only |
| Residency misunderstanding | Vertex global endpoint is not residency | Keep residency claims out unless separately reviewed |
| Operational ownership gap | Paid backend without a human owner is unsafe | Name a human billing/deployment owner before rollout |

## Acceptance checks

This issue is decision-ready when all of the following are true:

- This spec exists in the repo and is reviewed.
- The default architecture decision is clear: no direct mobile AI calls, no
  client secrets, broker-only if approved.
- The first approved paid path is clear: Firebase Functions 2nd gen broker +
  OpenAI Responses API + `gpt-5.4` high reasoning + hosted web search.
- The default rejected path is clear: Firebase AI Logic direct client use.
- Gemini Developer API and Vertex/Gemini Enterprise Agent Platform are clear
  alternate/deferred provider paths, not the owner-preferred default.
- The one-project isolation decision and broker-specific controls are
  documented.
- A monthly cost ceiling is documented.
- Gemini project-level and billing-account-level cap behavior, plus Prepay or
  Postpay decision requirements, are documented without claiming false hard
  stops.
- Billing alerts, quota alerts, retention, deletion, abuse controls, and
  rollback are documented.
- Server-side breaker, rollback verification, monitoring, and post-deploy
  evidence requirements are documented.
- App Check is correctly scoped as attestation only, with a separate auth/quota
  topology blocker.
- Provider data-handling, log-sharing/training, ZDR, and grounding tradeoff
  blockers are documented.
- OpenAI web-search controls are documented: professional-domain allowlist,
  citations, source metadata, high reasoning default, and deep-research cost
  limits.
- Linked follow-up issues exist for the hard blockers before implementation.
- The monetization posture is documented as workflow/evidence, not certainty.
- The answer about user Gemini subscriptions is explicit and evidence-backed.
- The answer about user ChatGPT subscriptions is explicit and evidence-backed.
- Redteam review and deployment-manager review are listed as required gates.

## Task breakdown

1. [#48](https://github.com/kenleren/MyArtCollection/issues/48): record the
   one-project broker approval, provider choice, environment, and billing
   topology. Required review: `codex-deployment-manager`, plus the human owner
   decision copied into GitHub.
2. [#49](https://github.com/kenleren/MyArtCollection/issues/49): prepare
   deployment gates, kill-switch/rollback runbook, monitoring, alerting, and
   budget/quota evidence. Required review: `codex-deployment-manager`.
3. [#50](https://github.com/kenleren/MyArtCollection/issues/50): design broker
   auth, App Check, entitlement, replay, revocation, and quota policy for beta
   research jobs. Required review: `codex-redteam-review`.
4. [#51](https://github.com/kenleren/MyArtCollection/issues/51): write the
   broker contract, payload minimization rules, and telemetry/redaction
   addendum. Required skill: `codex-task-plan`, then `codex-task-work`, then
   `codex-redteam-review`.
5. [#52](https://github.com/kenleren/MyArtCollection/issues/52): resolve
   provider data-handling, ZDR, professional-source rights, and grounding
   tradeoff guardrails. Required review: `codex-redteam-review`.
6. Only after the above blockers are accepted, plan any broker implementation.
   Required skill: `codex-task-plan`, then `codex-task-work`, then
   `codex-task-review`, `codex-redteam-review`, and `codex-deployment-manager`.

## Open human decisions

- Approve or reject paid AI/backend work for beta after this gate.
- Confirm OpenAI as the first paid research provider, with `gpt-5.4` and high
  reasoning as the MVP default.
- Confirm whether `my-art-collections` uses a dedicated billing account or a
  shared billing account with explicitly documented weaker isolation.
- Confirm the named human billing owner and deployment owner.
- Confirm OpenAI project/account owner, API-key custody, usage limits, and alert
  recipients.
- Confirm Prepay or Postpay for Gemini API billing only if Gemini is later
  enabled as a fallback or alternate provider.
- Confirm whether the initial monthly ceiling stays at `USD 25` or is adjusted.
- Confirm whether internal beta research is invite-only or broader.
- Confirm when monetized research should start, and what the first non-free cap
  is.
- Confirm whether any future residency requirement exists that would justify a
  Vertex/Agent Platform move.

## Recommended next Project status

`For Review` after this rework is checked and reviewed again.

Reason: the research/spec deliverable for #42 is complete once this document is
reviewed. It should not move to `Complete` if reviewers still find blockers.
Paid backend implementation remains blocked until #48 through #52 are accepted
and any required human decisions are copied into GitHub.
