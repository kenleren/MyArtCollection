# Marketing System Spec

Issue: #10  
Parent epic: #9  
Project item: `PVTI_lAHOB7LvFM4BcaDXzgxs9Fk`

## Problem

MyArtCollection needs a repeatable marketing workflow for SEO and collector-community learning, but the repo's trust model is stricter than normal growth tooling:

- the product is privacy-first,
- the app must avoid authenticity, appraisal, and valuation claims,
- public communities often reject promotional or automated behavior,
- human approval is required before any public posting, outreach, or partner contact.

The wrong implementation would optimize for volume and silently create search-spam, forum spam, misleading claims, or brand-damaging outreach.

## Decision

Build only a research-only marketing system for phase 1.

Allowed in the first approved workflow:

- keyword and SERP review tied to `docs/GTM_PLAN.md`
- SERP and community rule review
- educational content brief drafting for internal review
- experiment tracking and learning capture

Not approved in this phase:

- public reply, outreach, or partner-message drafting
- draft-review checklist work for public-channel messages
- autonomous posting
- autonomous commenting or direct messaging
- scraping at scale
- bulk account actions
- public-channel automation
- paid ads automation

Recommendation: split the marketing system into two bounded tracks:

1. Internal research and briefing automation: approved after normal spec review.
2. Public-channel drafting, outreach, or posting: deferred until explicit human approval and redteam review.

Public reply drafting, outreach drafting, direct posting, and outreach automation should not be built yet.

## Context And Evidence

Repo intent:

- `README.md`, `docs/NORTH_STAR.md`, and `docs/PRODUCT_PLAN.md` position the product as a private art inventory, not an appraiser, marketplace, or social catalog.
- `docs/COPY_TRUST_SPEC.md` prohibits authenticity, attribution-certainty, appraisal, certification, and market-value claims.
- `docs/GTM_PLAN.md` identifies launch wedges around private records, insurance-ready documentation, and educational SEO for:
  - art inventory template
  - how to insure an art collection
  - document artwork for insurance
  - organize art receipts and provenance
  - private art collection software

External rule checks:

- Google Search says content should be created to benefit people, not manipulate rankings, and warns against scaled or search-engine-first content.
- Reddit bans repeated or unsolicited mass engagement, including automated or manual spam, and communities also enforce their own rules.
- Facebook group participation is group-admin controlled and group-rule dependent. This is an inference from current Facebook Help snippets because full help pages were login-blocked during research.

## Non-Goals

- No autonomous posting to Reddit, Facebook, forums, newsletters, or partner inboxes.
- No fake personas, astroturfing, spam, or undisclosed agent-generated outreach.
- No claims about authenticity, appraisal, market value, artist attribution certainty, or insurance approval.
- No lead database or personal-data collection beyond approved public summaries and business contact notes explicitly entered by a human.
- No implementation of crawler, scraper, or browser automation against third-party communities in this issue.
- No paid acquisition system in the prototype phase.

## Requirements

### 1. SEO Research Workflow

The system must support:

- keyword list management tied to `docs/GTM_PLAN.md`
- intent classification: informational, comparison, partner, or community-learning
- page hypothesis per keyword:
  - target reader
  - problem to solve
  - trust constraints
  - evidence needed
  - CTA type
- SERP review notes:
  - dominant content type
  - weak or misleading competitors
  - opportunities to add first-hand value
- content brief output for human review

The system must reject:

- bulk low-value page generation
- pages created mainly to capture long-tail variants with minimal content differences
- keyword stuffing or doorway-style page sets
- claims that exceed product reality

### 2. Educational Content Brief Workflow

For each target page, the system must generate a concise brief with:

- working title
- target keyword and related questions
- user intent
- angle tied to product truth
- factual claims requiring citation or human verification
- disallowed claims from `docs/COPY_TRUST_SPEC.md`
- recommended outline
- proof points, screenshots, or examples needed
- CTA that stays within current product phase

Required initial brief candidates:

- art inventory template
- how to insure an art collection
- document artwork for insurance
- organize art receipts and provenance
- private art collection software

### 3. Community Research Workflow

The system may research communities and partners only into an internal tracker.

Allowed channels for research:

- Reddit communities
- collector forums
- Facebook groups
- newsletters
- podcasts
- artists
- galleries
- framers
- appraisers
- insurance-adjacent partners

For each target, capture:

- channel type
- name and URL
- audience fit
- access model: public, restricted, private, approval-based
- explicit rule summary
- self-promotion posture: disallowed, limited, allowed with conditions, unclear
- human owner recommendation: watch, participate, pitch, or avoid
- notes on tone, recurring questions, and risks

If rules are unclear, the default status is `avoid until manually reviewed`.

### 4. Deferred Public-Channel Drafting

Phase 1 must not draft public-channel messages.

Deferred examples:

- forum replies
- intro posts
- outreach emails
- partner pitch notes
- newsletter pitch drafts
- podcast pitch drafts
- public-channel draft-review checklists

These workflows require explicit human approval and `$codex-redteam-review` before any implementation issue is opened.

### 5. Experiment Tracking

Use a lightweight record with these fields:

- `channel`
- `target`
- `hypothesis`
- `message_or_brief`
- `workflow_type`
- `owner`
- `approval_status`
- `approval_by`
- `approval_date`
- `result`
- `learning`
- `next_action`
- `risk_notes`

## Guardrails

### Public Claims

- Never state or imply authenticity, attribution certainty, appraisal certainty, or market value.
- Never imply the product is insurance-approved, certified, or official.
- Use the existing trust language: AI suggests; the user confirms.
- Any market, insurance, or competitor claim requires a cited source and human verification before publication.

### Community Behavior

- No autonomous posting, commenting, messaging, or account actions.
- No mass engagement.
- No reposting the same promotional message across communities.
- No participation without reading both platform rules and target-community rules.
- No posting into restricted or approval-based communities without explicit human sign-off.
- No asking communities for votes, boosts, or engagement manipulation.

### Identity And Disclosure

- No fake personas.
- No undisclosed agent-generated outreach.
- Human sender identity must be explicit for any external message.
- For any future approved public-channel drafting, the human approver owns final review and sending.

### Privacy And Data Handling

- Store only approved public research summaries and business-context notes needed for follow-up.
- Do not store personal data copied from profiles unless a human explicitly decides it is necessary for legitimate outreach.
- Do not copy private-group content into the repo unless permission is clear and the human owner approves it.

## Approval Gates

### Gate A: Internal Research

No special approval beyond normal repo review if the workflow stays internal and does not log into, post to, scrape, or contact third-party targets.

### Gate B: Public-Channel Drafting

Blocked in phase 1. Required before creating public reply, outreach, partner-message, newsletter, or podcast pitch drafts:

- approved trust checklist
- approved disclosure template
- issue-level human approval that public-channel drafting is in scope
- `$codex-redteam-review`

### Gate C: Any Public Posting Or Outreach

Required every time:

- human approves the exact destination
- human confirms the community or channel rules
- human reviews the exact message
- human sends or posts manually

### Gate D: Any Automation Touching External Accounts Or Public Channels

Blocked until all are true:

- this spec is accepted
- independent spec review is complete
- `$codex-redteam-review` is complete
- a human approves platform access and account ownership
- a deployment/operations owner approves rollback and monitoring

## Success Metrics

### SEO

Pre-publication workflow metrics:

- 5 approved keyword briefs tied to `docs/GTM_PLAN.md`
- 1 intent and SERP summary per priority keyword
- 100% of briefs include trust constraints and evidence notes

Post-publication metrics for later implementation:

- impressions and clicks by target keyword cluster
- landing-page conversion to waitlist or trial action
- percentage of organic pages with a clear user-intent match
- zero pages flagged internally as claim-risk or thin-content risk

### Community / Partner Learning

Research-only metrics:

- 10 researched targets with rule summaries
- 100% of targets assigned `watch`, `participate`, `pitch`, or `avoid`
- 0 targets advanced without recorded rules review

Post-approval metrics for later implementation:

- response acceptance rate
- reply removal or warning count
- qualified conversation count
- partner reply rate
- zero policy warnings caused by automation

## Options Considered

### Option A: Full agent-driven posting workflow

Rejected.

Why:

- conflicts with repo trust posture
- high spam and platform-risk surface
- hard to verify disclosure quality
- creates unnecessary account and moderation risk early

### Option B: SEO-only system, no community workflows

Partial fit, but not enough.

Why not recommended alone:

- misses collector-language discovery from real communities
- weakens partner learning and message testing
- ignores GTM channel mix already named in `docs/GTM_PLAN.md`

### Option C: Research-only first phase

Recommended.

Why:

- supports SEO and community learning
- preserves product trust posture
- avoids public-channel drafting before explicit human approval
- defers the highest-risk public-channel workflows until there is a reviewed policy and redteam coverage

## Recommended Approach

Approve a phase-1 marketing system with four research-only capabilities:

1. Keyword and SERP research workspace.
2. Community and partner rule-tracking workspace.
3. Educational content brief workspace for internal review only.
4. Experiment tracking and learning-capture workspace.

Defer these capabilities to later issues:

- public reply drafting
- outreach and partner-message drafting
- public-channel draft-review checklists
- direct CMS publishing
- social/forum posting
- Reddit/Facebook/forum account automation
- outbound email sequencing
- scraping or cross-community monitoring bots

This recommendation would be wrong if:

- the human team decides public-channel drafting assistance is approved for phase 1,
- the product positioning changes away from privacy-first documentation,
- legal or trust review decides even internal research summaries are too risky for community participation.

## Risks And Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Search content becomes thin or repetitive | Ranking and brand damage | Require people-first brief criteria, evidence notes, and human editorial review |
| Public-channel drafting is accidentally treated as approved | Trust and legal risk | Keep reply, outreach, and partner-message drafting in deferred gated work |
| Community moderation backlash | Account or reputation damage | Default to observe-only until rules are recorded and human approves |
| Future draft reuse turns into spam | Brand and platform risk | Require explicit human approval and redteam before any public-channel drafting workflow |
| Private or personal data gets copied into repo notes | Privacy risk | Limit storage to approved public summaries and minimal business-context notes |
| External-account automation ships without controls | Severe policy risk | Redteam and deployment gates before any external-channel automation |

## Acceptance Checks

- A concise spec exists for SEO, content briefs, community research, tracking, and approval gates.
- Every public workflow explicitly requires human approval before posting, outreach, or claims.
- SEO objectives map to the keyword set already named in `docs/GTM_PLAN.md`.
- Community workflows default to rule review and human judgment, not automation.
- Redteam review is mandatory before any workflow touches public channels or external accounts.
- Follow-up tasks are limited to approved research-only workflows, with public-channel work listed only as deferred gated work.

## Follow-Up Task Breakdown

### Approved next tasks

1. Create a marketing research tracker schema and template.
   - Skill: `$codex-task-work`
   - Scope: docs-only

2. Create a keyword brief template tied to the GTM keyword set and trust checklist.
   - Skill: `$codex-task-work`
   - Scope: docs-only

3. Create a community and partner review rubric with rule-capture fields and approval states.
   - Skill: `$codex-task-work`
   - Scope: docs-only

4. Build internal tooling for research-only workflow templates if manual Markdown templates are insufficient.
   - Skills: `$codex-task-plan`, `$codex-task-work`, `$codex-task-review`
   - Scope: no third-party login, no public posting, no outreach drafting

### Deferred gated tasks

5. Public reply, outreach, and partner-message drafting workflow.
   - Required first: explicit human approval and `$codex-redteam-review`
   - Scope: not approved for phase 1

6. Draft-review checklist for public replies, outreach, partner messages, newsletters, and podcast pitches.
   - Required first: explicit human approval and `$codex-redteam-review`
   - Scope: not approved for phase 1

7. Redteam review for any tooling that logs into, posts to, drafts for, or sends through external channels.
   - Skill: `$codex-redteam-review`

8. Deployment and operational review for any external-account automation.
   - Skill: `$codex-deployment-manager`

No `$codex-visual-review` surface is required for this issue unless the follow-up work adds UI.

## Human Decisions Needed

1. What human role owns final approval for moving any deferred public-channel drafting or outreach work into scope?
2. What human role owns final approval and manual sending for any future public posts or partner outreach?
3. What tracker format should be the source of truth: Markdown table, spreadsheet, or future app/admin surface?
4. Are business contact notes for partners allowed in-repo, or should they stay outside the repository?
5. Which keyword cluster is first priority for educational content: insurance, inventory templates, provenance organization, or software comparison?

## Redteam And Deployment Gates

- Redteam is required before any automation touches public channels, external accounts, or outbound messaging.
- Deployment review is not needed for this docs spec itself.
- Deployment review becomes required once tooling can authenticate to third-party services, publish content, or send outbound messages.

## Source Summary

- Local: `README.md`, `docs/NORTH_STAR.md`, `docs/GTM_PLAN.md`, `docs/PRODUCT_PLAN.md`, `docs/COPY_TRUST_SPEC.md`, issues #9 and #10.
- External:
  - Google Search Central: spam policies and people-first content guidance
  - Reddit Help: Spam, Reddiquette, and community-rule guidance
  - Facebook Help snippets: group rules and participation are admin-controlled; treated here as supporting inference rather than a decisive policy source because full pages were login-blocked
