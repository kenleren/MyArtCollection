# Costed AI Backend Gate Spec

Status: Proposed
Issue: [#42](https://github.com/kenleren/MyArtCollection/issues/42)
Scheduling evidence: [issue comment](https://github.com/kenleren/MyArtCollection/issues/42#issuecomment-4883398463)
Implementation evidence: [issue comment](https://github.com/kenleren/MyArtCollection/issues/42#issuecomment-4883425657)
Review rework evidence: [issue comment](https://github.com/kenleren/MyArtCollection/issues/42#issuecomment-4883461683)

## Problem statement

MyArtCollection needs a hard decision gate before any paid AI or backend path is
implemented. The repo already wants a thin server-side AI broker, but #42
exists because paid backend work changes privacy, abuse, deployment, and cost
risk immediately.

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

## Requirements

Any approved paid AI/backend implementation must satisfy all of the following:

- Local-first product posture remains intact.
- No mobile client secrets.
- No direct mobile AI calls by default.
- Paid AI/backend traffic runs in a dedicated paid backend project, separate
  from Firebase App Distribution / crash-triage concerns.
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
- Redteam review and deployment-manager review are required before any paid
  backend is released beyond tightly controlled beta.

## Hard release blockers

The following are not recommendations. They are release blockers before any
paid backend implementation, Blaze enablement, live Firebase Functions broker,
Gemini API billing, provider call, or external-source automation can be started:

- [#48](https://github.com/kenleren/MyArtCollection/issues/48): paid AI
  backend approval and billing topology decision record.
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
| B. Thin server broker on Firebase Functions 2nd gen using Gemini Developer API | App sends minimal payload to broker; broker calls Gemini Developer API | Best match for repo architecture; lower-friction cost profile for interactive MVP use; easy to keep secrets server-side; simpler than Vertex for MVP | Requires Blaze; spend caps are not the only control because project and billing-account caps are experimental and can overrun during latency; no enterprise residency guarantees | Recommended first paid path, but only after gate approval |
| C. Thin server broker on Firebase Functions 2nd gen using Vertex / Gemini Enterprise Agent Platform | Same broker pattern, but provider is Vertex/Agent Platform | Better org-level governance, regional endpoint choice, richer GCP controls, can use some Google Cloud credits | More platform complexity; interactive pricing is not simpler; global endpoint does not guarantee residency; overkill for MVP beta | Defer unless separate human need for governance/residency outweighs complexity |
| D. Do not build paid backend yet | Hold all paid AI/backend work until monetization and operations are clearer | Lowest risk, no billing exposure, no new privacy surface | Delays AI research feature work | Correct stance until this gate is accepted |

## Recommended approach

Decision:

1. Do not implement any paid AI/backend workflow until this spec is accepted.
2. When accepted, approve only Option B as the first paid path:
   Firebase Functions 2nd gen broker, server-side Gemini Developer API, no
   Firebase AI Logic direct client integration.
3. Keep Vertex/Agent Platform as a later escalation path, not the starting
   point.

### Why this is the recommended first path

- It matches the existing repo architecture and privacy posture.
- It avoids shipping secrets or a paid API surface directly in the app.
- Current official pricing and setup constraints make Gemini Developer API
  Flash-Lite / Flash the lower-friction interactive starting point.
- It preserves room to add allowlisted professional-source lookups, schema
  validation, retention controls, and monetization later.

### Mandatory architecture guardrails

- Dedicated paid backend project for AI work. Do not attach paid AI broker work
  to the same Firebase/GCP project used for App Distribution or other existing
  beta operations.
- The paid AI beta and any later production paid AI backend must have an
  environment topology decision before rollout. Default topology:
  - beta paid AI backend project: placeholder `myartcollection-ai-beta`,
  - future production paid AI backend project: placeholder
    `myartcollection-ai-prod`,
  - only the beta project may be considered for Blaze during MVP beta,
  - production Blaze enablement requires a separate human approval and
    deployment-manager review.
- Prefer a dedicated billing account for the AI backend project if the team
  wants stronger blast-radius isolation. If a shared billing account is used,
  configure both project-level Gemini spend caps and billing-account-level
  controls, and still treat them as supplementary because spend caps are
  experimental and can overrun during processing latency.
- Record whether Gemini API billing is Prepay or Postpay before rollout. If
  Postpay is chosen, the `USD 25/month` ceiling is a policy ceiling, not a hard
  technical stop, unless separate quota and shutdown controls enforce it.
- Broker-only architecture:
  - app -> broker,
  - broker -> Gemini API,
  - broker -> allowlisted professional/public sources,
  - broker -> app with structured citations and uncertainty.
- No generic direct model access from Flutter.
- No Google Search grounding in the first paid rollout. Start with
  allowlisted professional/public sources and free/public collection APIs first.

### Approval record required before any paid work

No paid backend task may start until #48 records all of the following:

- named human billing owner,
- named human deployment owner,
- explicit approval or rejection of Blaze for the beta paid backend project,
- approved Firebase/GCP project ids or final placeholders,
- approved billing account topology,
- approved Prepay or Postpay Gemini API billing posture,
- approved monthly policy ceiling,
- accepted deployment-manager review,
- accepted redteam/privacy review when the decision changes data boundaries.

Chat approval is not sufficient unless it is copied into the linked GitHub
issue with the decision, date, owner, and scope.

### Recommended beta cost ceiling

- Internal total ceiling for the dedicated AI backend project: `USD 25/month`.
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
- Budget alerts for the dedicated AI backend project at 50%, 70%, 80%, and 90%
  of the monthly ceiling.
- Gemini API project-level spend cap configured for the AI backend project when
  available, plus billing-account-level caps or alerts according to the chosen
  billing topology.
- Quota alerts for the broker project and any Gemini-related quotas in Cloud
  Monitoring.
- Server-side breaker before client-side controls: the broker must be able to
  reject paid research requests at the server before calling a provider, even
  if a stale app build still shows the research entry point.
- Written manual kill switch, in order:
  1. set server-side breaker to reject all paid research traffic,
  2. set product/Remote Config flag `online_research_enabled=false`,
  3. disable or deny the broker route/function,
  4. disable, rotate, or revoke provider credentials/API keys,
  5. lower provider quotas where possible,
  6. disable billing on the dedicated paid backend project only as a last
     resort.
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
  rollout. If ZDR is unavailable, the decision record must state why the
  provider retention behavior is acceptable for beta collector content.
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

### Explicit answer: can a user's Gemini Pro / AI Pro subscription be used by the app?

No, not as the default architecture for MyArtCollection.

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

## Risks and mitigations

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| Direct client AI abuse | Paid surface can be replayed or scripted | Do not approve Firebase AI Logic direct client calls by default |
| Surprise spend | Budgets are alerts, spend caps are experimental, and processing latency can overrun limits | Dedicated paid project, low policy ceiling, Prepay/Postpay decision, project spend cap, quota caps, server breaker, manual kill switch, optional last-resort billing disable |
| Billing-account cross-talk | Shared billing accounts can blur ownership and blast radius | Prefer dedicated billing account; if shared, configure both project-level and billing-account controls and record the weaker isolation |
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
  Gemini Developer API.
- The default rejected path is clear: Firebase AI Logic direct client use.
- A dedicated paid backend project requirement is documented.
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
- Linked follow-up issues exist for the hard blockers before implementation.
- The monetization posture is documented as workflow/evidence, not certainty.
- The answer about user Gemini subscriptions is explicit and evidence-backed.
- Redteam review and deployment-manager review are listed as required gates.

## Task breakdown

1. [#48](https://github.com/kenleren/MyArtCollection/issues/48): create the
   dedicated paid backend approval, environment, and billing topology decision
   record. Required review: `codex-deployment-manager`, plus human owner
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
- Confirm whether the AI backend gets its own billing account, or only its own
  project.
- Confirm the named human billing owner and deployment owner.
- Confirm Prepay or Postpay for Gemini API billing.
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
