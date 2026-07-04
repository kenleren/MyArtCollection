# AI Broker Auth And Quota Spec

Status: Proposed
Issue: [#50](https://github.com/kenleren/MyArtCollection/issues/50)
Parent: [#42](https://github.com/kenleren/MyArtCollection/issues/42)
Related docs:
- [Architecture Plan](ARCHITECTURE.md)
- [Costed AI Backend Gate Spec](COSTED_AI_BACKEND_GATE_SPEC.md)
- [AI Artwork Research Spec](AI_ART_RESEARCH_SPEC.md)
- [Firebase Telemetry Privacy Policy](FIREBASE_TELEMETRY_POLICY.md)

## Problem statement

MyArtCollection needs a broker access-control model before any paid AI endpoint
exists. The first paid AI path is expected to be a thin Firebase-hosted broker
that sends explicit user-approved research requests to OpenAI Responses API web
search using `gpt-5.4` with high reasoning by default. Before that path is
implemented, the repo needs a precise answer to four questions:

- what proves a request came from an approved app,
- what proves which tester or user is asking,
- how quotas and replay protection prevent duplicate or abusive paid calls,
- and how the broker fails closed when the wrong Firebase project or wrong app
  presents a token.

The spec must preserve the repo's local-first posture and must not introduce a
mobile secret or imply that App Check alone identifies a person.

## Context and evidence

### Repo-local evidence

- [Architecture Plan](ARCHITECTURE.md) requires a thin server-side AI broker
  and says AI must never be a direct vendor call from the app.
- [Costed AI Backend Gate Spec](COSTED_AI_BACKEND_GATE_SPEC.md) makes this
  issue a hard blocker before any paid broker, Blaze enablement, or provider
  call is allowed.
- [Firebase Telemetry Privacy Policy](FIREBASE_TELEMETRY_POLICY.md) bans AI
  prompts, responses, citations, research queries, source URLs, and tokens from
  Firebase-bound telemetry.
- The current local research contract already models one request per artwork
  research job with explicit consent and query summary in
  [`lib/app/research/online_research_service.dart`](../lib/app/research/online_research_service.dart)
  and stores provider/job metadata in
  [`lib/app/storage/ai_research_record.dart`](../lib/app/storage/ai_research_record.dart).

### Current vendor facts that shape the trust model

- Firebase states that App Check protects backend resources by attesting that
  requests come from the authentic app or an untampered device. Firebase also
  states that App Check and Firebase Authentication are complementary: App Check
  is app or device attestation, while Firebase Authentication is user
  authentication.
- Firebase says custom backends must verify App Check tokens on every request.
  A successful verification means the token originated from an app belonging to
  that Firebase project.
- Firebase App Check decoded tokens expose `app_id`, `sub`, `aud`, and `iss`.
  The documented `aud` is a two-element array containing the Firebase project
  number and project ID, and the documented `iss` format is
  `https://firebaseappcheck.googleapis.com/<PROJECT_NUMBER>`.
- Firebase Auth decoded ID tokens expose `uid`, `aud`, and `iss`. The
  documented `aud` equals the Firebase project ID, and the documented `iss`
  format is `https://securetoken.google.com/<PROJECT_ID>`.
- Firebase says `verifyIdToken()` does not check revocation unless the server
  explicitly asks for revocation checking.
- Firebase supports anonymous authentication as a temporary account model. It
  also documents that anonymous sign-up is quota-limited and, with Identity
  Platform enabled, can be auto-cleaned up after 30 days.
- Firebase App Check replay protection exists, but the documented Cloud
  Functions enforcement and one-time token consumption path is for callable
  functions. Using replay protection also adds latency and does not replace
  application-level idempotency.
- OpenAI's current docs say new web-search integrations should use the
  Responses API `web_search` tool, and current model guidance recommends
  `gpt-5.5` for most new reasoning workloads. This repo deliberately keeps
  `gpt-5.4` as the initial broker default by product decision from #42.

Primary sources:

- Firebase App Check overview:
  <https://firebase.google.com/docs/app-check>
- Verify App Check tokens from a custom backend:
  <https://firebase.google.com/docs/app-check/custom-resource-backend>
- App Check enforcement:
  <https://firebase.google.com/docs/app-check/enable-enforcement>
- App Check for Cloud Functions callable replay protection:
  <https://firebase.google.com/docs/app-check/cloud-functions>
- Verify Firebase Auth ID tokens:
  <https://firebase.google.com/docs/auth/admin/verify-id-tokens>
- Manage Firebase Auth sessions and revocation:
  <https://firebase.google.com/docs/auth/admin/manage-sessions>
- Anonymous auth for Flutter:
  <https://firebase.google.com/docs/auth/flutter/anonymous-auth>
- Firebase Admin `DecodedAppCheckToken` reference:
  <https://firebase.google.com/docs/reference/admin/node/firebase-admin.app-check.decodedappchecktoken>
- Firebase Admin `DecodedIdToken` reference:
  <https://firebase.google.com/docs/reference/admin/node/firebase-admin.auth.decodedidtoken>
- Callable Functions protocol/App Check context:
  <https://firebase.google.com/docs/functions/callable-reference>
- OpenAI web search guide:
  <https://developers.openai.com/api/docs/guides/tools-web-search>
- OpenAI reasoning guidance:
  <https://developers.openai.com/api/docs/guides/reasoning>

## Non-goals

- No paid endpoint implementation in this issue.
- No approval for direct mobile vendor calls.
- No mobile client secrets.
- No dependence on Firebase App Distribution tester membership as runtime auth.
- No commitment yet to a permanent end-user account system.
- No approval for Firestore, Storage, or other cloud data storage for artwork
  records in the broker project.

## Requirements

Any approved paid broker implementation must satisfy all of the following:

- App Check is treated as app or device attestation only, not as user
  authentication.
- Every paid broker request must require both:
  - a valid App Check token from the broker Firebase project, and
  - a valid Firebase Auth ID token from the same broker Firebase project.
- The distribution/telemetry Firebase project and the paid broker Firebase
  project must stay separate.
- Wrong-project App Check tokens and wrong-project Auth ID tokens must fail
  closed before any provider call.
- The first broker identity model must work without a mandatory user-facing
  account signup flow.
- Quotas must be keyed to a revocable identity, not to App Check alone and not
  to App Distribution tester email.
- Duplicate retries must not create duplicate paid provider calls.
- Revocation must exist for both the app surface and the user/tester surface.
- Logs and telemetry must not include raw tokens, raw UIDs, prompts, responses,
  research queries, source URLs, or other banned user/content data.
- Redteam review is mandatory before any paid rollout.

## Options considered

| Option | Summary | Pros | Cons | Outcome |
| --- | --- | --- | --- | --- |
| A. App Check only | Require App Check and no Firebase Auth identity | Lowest UX friction | Cannot identify or revoke a tester/user cleanly; quota reduces to app-level only; App Check is explicitly not user auth | Reject |
| B. App Check plus Firebase anonymous auth in a dedicated broker project | Require both App Check and a Firebase Auth anonymous ID token; allow broker only for approved app IDs and approved UIDs | Matches local-first/no-account posture, gives revocable quota subject, avoids permanent signup, keeps app attestation and user identity separate | Anonymous UID can churn on reinstall unless later linked to a durable account | Recommended first path |
| C. App Check plus mandatory Apple/Google/email login before any broker call | Require durable user login from day one | Stronger person-level identity and entitlement future | Adds account UX and privacy surface before the product needs it | Defer |
| D. App Distribution tester membership as access control | Reuse beta tester list as runtime authorization | Operationally simple in theory | Not a documented runtime trust signal; not present in broker request tokens; poor revocation and bad separation of concerns | Reject |

## Recommended approach

Decision:

1. Do not implement the paid broker until this spec and the other #42 blockers
   are accepted.
2. When implementation begins, use Option B first:
   App Check plus Firebase anonymous auth in a dedicated broker Firebase
   project, with Cloud Functions 2nd gen callable entrypoints for the paid
   "start research" path.
3. Treat durable login and multi-device entitlements as later work, not as a
   prerequisite for the first paid beta.

### What would make this recommendation wrong

This recommendation should be revisited if any of the following becomes true:

- the callable-function path cannot support the required payload shape, size, or
  background execution model,
- closed beta needs person-level entitlement portability across reinstalls and
  devices immediately,
- or Firebase anonymous auth is judged too fragile for tester approval and
  revocation workflow.

If any of those happen, the next candidate is still not "App Check only". The
next candidate is a server-verified auth model with a stronger user identity.

### Firebase project topology

Use two Firebase/GCP projects with different purposes:

1. Distribution/telemetry project:
   - Firebase App Distribution and the limited telemetry surfaces already
     allowed by repo policy.
   - No paid OpenAI broker secrets.
   - No authority over broker Auth or broker App Check decisions.

2. Paid broker project:
   - Firebase Authentication for broker identity.
   - Firebase App Check for broker app attestation.
   - Cloud Functions 2nd gen for broker entrypoints.
   - No approval from this spec for Firestore/Storage artwork persistence.
   - This project is the only project whose Auth/App Check tokens the broker
     trusts.

Implication:

- The mobile app may need to be registered in both projects in the future, but
  the broker must trust only tokens minted under the paid broker project.
- A token minted under the distribution project is a wrong-project token for the
  broker, even if it came from the same shipped app binary.

### Trust model

For the first paid broker entrypoint, require this chain:

1. Valid App Check token proves the request came from an approved app instance
   registered in the broker project.
2. Valid Firebase Auth ID token proves which broker user or tester is asking.
3. Server-side allowlist/entitlement check decides whether that UID may spend
   paid broker budget.
4. Server-side quota and replay checks decide whether this specific request may
   run now.
5. Only then may the broker call OpenAI.

App Check without Auth is insufficient. Auth without App Check is insufficient.

### Token verification and audience checks

The broker must verify both tokens under the broker project configuration and
must explicitly assert the documented audience and issuer after verification.
This second check is intentional defense against misconfiguration.

| Token | Required checks | Expected project binding |
| --- | --- | --- |
| App Check token | Verify with Firebase Admin App Check in the broker project. Require `aud` to contain the broker project number and broker project ID. Require `iss` to equal `https://firebaseappcheck.googleapis.com/<BROKER_PROJECT_NUMBER>`. Require `sub`/`app_id` to be in the broker allowlist of approved Firebase app IDs. | Broker Firebase project number and ID |
| Firebase Auth ID token | Verify with Firebase Admin Auth in the broker project and require revocation checking on paid endpoints. Require `aud` to equal the broker project ID. Require `iss` to equal `https://securetoken.google.com/<BROKER_PROJECT_ID>`. Require non-empty `uid`. For the first paid beta, require `firebase.sign_in_provider=anonymous` unless a later spec approves additional providers. | Broker Firebase project ID |

Wrong-project handling rules:

- If App Check verification fails because the token belongs to another Firebase
  project, return a generic unauthorized response and classify the event as
  `wrong_project_app_check`.
- If Auth verification fails because the token belongs to another Firebase
  project, return a generic unauthorized response and classify the event as
  `wrong_project_auth`.
- Never accept a request where App Check verifies under one project and Auth
  verifies under another.

### Tester and user identity

Recommended first identity subject:

- `uid` from Firebase anonymous auth in the broker project.

Why anonymous auth is justified here:

- The product rule says the app should work without an app account.
- App Check does not identify a person or tester.
- Anonymous auth gives a revocable, server-verifiable identity with minimal UX.
- The account can later be linked to Apple, Google, or email without changing
  the broker's requirement that a request carry a valid Auth ID token.

Closed-beta authorization rule:

- Firebase App Distribution membership is not enough.
- The broker must check a server-side approval record keyed by broker `uid`
  before allowing paid traffic.
- A reinstall that creates a new anonymous UID should require re-approval in
  the closed beta unless a later durable-account flow is approved.

### Quota key derivation

Primary quota subject:

```text
quota_subject_v1 = HMAC_SHA256(
  quota_secret,
  "broker-v1|project:" + auth.aud +
  "|app:" + app_check.app_id +
  "|uid:" + auth.uid +
  "|feature:art_research"
)
```

Rules:

- Use the HMAC output or another one-way derived key for storage and metrics;
  do not store raw UID as the main quota key.
- Do not derive quota from App Distribution tester email, raw email address,
  device fingerprint, or a client-generated install ID alone.
- App-level limits and global spend limits still exist, but they are secondary
  guards. The primary per-request quota subject is the revocable Auth identity
  bound to an attested app.

Minimum quota dimensions:

- per `quota_subject_v1` daily paid jobs,
- per `quota_subject_v1` concurrent running jobs,
- per approved `app_id` request rate,
- broker-global spend and concurrency ceilings,
- optional coarse edge throttles for obvious abuse bursts.

### Replay prevention and idempotency

Use two layers, because App Check replay protection alone does not solve paid
duplicate calls caused by normal client retries.

Layer 1: App Check replay protection on sensitive callable endpoints

- For the paid "start research" callable function, require App Check
  enforcement.
- When the endpoint is implemented, consume the App Check token after
  verification on that callable endpoint so one limited-use token cannot be
  replayed.
- This is recommended only on the sensitive paid-start path because Firebase
  documents added latency for token consumption.

Layer 2: broker idempotency ledger

- Every client request must include a locally persisted `request_id` UUID.
- The broker must derive an idempotency key from:
  - `quota_subject_v1`,
  - `request_id`,
  - normalized request payload hash.
- The broker must store a short-lived ledger entry before the provider call.
- Retries with the same idempotency tuple must return the original accepted job
  handle or completed result, not start a second OpenAI call.
- Reusing the same `request_id` with a different payload hash must fail as a
  conflict.

Recommended initial TTL for the idempotency ledger:

- 24 hours.

This recommendation is conservative because mobile retries and delayed
foreground resumes can happen well after the original request started.

### Revocation path

User/tester revocation:

- Remove the broker `uid` from the server-side allowlist or entitlement record.
- Revoke refresh tokens or disable the Firebase Auth user when immediate access
  removal is required.
- Paid endpoints must verify ID tokens with revocation checking enabled.

App revocation:

- Remove the Firebase App ID from the broker allowlist of approved `app_id`
  values.
- If an app build or platform registration is no longer trusted, its App Check
  token may still verify structurally, but the broker allowlist check must deny
  it.

Emergency kill switch:

- A broker-wide shutoff remains the responsibility of [#49](https://github.com/kenleren/MyArtCollection/issues/49),
  but #50 requires the auth/quota layer to honor a deny-all switch before any
  provider call.

### Failure semantics and logging

- Fail closed on any missing or invalid token, wrong-project token, missing
  entitlement, consumed App Check token, or quota breach.
- Return generic unauthorized, forbidden, or quota-exceeded responses without
  echoing token claims, project IDs, or allowlist details to the client.
- Broker logs may record only fixed reason codes and one-way-derived quota
  subject identifiers. They must not record raw tokens, raw UID, prompts,
  citations, source URLs, or user content.

## Risks and mitigations

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| Anonymous UID churn on reinstall | Closed-beta tester may lose approval or quota history | Accept this as a beta constraint, document re-approval, and defer durable-login linking until needed |
| App Check over-trust | App Check does not prove which person is using the app | Require Auth plus allowlist/entitlement checks |
| Duplicate billing from retries | Mobile clients legitimately retry on flaky networks | Require idempotency ledger in addition to limited-use App Check tokens |
| Wrong Firebase project wiring | Dual-project setup makes misconfiguration plausible | Explicit post-verify audience and issuer assertions for both token types |
| Callable-function mismatch with future workload | Large or long-running jobs may outgrow callable constraints | Re-spec the same trust rules on authenticated HTTPS/Cloud Run before changing entrypoint type |

## Acceptance checks and negative tests

No paid rollout is allowed until the following tests exist and pass in the
future implementation:

1. Missing App Check token is rejected before any provider call.
2. Missing Firebase Auth ID token is rejected before any provider call.
3. Valid App Check plus missing Auth is rejected.
4. Valid Auth plus missing App Check is rejected.
5. App Check token from the wrong Firebase project is rejected and classified
   without leaking token contents.
6. Auth ID token from the wrong Firebase project is rejected and classified
   without leaking token contents.
7. App Check token with an `app_id` outside the approved broker allowlist is
   rejected.
8. Revoked or disabled Firebase Auth user is rejected on a paid endpoint.
9. Approved App Distribution tester with no approved broker `uid` is rejected.
10. Reuse of a consumed limited-use App Check token is rejected on the paid
    callable entrypoint.
11. Retry with a fresh valid token but the same idempotency tuple does not
    create a second provider call.
12. Reuse of the same `request_id` with a different payload hash is rejected as
    a conflict.
13. Quota exhaustion for one subject does not block unrelated approved
    subjects.
14. Broker logs and metrics are inspected to prove they do not contain raw
    tokens, raw UIDs, prompts, research queries, or source URLs.

## Task breakdown

1. Finalize the broker request envelope and auth contract in the implementation
   plan for the paid start-research endpoint.
   - Skill: `codex-task-plan`

2. Implement callable broker auth middleware and explicit project/app claim
   checks.
   - Skills: `codex-task-work`, `codex-task-review`
   - Required review: `codex-redteam-review`

3. Add client-side broker identity bootstrap for anonymous auth, App Check
   token acquisition, and persisted `request_id` retries.
   - Skills: `codex-task-plan`, `codex-task-work`
   - Required review: `codex-redteam-review`

4. Implement quota-subject derivation, entitlement/allowlist enforcement, and
   the broker idempotency ledger.
   - Skills: `codex-task-plan`, `codex-task-work`
   - Required review: `codex-redteam-review`

5. Write the negative test pack and rollout evidence for wrong-project,
   revocation, replay, and duplicate-call scenarios.
   - Skills: `codex-task-work`, `codex-task-review`
   - Required review: `codex-redteam-review`, `codex-deployment-manager`

## Open decisions for humans

1. Is anonymous-auth closed beta acceptable for the first paid broker, or is a
   durable account requirement needed before any paid beta?
2. Is a 24-hour idempotency TTL acceptable, or should the operator choose a
   shorter window with stricter client retry behavior?
3. Are Cloud Functions 2nd gen callable limits sufficient for the planned
   artwork image/document payloads, or should the implementation path move to an
   authenticated HTTPS/Cloud Run broker before coding starts?
4. Should the broker project upgrade to Firebase Authentication with Identity
   Platform before rollout to get anonymous-account cleanup and stronger audit
   features?

## Recommendation summary

Do not build the paid broker yet. When #42 is unblocked, the first approved
auth model should be:

- dedicated broker Firebase project,
- App Check required,
- Firebase Auth anonymous ID token required,
- server-side UID allowlist/entitlement check required,
- explicit audience and issuer checks for both token types required,
- limited-use App Check tokens on the paid callable start path,
- and broker-side idempotency required before any OpenAI call.
