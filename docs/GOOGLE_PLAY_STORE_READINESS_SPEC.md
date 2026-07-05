# Google Play Store Readiness Spec

Issue: #76  
Project: https://github.com/users/kenleren/projects/1  
Depends on context from: #53, #9  
Status: research/spec only

## Problem statement

`#53` prepared listing copy and asset direction. `#76` must turn the remaining
Google Play launch blockers into agent-executable work without actually
publishing the app, submitting a Play release, enabling paid services, or
touching secrets.

The work is broader than store-copy polish. MyArtCollection needs a bounded
submission path for:

- store listing fields and asset dependencies,
- a privacy-policy URL and minimal public website,
- a Data safety worksheet tied to the exact Android build on each Play track,
- SDK and testing-track decisions,
- review gates for screenshots, icon, feature graphic, and copy,
- explicit human approvals before any public upload or publication.

## Context and evidence

Repo evidence:

- Root `AGENTS.md` has been prepared on the accepted agent-guardrails branch
  and should be included in release-candidate integration before Play-facing
  work continues.
- [docs/GOOGLE_PLAY_LISTING_PREP.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/GOOGLE_PLAY_LISTING_PREP.md)
  already defines the shipped-safe listing baseline from `#53`.
- [docs/COPY_TRUST_SPEC.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/COPY_TRUST_SPEC.md),
  [README.md](/Users/kenleren/Private/Ken/MyArtCollection/README.md), and
  [docs/GTM_PLAN.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/GTM_PLAN.md)
  position the app as a private collector-record tool, not an appraiser,
  authenticity engine, marketplace, or social product.
- [docs/ARCHITECTURE.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/ARCHITECTURE.md),
  [docs/LOCAL_STORAGE_SPEC.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/LOCAL_STORAGE_SPEC.md),
  [docs/FIREBASE_TELEMETRY_POLICY.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/FIREBASE_TELEMETRY_POLICY.md),
  and
  [docs/FIREBASE_APP_DISTRIBUTION.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/FIREBASE_APP_DISTRIBUTION.md)
  constrain privacy, telemetry, and beta-distribution claims.
- The Android app currently includes gated `firebase_core`,
  `firebase_crashlytics`, and `firebase_remote_config`
  ([pubspec.yaml](/Users/kenleren/Private/Ken/MyArtCollection/pubspec.yaml),
  [android/app/build.gradle.kts](/Users/kenleren/Private/Ken/MyArtCollection/android/app/build.gradle.kts),
  [lib/app/telemetry/crash_telemetry.dart](/Users/kenleren/Private/Ken/MyArtCollection/lib/app/telemetry/crash_telemetry.dart),
  [lib/app/config/app_feature_flags.dart](/Users/kenleren/Private/Ken/MyArtCollection/lib/app/config/app_feature_flags.dart)).
- Current Android manifest state shows launcher-only app metadata and no
  explicit release permission additions in the main manifest
  ([android/app/src/main/AndroidManifest.xml](/Users/kenleren/Private/Ken/MyArtCollection/android/app/src/main/AndroidManifest.xml)).

Current primary-source external evidence checked on July 5, 2026:

- Play listing fields remain app name `30` chars, short description `80`, full
  description `4000`; store listing is shared across tracks; repetitive or
  misleading keywords can trigger policy action. Source:
  [Create and set up your app](https://support.google.com/googleplay/android-developer/answer/9859152?hl=en).
- App icon is required at `512x512` PNG up to `1024 KB`; screenshots support up
  to `8` per device type. Source:
  [Add preview assets to showcase your app](https://support.google.com/googleplay/android-developer/answer/9866151?hl=en).
- Before submission, Google requires accurate metadata plus a privacy policy and
  Data safety completion. Source:
  [Developer Program Policy](https://support.google.com/googleplay/android-developer/answer/17105854?hl=en).
- Data safety is required for apps published on closed, open, or production
  tracks; apps active only on internal testing are exempt. Source:
  [Provide information for Google Play's Data safety section](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en).
- For new personal developer accounts, production access still requires a
  closed test with at least `12` opted-in testers for `14` continuous days.
  Source:
  [App testing requirements for new personal developer accounts](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en).
- Custom store listings still require a default listing and a published app.
  Source:
  [Create custom store listings](https://support.google.com/googleplay/android-developer/answer/9867158?hl=en).
- Managed publishing can hold store listing, app content, and release changes
  until a human publishes them. Source:
  [Control when app changes are reviewed and published](https://support.google.com/googleplay/android-developer/answer/9859654?hl=en).
- Firebase Hosting still supports multiple sites in one project, custom domains,
  and automatic SSL. Sources:
  [Firebase Hosting](https://firebase.google.com/docs/hosting),
  [Connect a custom domain](https://firebase.google.com/docs/hosting/custom-domain).
- Firebase’s current Play data-disclosure guidance says developers must account
  for data collected by included SDKs such as Crashlytics, Installations, and
  Remote Config when those SDKs are active in public Play tracks. Source:
  [Prepare for Google Play's data disclosure requirements](https://firebase.google.com/docs/android/play-data-disclosure).

## Non-goals

- No Play Console submission, rollout, or asset upload.
- No Firebase Hosting deploy, domain purchase, or DNS change.
- No enabling paid services, billing, or subscriptions.
- No code implementation beyond spec documentation.
- No creation or exposure of secrets, tester lists, or service-account files.
- No custom store listing execution, A/B experiments, or ads setup.

## Requirements

### 1. Submission path must be track-aware

The spec must distinguish:

- `internal testing only`: quickest route, Data safety exempt if the app is
  exclusively active on internal testing;
- `closed testing`: Data safety required, privacy-policy URL required, store
  listing visible, and likely needed for new personal-account production access;
- `production`: requires all closed-test access criteria plus final human
  approvals.

### 2. Privacy policy must be true to shipped behavior

The privacy policy must state only what the shipped build actually does:

- local-first storage by default,
- optional Firebase-only internal beta diagnostics if enabled in that track,
- optional future Google Drive backup only when shipped,
- optional future AI/off-device processing only when shipped,
- no authenticity or appraisal claims.

### 3. Website scope must stay minimal

The first public web presence should exist to satisfy Play and trust needs, not
to build a full marketing system from `#9`.

Minimum public pages:

- `/privacy`
- `/support`
- `/`
- `/blog/` or `/updates/` index only if there is actual content to publish

Recommended near-term additions:

- `/app-version` or `/release-notes` for beta/public change summaries
- `/contact` only if different from `/support`

Not required for first Play readiness:

- CMS
- comments
- user accounts
- analytics
- newsletter signup
- public automation

### 4. Data safety work must start from the actual build matrix

The team must not fill the Data safety form from aspiration or from platform
vision docs. It must be based on the exact artifacts intended for each track.

### 5. Visual assets must come from a release candidate

Store screenshots and graphics must be reviewed against the exact build that is
intended for the relevant public Play track.

### 6. ASO/AEO must stay within trust limits

Copy may improve discoverability for art inventory, records, documents,
insurance-prep, and organization use cases, but cannot imply:

- authenticity verification,
- appraisal certainty,
- insurance approval,
- stronger privacy/security guarantees than implemented,
- shipped AI, backup, export, or reporting features that are absent.

### 7. Human approval must be explicit before publication

Agent work may prepare docs, drafts, and assets, but humans must approve:

- final privacy policy text,
- Data safety declarations,
- default store listing copy,
- screenshots/icon/feature graphic,
- Play track choice and tester strategy,
- any actual Play or Firebase publication action.

## Options considered

| Decision | Option | Pros | Risks | Recommendation |
| --- | --- | --- | --- | --- |
| Public web presence | Full marketing site now | More launch surface | Pulls #9 forward; more copy/policy drift | No |
| Public web presence | Minimal Firebase-hosted static site for policy/support | Fastest compliant path; low maintenance | Less marketing impact | Yes |
| First public Play path | Closed test with Firebase-enabled build | Better crash triage and remote flags | More complex Data safety and policy review | Only if needed |
| First public Play path | Closed test with non-Firebase build | Simplest privacy/Data safety story | Less operational telemetry | Yes |
| Blog approach | Dynamic CMS | Easier non-technical edits later | More moving parts, auth, security, and content debt | No for now |
| Blog approach | Static markdown-backed updates page | Low cost; repo-reviewed; Firebase-friendly | Manual publishing | Yes |

Recommendation could be wrong if:

- release operations prove that Remote Config or Crashlytics are mandatory even
  for the first closed test, or
- the product decides to use the public website as a core GTM asset before Play
  submission rather than only as a policy/support surface.

## Recommended approach

### A. Separate readiness into two lanes

1. `Play-compliance lane`
   - privacy policy
   - Data safety worksheet
   - SDK/track inventory
   - release gates
2. `Public-presence lane`
   - minimal Firebase-hosted site
   - support page
   - optional updates/blog page
   - app/contact details used by Play listing

This keeps `#76` bounded and avoids dragging the broader marketing epic into
the submission-critical path.

### B. Prefer a non-Firebase build for the first closed/public Play track

Recommended first public-track stance:

- keep Crashlytics and Remote Config for internal beta only,
- prepare the first closed-test/public-track artifact without Firebase runtime
  collection unless the team can justify why it is necessary.

Why:

- internal-only tracks are exempt from the Data safety requirement;
- closed/open/production tracks require declarations matching the sum of all
  active public-track versions;
- the current repo positioning is privacy-first and local-first, so reducing
  SDK-driven off-device data collection simplifies the first public disclosure
  package and lowers review risk.

If Firebase-enabled builds are used on closed/open/production tracks, the team
must disclose the resulting Diagnostics / App info / Device-or-other-ID classes
as applicable after console verification.

### C. Use one minimal static Firebase Hosting site

Recommended structure:

- one repo-managed static site,
- hosted on Firebase Hosting,
- no app login,
- no analytics,
- no forms that require backend storage,
- markdown or plain HTML content rendered statically.

Recommended IA:

- `/`:
  one-screen plain product explanation and links to privacy/support
- `/privacy`:
  privacy policy for MyArtCollection Android app
- `/support`:
  support email, supported platform, beta/public issue reporting guidance
- `/updates`:
  optional release notes and short updates

Recommended domain approach:

- preferred: branded custom domain connected to Firebase Hosting before public
  Play submission;
- fallback for non-public prep: temporary `web.app` / `firebaseapp.com` URL;
- do not rely on a temporary Firebase domain as the long-term Play-facing trust
  URL if a branded domain is available.

### D. Treat Data safety as a worksheet plus final console verification

Prepare the worksheet in repo first, then require a human to confirm every
answer in Play Console against the exact artifact(s).

#### Recommended worksheet inputs

Track assumptions should be recorded explicitly:

| Scenario | Firebase Crashlytics | Firebase Remote Config | Likely worksheet outcome |
| --- | --- | --- | --- |
| Internal-only beta artifact | On if gated | On if gated | No Play Data safety filing needed while app is exclusively internal-test active |
| First closed/public artifact without Firebase runtime collection | Off | Off | Candidate for "no user data collected/shared off device", subject to final permission/API audit |
| Closed/public artifact with Crashlytics only | On | Off | Expect declarations for diagnostics, app info/performance, and installation/Crashlytics identifiers |
| Closed/public artifact with Crashlytics + Remote Config | On | On | Expect above plus Remote Config coarse environment/app metadata and Firebase Installations ID handling |

#### Repo-grounded worksheet notes

Current repo evidence supports these draft inputs:

- no Firebase Analytics SDK present;
- no Firebase Performance Monitoring SDK present;
- no ads SDK present;
- no billing SDK present;
- no app account/auth SDK present;
- Crashlytics is currently designed for Android release builds only when both
  Gradle and Dart defines enable it;
- Remote Config is currently designed for Android release builds only when both
  Gradle and Dart defines enable it.

#### Firebase SDK disclosure prompts to verify before final answers

If a public-track build includes Crashlytics:

- diagnostics collected automatically on crash,
- relevant app/device metadata,
- Crashlytics installation UUID,
- Firebase Installations ID transitively involved.

If a public-track build includes Remote Config:

- country code,
- language code,
- time zone,
- platform / OS version,
- app package and Firebase app identifiers,
- Firebase Installations ID transitively involved.

Human console verification must decide the exact Play taxonomy mapping and
whether Google considers each item collected, shared, required, and
security-practice disclosed for the submitted artifact set.

### E. Keep store listing scope aligned with #53

Carry forward from `#53`:

- default listing first,
- phone-first screenshots,
- no public asset upload before release-candidate review,
- no custom store listings until after a published default listing exists,
- no experiment rollout until baseline traffic exists.

Use the existing listing-prep doc for copy direction, but add these `#76`
constraints:

- the support URL and privacy-policy URL must exist before any closed/open/
  production submission;
- the app contact email shown on Play must be monitored by a human;
- the listing copy must be reconciled against the exact release candidate so it
  does not mention AI, backup, export, or PDF reports unless they actually ship.

## Store listing package for execution

### Required listing fields and dependencies

| Field / asset | Required for #76 | Dependency | Notes |
| --- | --- | --- | --- |
| App name | Yes | Human copy approval | Keep within 30 chars |
| Short description | Yes | Human copy approval | Keep within 80 chars |
| Full description | Yes | Human copy approval | Keep within 4000 chars |
| App category + tags | Yes | Console availability check | Use actual Play tag names |
| Support email | Yes | Human-monitored inbox | Must be operational |
| Privacy policy URL | Yes for closed/open/production | Website lane complete | Active public URL |
| Website URL | Recommended | Website lane complete | Helps trust and support |
| App icon | Yes | Design asset review | 512x512 PNG |
| Feature graphic | Strongly recommended for launch-ready listing | Design asset review | 1024x500, no alpha |
| Phone screenshots | Yes | Release-candidate capture | Up to 8; launch with 6 recommended |
| Large-screen screenshots | Deferred | Verified large-screen UX | Only after real QA |
| Promo video | Optional | Visual polish + YouTube | Not a blocker |

### Screenshot dependencies

Required before capture:

- release-candidate build installed on representative Android phone(s),
- approved fixture data instead of private real-user collection data,
- final UI copy checked against trust rules,
- any unshipped surface hidden from screenshot flow.

### AEO / ASO constraints

Allowed search themes:

- art records
- art inventory
- private collection records
- artwork documents
- insurance documentation
- catalog from photos

Disallowed search themes:

- art appraisal
- artwork valuation
- authenticity verification
- official provenance certification
- instant artist identification certainty

Copy rules:

- title and first sentence must say what the app is;
- do not repeat keyword clusters unnaturally;
- do not vary trust/privacy/AI claims between assets and text;
- do not let the blog or website promise features absent from the store listing
  build.

## Risks and mitigations

| Risk | Why it matters | Mitigation |
| --- | --- | --- |
| Privacy policy says more than the build does | Play enforcement and trust damage | Write from actual shipped behavior and build flags |
| Data safety filled from intent, not artifact | High mismatch risk | Use track-by-track worksheet and human console verification |
| Firebase-enabled closed test expands disclosure scope | More review burden | Prefer non-Firebase public-track build first |
| Store assets show unshipped features | Misleading metadata risk | Release-candidate-only screenshot review |
| #9 marketing scope creeps into #76 | Delays compliance path | Limit website to policy/support/updates |
| Unmonitored Play contact inbox | Review or user issues get missed | Assign human owner before submission |
| Custom domain setup delays website lane | Blocks privacy-policy URL if no fallback | Use temporary Hosting URL for non-public prep; move to custom domain before public submission if possible |

## Acceptance checks

`#76` is ready for implementation work when all of the following are specified:

1. Website scope is frozen to static policy/support/updates pages.
2. Privacy-policy outline exists and is reconciled against current product docs.
3. Track plan is explicit:
   - internal only,
   - closed test,
   - production later.
4. Data safety worksheet exists with one row per planned track/build posture.
5. SDK inventory exists for the Android artifact intended for the first public
   Play track.
6. Listing field inventory exists with owners and approval gates.
7. Screenshot, icon, and feature-graphic dependencies are listed.
8. Human approvals required before any publish action are named.
9. Work is split into implementation-sized tasks.

## Recommended task breakdown

### Task 1: Write privacy-policy source spec

Goal:

- create the policy outline and truth-source checklist for the Android app and
  any linked website pages.

Needs:

- normal implementation
- human legal/product review before publication

Suggested review tags:

- `$codex-task-work`
- deployment review only if actual Hosting publish is later scheduled

### Task 2: Create minimal Firebase Hosting website plan

Goal:

- specify site structure, content files, route map, and domain strategy for the
  privacy/support/updates site.

Needs:

- `$codex-task-plan` because this is a new public surface
- `$codex-visual-review` after implementation
- deployment review before any real deploy

### Task 3: Produce Play Data safety worksheet

Goal:

- inventory SDKs, permissions, and off-device behaviors by track/build.

Needs:

- `$codex-task-work`
- `$codex-redteam-review` because privacy/disclosure mismatches are a policy
  risk

### Task 4: Produce SDK and track decision memo

Goal:

- choose whether the first closed/public track uses a non-Firebase build or a
  Firebase-enabled build and record the consequences.

Needs:

- `$codex-task-work`
- deployment review before any real track use

### Task 5: Prepare Play listing execution checklist

Goal:

- convert `#53` copy + `#76` gates into an upload-ready checklist for fields,
  assets, contact details, and managed-publishing settings.

Needs:

- `$codex-task-work`
- human marketing/product approval

### Task 6: Capture release-candidate screenshot and graphic brief

Goal:

- define fixture content, target screens, capture device(s), and design review
  rules for the final assets.

Needs:

- `$codex-task-plan`
- design review
- `$codex-visual-review`

### Task 7: Prepare closed-test readiness pack

Goal:

- checklist for tester recruitment, opt-in continuity, feedback channel, and
  production-access application evidence if the account is subject to the
  personal-account requirement.

Needs:

- `$codex-task-work`
- deployment/release review

## Tasks that need design / visual / deployment review

| Task | Design review | Visual review | Deployment review |
| --- | --- | --- | --- |
| Privacy-policy source spec | No | No | Only if publishing later |
| Minimal Firebase Hosting website plan | Light content/design review | Yes | Yes before deploy |
| Play Data safety worksheet | No | No | Yes before console submission |
| SDK and track decision memo | No | No | Yes |
| Play listing execution checklist | Yes for copy/assets | No | Yes before console action |
| Release-candidate screenshot and graphic brief | Yes | Yes | No |
| Closed-test readiness pack | No | No | Yes |

## Explicit human approval gates

Humans must approve before any publication or upload:

1. final privacy-policy text,
2. website domain/URL choice,
3. Data safety answers in Play Console,
4. first public-track build posture:
   - Firebase off, or
   - Firebase on with expanded disclosures,
5. store listing copy,
6. final screenshots, app icon, and feature graphic,
7. tester list / feedback channel / closed-test start,
8. enabling Managed Publishing release or any actual Play publish action.

## Open decisions for humans

1. Is the Play developer account a new personal account that still needs the
   `12 testers / 14 days` closed-test gate for production access?
2. Is a branded domain already owned for the website, or should the website
   first launch on a temporary Firebase domain?
3. Is Crashlytics or Remote Config actually needed on the first closed/public
   Play track, or can that track ship without Firebase runtime collection?
4. Does the first public Play build include any AI, Drive backup, export, or
   PDF/report functionality that must appear in policy and listing copy?
5. Who owns the public support inbox and final publish decision?

## Recommended next step

Open implementation tasks in this order:

1. privacy-policy source spec,
2. Data safety worksheet,
3. SDK/track decision memo,
4. minimal Firebase Hosting site plan,
5. listing execution checklist,
6. release-candidate screenshot/graphic brief,
7. closed-test readiness pack.
