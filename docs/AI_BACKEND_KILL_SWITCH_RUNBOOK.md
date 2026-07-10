# AI Backend Kill Switch Runbook

Status: Proposed
Issue: [#49](https://github.com/kenleren/MyArtCollection/issues/49)
One-project reconciliation: #190
Parent: [#42](https://github.com/kenleren/MyArtCollection/issues/42)  
Related blockers: [#48](https://github.com/kenleren/MyArtCollection/issues/48), [#50](https://github.com/kenleren/MyArtCollection/issues/50), [#51](https://github.com/kenleren/MyArtCollection/issues/51), [#52](https://github.com/kenleren/MyArtCollection/issues/52)

## Problem statement

Archivale needs a decision-ready, operator-usable runbook for stopping
paid AI/backend traffic before any broker rollout. A client-only switch is not
enough because stale builds can still reach a server endpoint, and provider
spend can continue after a UI flag is turned off.

This runbook defines the shutoff order, monitoring surface, alert ownership,
smoke checks, rollback triggers, and evidence required before any paid broker
path can be exposed to testers.

## Context and evidence

### Repo-local evidence

- [README.md](../README.md) and [ARCHITECTURE.md](ARCHITECTURE.md) keep the app
  local-first and require a thin server-side AI broker, never direct vendor
  calls from Flutter.
- [COSTED_AI_BACKEND_GATE_SPEC.md](COSTED_AI_BACKEND_GATE_SPEC.md) already makes
  `#49` a hard blocker for any paid backend rollout and defines the intended
  kill-switch order.
- [FIREBASE_TELEMETRY_POLICY.md](FIREBASE_TELEMETRY_POLICY.md) allows
  non-sensitive Remote Config flags, keeps `online_research_enabled=false` as a
  safe default, and bans AI prompts, responses, queries, citations, and source
  URLs from telemetry.
- [FIREBASE_APP_DISTRIBUTION.md](FIREBASE_APP_DISTRIBUTION.md) treats Firebase
  App Distribution as a separate beta-delivery layer and documents Remote
  Config gating only for Android release builds with explicit Dart defines.
- [lib/app/config/app_feature_flags.dart](../lib/app/config/app_feature_flags.dart)
  already defaults `online_research_enabled` to `false`, uses `setDefaults`,
  and falls back to safe local defaults on fetch failure.
- [test/app_feature_flags_test.dart](../test/app_feature_flags_test.dart)
  already verifies that the flag stays off when release/Firebase/Remote Config
  gates are missing.

### Current vendor facts that shape the runbook

- OpenAI recommends the Responses API hosted `web_search` tool for new web
  search integrations and supports source-return controls for search results.
- OpenAI project scoping supports project-level usage tracking and budgets, and
  project-scoped API keys can be restricted or revoked by owners.
- OpenAI rate-limit headers expose project-scoped request and token limits,
  which makes project-level monitoring practical.
- Firebase Remote Config supports in-app defaults via `setDefaults()` and can
  fetch updated values in real time, but safe local defaults must still exist.
- Firebase Functions management supports deploy, modify, and delete operations,
  and function runtime options can cap max instances.
- Firebase/Google Cloud budgets are alerts, not hard stops.
- Google Cloud's billing-disable automation can stop project services, but
  Google explicitly warns about notification delay and possible extra spend
  before shutoff completes.
- Cloud quota alerts and Cloud Monitoring alerting policies can notify operators
  on project-level quota and service metrics.

## Non-goals

- No live service changes in this task.
- No approval to deploy a broker, enable Blaze, enable Firebase Functions, or
  create provider credentials.
- No reading, printing, validating, or mutating credentials, Firebase config,
  or tester lists.
- No approval for direct mobile AI calls.
- No approval for Gemini as the first paid provider.

## Requirements

Any paid AI/backend rollout must satisfy all of the following before first
tester exposure:

- The AI broker is isolated by codebase, function, runtime identity, IAM,
  provider credentials, Firestore collections, breaker, quotas, and rollback
  target inside the sole approved project, `my-art-collections`.
- OpenAI is the first paid provider, using the Responses API hosted
  `web_search` path with `gpt-5.4` and high reasoning by product decision.
- The server can reject paid research traffic before any provider call is made.
- The product has a separate client-visible kill flag:
  `online_research_enabled=false`.
- The broker can be disabled or denied independently of the client flag.
- The provider credential path can be disabled or revoked independently of the
  broker path.
- Budget alerts, quota alerts, and error alerts are configured before rollout.
- Named human roles exist for billing ownership, deployment ownership, and a
  backup responder.
- The release watch window, rollback triggers, and smoke checks are written and
  rehearsed in a dry run.
- Deployment-manager review receives evidence for all control layers.

## Options considered

| Option | Summary | Pros | Cons | Outcome |
| --- | --- | --- | --- | --- |
| A. Remote Config only | Hide the client entry point with `online_research_enabled=false` | Fast and already aligned with app code | Fails open for stale builds or direct endpoint traffic | Reject |
| B. Provider-key-only shutdown | Revoke the OpenAI key when spend or abuse appears | Strong last-mile stop | Too coarse, slower to verify, disrupts all traffic at once, harder recovery | Reject as primary control |
| C. Layered kill switch | Server breaker -> client flag off -> route deny/function disable -> provider key revoke -> quota reductions -> billing disable last | Reversible, narrow blast radius first, works with stale clients, matches repo gate spec | Requires more setup and evidence | Recommended |

## Recommended approach

Use a layered, server-first kill switch. The shutdown order must be:

1. Enable a server-side breaker that rejects all paid research requests before
   any provider call.
2. Publish `online_research_enabled=false` through Remote Config and keep the
   in-app default `false`.
3. Disable or deny the broker route/function.
4. Disable or revoke the provider credential or service-account access.
5. Lower quotas or usage ceilings where the platform allows it.
6. Disable billing on the shared `my-art-collections` project only as an
   explicit owner-approved last resort after accounting for every affected
   Firebase, Play Billing, distribution, and AI surface.

This sequence is recommended because it stops spend at the narrowest layer
first, leaves recovery paths intact, and avoids jumping straight to broad,
destructive billing actions.

## Control matrix

| Layer | Purpose | Expected owner | Verification target | Recovery note |
| --- | --- | --- | --- | --- |
| Server breaker | Stop provider-bound traffic before spend | Deployment owner | Request rejected before provider call | Remove breaker only after root cause and smoke checks pass |
| Remote Config flag | Remove product entry points for fresh clients | Deployment owner | `online_research_enabled=false` published and fetched by enabled release builds | Keep local default `false`; only re-enable after breaker stays off and backend is healthy |
| Route deny / function disable | Block endpoint reachability | Deployment owner | Endpoint returns rejection without provider activity | Prefer reversible deny before delete |
| Provider key revoke / access removal | Stop any remaining provider calls | Billing owner or OpenAI project owner | Provider-auth failure on isolated operator check | Create replacement key only after deployment-manager approval |
| Quota reduction | Narrow remaining blast radius | Billing owner | Lower ceilings visible in project/provider console | Restore only after the incident postmortem identifies cause |
| Billing disable | Last-resort shared-project stop | Billing owner plus deployment owner | Project billing disabled and every affected surface recorded | Treat as a cross-service recovery incident, not same-window rollback |

### AI And Play Billing Independence

The AI and Play Billing controls share `my-art-collections` but must not share
runtime authority or routine rollback:

- AI controls target codebase `broker`, function `artResearchBroker`, the
  research runtime identity, provider credential, broker breaker, and broker
  records only.
- Play Billing uses codebase `play-billing`, callable
  `acceptPlayBillingDisclosure`/`revokePlayBillingDisclosure`/
  `verifyPlaySubscription`, a distinct runtime identity, Android Publisher IAM,
  and named Firestore database
  `archivale-play-billing` with database-conditioned IAM and deny-all client
  rules, as defined in `PLAY_BILLING_GATE_SPEC.md`.
- AI responders must not disable the billing callable, alter billing
  database/rules/IAM, revoke Android Publisher access, or use
  `brokerDurableEntitlements` as payment authority.
- Billing failure or rollback fails plan access to Free but does not grant or
  revoke AI research consent and does not change the AI breaker.
- `online_research_enabled=false` stops online professional-source research
  entry points only. It does not control local on-device AI and is not a
  subscription or payment switch.

Project-wide billing disablement is the only layer here that couples the blast
radius. It may stop the AI broker, Play verification, Auth/App Check,
telemetry, and App Distribution together; it therefore requires explicit owner
approval, a service inventory, and a cross-service recovery plan.

AI rollback must not delete the billing database or remove its TTL/index/rules
target. Billing can contain verified delivery committed before acknowledgement
or acknowledgement-unknown recovery state. A billing-specific shutdown must
stop new purchase starts while preserving a reviewed path for bounded
verification/finalization of those records, unless an active security incident
requires full denial and the unresolved/refund impact is explicitly accepted.
Database deletion is never same-window rollback.

Shutdown and recovery must not bypass billing attempt ownership. In-flight,
delivery-committed, and acknowledgement-in-progress records stay protected
until their 90-second owner lease expires; acknowledgement-unknown records stay
closed until the 15-second cooldown expires. Recovery must atomically advance
the server attempt generation/nonce and use exact-owner-and-phase CAS. It must
never restart acknowledgement under a live owner or regress acknowledged final
state to acknowledgement-unknown.

## Runbook

### Preconditions before any rollout

- `#48` confirms `my-art-collections` as the only Firebase/GCP project and names
  the broker isolation controls, billing topology, monthly cost ceiling,
  OpenAI project owner, and alert recipients.
- `#50` defines broker identity, App Check role, quota key, replay rejection,
  and revocation behavior.
- `#51` defines request/response contract, payload minimization, and telemetry
  redaction.
- `#52` records provider data handling, retention, and any ZDR decision.
- The broker exposes a breaker control that fails closed.
- The app default remains `online_research_enabled=false`.
- A reversible route-deny path exists for the broker.
- The provider key is project-scoped and not shared with unrelated workloads.

### Release-window watch

For the first paid beta rollout:

- Start operator watch 30 minutes before enablement.
- Keep continuous watch for the first 2 hours after enablement.
- Perform scheduled checks at +4 hours, +8 hours, and +24 hours.
- Do not close the watch until smoke checks and alert health are recorded.

For later controlled betas after one successful rollout:

- Start watch 15 minutes before enablement.
- Keep continuous watch for 60 minutes after enablement.
- Perform scheduled checks at +4 hours and next-day.

### Alert recipients

The minimum responder set is:

- Billing owner: primary for spend, budget, quota, and billing-disable actions.
- Deployment owner: primary for breaker, Remote Config, and route/function
  actions.
- Backup responder: secondary for all alerts when either owner is unavailable.

Notification channels must include:

- direct email for all three roles,
- one shared escalation channel,
- one phone/pager-capable channel for budget >= 80%, provider auth failure, or
  post-shutoff traffic that still appears paid.

### Required monitoring dashboards and signals

Before rollout, operators must have quick access to:

- Cloud Billing budget status for `my-art-collections`, with the isolated
  broker workload identified by its codebase/runtime/provider signals.
- Cloud Billing anomaly view for the billing account used by that project.
- Cloud quota usage and alert status for the broker project.
- Function metrics: invocations, concurrency, errors, latency, and instance
  count.
- Broker application metrics: paid request attempts, breaker rejects, provider
  call count, provider auth failures, and quota rejects.
- OpenAI project usage view for requests, tokens, and project budgets.
- Remote Config parameter history for `online_research_enabled`.

### Alert thresholds

Use these minimum thresholds unless `#48` approves stricter ones:

- Budget alerts: 50%, 70%, 80%, 90% of monthly ceiling.
- Cost anomaly: notify on any anomaly detected for `my-art-collections` or the
  isolated broker provider scope; project totals are not assumed to be AI-only.
- Function error rate: alert at >2% 5xx over 5 minutes.
- Provider auth failure: alert at >3 failures over 5 minutes.
- Breaker rejects: alert on any non-zero reject count outside a planned
  shutdown window.
- Quota rejection: alert at >1 rejection over 10 minutes.
- Latency: alert at p95 >30 seconds over 10 minutes.
- Paid request activity outside an approved release window: alert immediately on
  any non-zero traffic.

## Kill-switch procedure

### Trigger conditions

Run this procedure when any of the following happens:

- spend exceeds the approved release-window expectation,
- budget reaches 80% before the planned point in the month,
- paid traffic appears outside an approved release window,
- quota abuse or replay behavior is detected,
- provider failures or retries could amplify spend,
- telemetry or logs appear to contain banned data classes,
- users can still start paid research after the feature should be off,
- reviewers request rollback during deployment-manager watch.

### Step 1: Freeze the rollout

- Stop enabling new testers or release changes.
- Record the incident start time and the suspected trigger.
- Keep all evidence sanitized; do not paste prompts, citations, URLs, or
  credential data into incident notes.

Verification:

- Release promotion is paused.
- A single incident thread exists with owner assignment.

### Step 2: Enable the server-side breaker

Action:

- Switch the broker to reject all paid research traffic before any OpenAI call.

Expected response:

- HTTP 503 or 429 with a fixed sanitized error code and no provider attempt.

Verification:

- A known operator test request returns breaker rejection.
- Provider call count stops increasing after the breaker is enabled.
- Breaker-reject metrics increase while provider-usage metrics stay flat.

Recovery note:

- Do not clear the breaker until the root cause is identified and post-breaker
  smoke checks pass.

### Step 3: Publish `online_research_enabled=false`

Action:

- Set the Remote Config flag to `false`.

Verification:

- Parameter history shows the latest published value is `false`.
- A release build with Remote Config enabled fetches `false`.
- Fresh clients hide or disable the research entry point.

Recovery note:

- This is not sufficient by itself; stale builds may still call the broker.

### Step 4: Deny or disable the broker route/function

Action:

- Apply the pre-approved route deny, unauthenticated invoke deny, or function
  disable path for the broker.
- Use deletion only if the approved deny path is unavailable or ineffective.
- For the checked-in Firebase Functions broker surface, the deploy-addressable
  target is codebase `broker`, function `artResearchBroker`, region
  `us-central1`, project `my-art-collections`:

  ```sh
  firebase deploy --project my-art-collections --only functions:broker:artResearchBroker
  ```

- If the approved rollback requires deleting the deployed function, the command
  shape is:

  ```sh
  firebase functions:delete artResearchBroker --region us-central1 --project my-art-collections
  ```

- Do not run either command without #155 deployment-manager approval and the
  explicit rollback/release window. Do not use `firebase deploy --dry-run` as
  no-deploy evidence because Firebase CLI 15.22.4 warns that dry-run may still
  enable APIs on the target project.

Verification:

- Endpoint access now fails before reaching application logic.
- Function invocations stop or drop to only expected health/operator probes.
- Provider-usage metrics remain flat.

Recovery note:

- Prefer reversible deny over delete so recovery does not depend on a same-day
  redeploy under incident pressure.

### Step 5: Disable or revoke provider credentials

Action:

- Revoke the affected project API key or remove the service account access used
  by the broker.

Verification:

- An isolated operator check against the provider path fails with an auth error.
- No new paid provider usage appears after revocation.

Recovery note:

- Replacement credentials require deployment-manager approval and fresh custody
  evidence before reuse.

### Step 6: Lower quotas or usage ceilings

Action:

- Reduce the remaining project/provider quota headroom where the platform
  supports it.

Verification:

- Updated quota ceilings are visible in project/provider controls.

Recovery note:

- This step narrows blast radius; it is not the primary stop control.

### Step 7: Disable shared-project billing only if all prior controls fail

Action:

- Obtain explicit owner approval to disable billing for `my-art-collections`
  only after recording the impact on the research broker, Play subscription
  verification, Auth/App Check, telemetry, App Distribution, and any other
  project services. There is no narrower project to disable.

Verification:

- Billing status for `my-art-collections` shows disabled.
- Paid broker traffic has stopped.
- Play verification and every other expected affected service are included in
  incident and recovery evidence; no one interprets their outage as payment or
  research state.
- Any `delivery_committed` or `ack_unknown` billing recovery backlog in the
  named database is recorded without token/account identifiers and assigned a
  payment owner before access is removed.

Recovery note:

- Treat this as a last-resort cross-service containment move. Recovery may
  require manual project repair and explicit billing, deployment, payment, and
  privacy review before service returns.

## Smoke checks

These checks must be documented before first rollout and re-run after any
shutdown or recovery:

1. Flag off baseline:
   - release build with Remote Config disabled locally shows research off.
2. Flag on path:
   - release build with approved config shows research on only when broker is
     healthy.
3. Breaker on:
   - request is rejected before provider call.
4. Breaker off:
   - approved request succeeds with citations and expected structured output.
5. Route deny:
   - endpoint is unreachable or denied before broker logic.
6. Provider key revoked:
   - isolated operator probe fails auth without user-content payload.
7. Quota rejection:
   - the system returns a sanitized quota error and does not retry
     uncontrollably.
8. Recovery:
   - after rollback completion, research remains off until explicit re-enable.

## Rollback triggers

Immediate rollback is required when any of the following occurs:

- budget reaches 80% unexpectedly,
- any paid traffic appears outside an approved release window,
- provider auth failures or retries suggest uncontrolled looping,
- error rate exceeds 5% for 10 minutes,
- banned telemetry data classes appear in logs or evidence,
- stale clients can still spend after breaker + flag shutoff,
- rollout owners cannot confirm which control layer is currently active,
- deployment-manager review finds missing evidence for a required control.

## Evidence required for deployment-manager review

Before first paid rollout, `codex-deployment-manager` should require:

- link to this runbook and accepted review comments,
- named billing owner, deployment owner, and backup responder,
- screenshot or export evidence that the default app flag is `false`,
- evidence that the breaker exists and fails closed,
- evidence of the route-deny or function-disable path,
- evidence of OpenAI project scoping, project budget ownership, and key custody
  plan,
- budget alert thresholds and recipients,
- quota alert thresholds and recipients,
- dashboard locations for billing, quota, function, broker, and provider usage,
- dry-run record for breaker on/off, flag off, route deny, and provider-key
  revoke verification,
- release-window watch schedule,
- rollback template and incident owner handoff plan.

After each paid beta rollout, the deployment record should include:

- exact rollout start and end timestamps,
- app build/version and broker revision,
- flag state before and after rollout,
- breaker state before and after rollout,
- alert health summary,
- budget/quota/provider usage summary,
- smoke-check results,
- whether rollback was needed,
- operator sign-off from billing owner and deployment owner.

## Risks and mitigations

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| Client-only shutoff fails open | Stale builds can still spend | Server breaker first, then route deny |
| Shared-project billing blast radius | Last-resort billing disable can stop AI, Play verification, Auth/App Check, telemetry, and distribution together | Use broker breaker, route/runtime IAM, provider revoke, and quotas first; require owner-approved cross-service recovery before project-wide action |
| Key revocation is too coarse | Revoke stops all usage and complicates recovery | Use only after breaker and route controls |
| Budget alerts arrive late | Spend can exceed threshold before alerts arrive | Conservative quotas, breaker, small beta ceiling, last-resort billing disable |
| Route delete under pressure slows recovery | Re-deploy work during incident is brittle | Prefer reversible deny path before delete |
| Unknown operator ownership | No one acts fast enough during spend incident | Named owners and backup responder required before rollout |

## Acceptance checks

This issue is decision-ready when all of the following are true:

- This runbook exists in the repo.
- The kill-switch order is explicit and server-first.
- Remote Config shutoff is documented as a product-layer control, not the only
  control.
- Broker route deny/function disable is documented.
- Provider credential revoke/disable is documented.
- Quota, budget, and billing-disable responses are documented.
- Alert recipients, watch window, smoke checks, and rollback triggers are
  documented.
- Deployment-manager evidence requirements are documented.
- The runbook does not require reading or mutating credentials as part of this
  issue's work.

## Task breakdown

1. `#48`: confirm billing topology, monthly ceiling, OpenAI project ownership,
   and final alert recipient roles. Required review: `codex-deployment-manager`.
2. `#49`: accept this runbook and record any operator-specific values that are
   still open. Required review: `codex-deployment-manager`.
3. `#50`: implement broker auth, quota identity, replay rejection, and revoke
   semantics that the breaker/route controls rely on. Required review:
   `codex-redteam-review`.
4. `#51`: implement broker contract, sanitized error codes, and breaker-safe
   telemetry. Required review: `codex-redteam-review`.
5. `#52`: accept provider data handling, retention, ZDR, and source-rights
   posture before any live collector content leaves the device. Required review:
   `codex-redteam-review`.
6. After blockers are accepted, dry-run the controls in a non-production beta
   environment before any paid tester exposure. Required review:
   `codex-deployment-manager`.

## Open decisions for humans

- Confirm the named billing owner, deployment owner, and backup responder.
- Confirm whether `my-art-collections` uses a dedicated billing account or a
  shared billing account with explicitly documented weaker isolation.
- Confirm the monthly ceiling approved in `#48`.
- Confirm the exact breaker response code and UX copy for shutoff mode.
- Confirm the reversible route-deny mechanism preferred over deletion.
- Confirm whether OpenAI project-level IP allowlisting is required for the
  broker environment.
- Confirm the exact first-beta watch window if tighter than this default.

## Sources

Primary vendor sources checked July 4, 2026:

- OpenAI web search guide: <https://developers.openai.com/api/docs/guides/tools-web-search>
- OpenAI Responses API reference: <https://developers.openai.com/api/reference/resources/responses/methods/create/>
- OpenAI rate limits guide: <https://developers.openai.com/api/docs/guides/rate-limits>
- OpenAI projects help article: <https://help.openai.com/en/articles/9186755-managing-your-work-in-the-api-platform-with-projects>
- OpenAI API key safety: <https://help.openai.com/en/articles/5112595-best-practices-for-api-key-safety>
- OpenAI API key scope/revoke guidance: <https://help.openai.com/en/articles/9132009-how-can-i-view-the-users-or-organizations-associated-with-an-api-key>
- OpenAI IP allowlisting: <https://help.openai.com/en/articles/20001201-ip-allowlisting-for-openai-api>
- Firebase Remote Config: <https://firebase.google.com/docs/remote-config>
- Firebase Remote Config loading strategies: <https://firebase.google.com/docs/remote-config/loading>
- Firebase Functions manage functions: <https://firebase.google.com/docs/functions/manage-functions>
- Firebase pricing plans: <https://firebase.google.com/docs/projects/billing/firebase-pricing-plans>
- Cloud Billing budgets and alerts: <https://docs.cloud.google.com/billing/docs/how-to/budgets>
- Budget notification recipients: <https://docs.cloud.google.com/billing/docs/how-to/budgets-notification-recipients>
- Cost anomalies: <https://docs.cloud.google.com/billing/docs/how-to/manage-anomalies>
- Disable billing with notifications: <https://docs.cloud.google.com/billing/docs/how-to/disable-billing-with-notifications>
- Quota alerts: <https://docs.cloud.google.com/docs/quotas/set-up-quota-alerts>
- Cloud Monitoring alerting policies: <https://docs.cloud.google.com/monitoring/alerts/target-configuration-library>
