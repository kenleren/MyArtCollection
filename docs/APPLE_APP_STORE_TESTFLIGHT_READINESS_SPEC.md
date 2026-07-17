# Apple App Store and TestFlight Readiness Spec

Issue: #83
Project: https://github.com/users/kenleren/projects/1
Depends on context from: #76, #78, #82
Status: research/spec only

## Problem statement

Archivale has an Android-facing readiness spec in `#76`, but the iOS
distribution path is still implicit. Apple distribution adds a separate setup
surface for App Store Connect, TestFlight, App Privacy nutrition labels,
screenshots, export-compliance answers, signing/provisioning ownership, and
device-family support decisions.

`#83` must turn those moving parts into a bounded, human-gated readiness plan
for an iPhone-first MVP without uploading builds, touching signing assets, or
handling Apple credentials.

## Context and evidence

Repo and issue evidence:

- No root `AGENTS.md` is present in this worktree. The nearest accepted repo
  guidance is
  [../MyArtCollection-issue71-agents/AGENTS.md](/Users/kenleren/Private/Ken/MyArtCollection-issue71-agents/AGENTS.md),
  which matches the guardrails referenced by the Android readiness spec.
- `#76` already established the release-spec structure and trust boundaries for
  store readiness work:
  [docs/GOOGLE_PLAY_STORE_READINESS_SPEC.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/GOOGLE_PLAY_STORE_READINESS_SPEC.md).
- `#78` accepted the canonical human-facing brand string `Archivale`
  for install and in-app surfaces. Review evidence also recorded that iOS
  runtime proof depended on the deployment-target fix in `#82`.
- `#82` has a pushed compatibility fix at commit `1f8185a` on branch
  `codex/issue-82-ios-target`: it raises the effective iOS deployment target to
  `15.0` and has worker-reported unsigned simulator-build evidence. The
  branch still needs independent review before it should be treated as a
  completed Apple readiness prerequisite.
- iOS project metadata today:
  - display name is `Archivale`
    ([ios/Runner/Info.plist](/Users/kenleren/Private/Ken/MyArtCollection/ios/Runner/Info.plist:10));
  - bundle id is `com.kenleren.myArtCollection`
    ([ios/Runner.xcodeproj/project.pbxproj](/Users/kenleren/Private/Ken/MyArtCollection/ios/Runner.xcodeproj/project.pbxproj:386));
  - deployment target is `15.0` on the `#82` branch
    ([ios/Runner.xcodeproj/project.pbxproj](/Users/kenleren/Private/Ken/MyArtCollection/ios/Runner.xcodeproj/project.pbxproj:363));
  - targeted device family is `1,2`, so the current target declares iPhone and
    iPad support
    ([ios/Runner.xcodeproj/project.pbxproj](/Users/kenleren/Private/Ken/MyArtCollection/ios/Runner.xcodeproj/project.pbxproj:367));
  - iPad interface orientations are explicitly present
    ([ios/Runner/Info.plist](/Users/kenleren/Private/Ken/MyArtCollection/ios/Runner/Info.plist:62)).
- The repo currently contains no app-owned iOS `GoogleService-Info.plist`,
  `.entitlements`, `ExportOptions.plist`, or app-owned `PrivacyInfo.xcprivacy`
  under `ios/`.
- Firebase posture in repo docs is Android-first today:
  [docs/FIREBASE_TELEMETRY_POLICY.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/FIREBASE_TELEMETRY_POLICY.md)
  and
  [docs/FIREBASE_APP_DISTRIBUTION.md](/Users/kenleren/Private/Ken/MyArtCollection/docs/FIREBASE_APP_DISTRIBUTION.md)
  explicitly allow Android beta delivery and Android-only Crashlytics enablement
  while requiring any future iOS Firebase config to pass the same privacy gate.
- Localization surface is already wider than one language: the app ships ARB
  files for `en`, `da`, `de`, `es`, `fi`, `fr`, `is`, `it`, `nb`, `nl`, `pl`,
  `pt`, and `sv`
  ([lib/l10n](/Users/kenleren/Private/Ken/MyArtCollection/lib/l10n)).
- Brand drift still exists in localizations and Flutter metadata: `MaterialApp`
  title and ARB `appTitle` remain `Archivale`
  ([lib/app/app.dart](/Users/kenleren/Private/Ken/MyArtCollection/lib/app/app.dart:29),
  [lib/l10n/app_en.arb](/Users/kenleren/Private/Ken/MyArtCollection/lib/l10n/app_en.arb:3)).

Current primary-source external evidence checked on July 5, 2026:

- Creating a new App Store Connect app record requires an App Store Connect role
  of Account Holder, Admin, or App Manager and needs a platform, name, primary
  language, bundle ID, and SKU. Bundle ID must match the Xcode project. Source:
  [Add a new app](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/),
  [App information reference](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/).
- App privacy responses are app-level, must include third-party partner code,
  and should be answered in the most comprehensive way across supported
  platforms. A privacy policy URL is required for iOS apps. Source:
  [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/),
  [App privacy details](https://developer.apple.com/app-store/app-privacy-details/).
- App Store screenshots remain one to ten per supported device size and
  localization. If UI is the same across sizes/localizations, Apple allows the
  highest-resolution set to scale down. App previews are optional, up to three
  per supported device size and language. Sources:
  [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/),
  [Upload app previews and screenshots](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots/),
  [Creating your product page](https://developer.apple.com/app-store/product-page/).
- TestFlight supports up to 100 internal testers and up to 10,000 external
  testers. External testing requires beta test information and may require beta
  App Review on the first build added to a group. Sources:
  [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/),
  [Provide test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/),
  [Invite external testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/).
- Export compliance is still an explicit App Store Connect and TestFlight gate;
  Apple provides a questionnaire for builds and app records. Sources:
  [Overview of export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/),
  [Provide export compliance information for beta builds](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-export-compliance-information-for-beta-builds/),
  [Complying with encryption export regulations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations).
- App age rating is required before App Store publication. Source:
  [Set an app age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/).
- Firebase’s current Apple-platform disclosure guidance says developers must
  disclose actual app behavior for each included Firebase SDK and optional
  features; Firebase privacy manifests do not remove the developer’s obligation
  to answer Apple’s nutrition labels accurately. Source:
  [Prepare for Apple's App Store data disclosure requirements](https://firebase.google.com/docs/ios/app-store-data-collection).

## Non-goals

- No App Store Connect record creation, TestFlight upload, or App Store
  submission.
- No paid Apple Developer enrollment work, contract acceptance, banking, or tax
  setup.
- No signing/provisioning edits, certificate/profile generation, or secret
  inspection.
- No reading, printing, validating, or moving `GoogleService-Info.plist`,
  certificates, provisioning profiles, or local credentials.
- No screenshot production, design polish, or code implementation in this spec.

## Requirements

### 1. Use an iPhone-first distribution path

The first Apple path should be scoped to `iPhone only for store-ready proof`
unless and until the product explicitly commits to iPad UX support. The current
target advertises iPad support, so leaving `TARGETED_DEVICE_FAMILY = "1,2"` in
place would force iPad screenshots and broader device QA for truthful listing
and review readiness.

### 2. Treat `#82` review acceptance as a hard blocker before runtime or upload work

No Apple beta or App Store distribution action should proceed before `#82`
review accepts the raised deployment target and deterministic iOS build proof.
Until that review lands, screenshot capture, TestFlight packaging, and App
Store validation remain premature.

### 3. Keep the first Apple beta lane narrower than the eventual App Store lane

Recommended lanes:

- `internal TestFlight only`: narrowest safe Apple lane after `#82`; allows
  real-device QA and operational setup without public product-page pressure.
- `external TestFlight`: requires beta test info and likely beta App Review for
  the first build in a group; use only after privacy labels, screenshots, and
  review notes are ready.
- `App Store submission`: requires the full listing, age rating, privacy policy,
  screenshots, export compliance answers, and human release approvals.

### 4. Privacy nutrition labels must match the exact shipped iOS artifact

Do not answer App Privacy from architecture aspirations or Android-only docs.
Answer from the exact iOS artifact:

- If the first iOS artifact ships without Firebase runtime use, prefer the
  narrowest truthful label set.
- If iOS adds Crashlytics and/or Remote Config, update labels to include the
  SDK-driven disclosures Apple requires for those behaviors.
- Third-party code counts even when collection is conditional or limited.

### 5. Privacy policy must align with iOS-specific truth

The policy URL used in App Store Connect must say only what the shipped iOS
build does:

- local-first storage by default,
- optional off-device services only when actually enabled on iOS,
- no authenticity, appraisal, or insurance-approval claims,
- no stronger encryption/privacy promises than the repo can support.

### 6. Screenshots and app preview work must stay build-specific

Apple screenshots and any optional app preview must come from the actual iOS
release candidate or TestFlight candidate, not Android mocks or design comps.
If iPad remains supported, iPad screenshots become a required workstream.

### 7. Human ownership of Apple identity and signing must be explicit

Agents may document the needed Apple identifiers and steps, but humans must own:

- Apple Developer account and role assignment,
- explicit App ID registration,
- App Store Connect app record creation,
- team selection,
- signing certificate/provisioning profile creation or approval,
- final build upload and release actions.

## Options considered

| Decision | Option | Pros | Risks | Recommendation |
| --- | --- | --- | --- | --- |
| First Apple beta lane | Internal TestFlight first | Lowest review overhead; real-device proof | Needs Apple account/setup first | Yes |
| First Apple beta lane | External TestFlight first | Faster outside feedback | Adds beta App Review and tester-facing metadata sooner | No |
| Device scope | Keep iPhone + iPad for first lane | Wider device reach | Adds iPad QA and screenshot burden immediately | No |
| Device scope | Reduce to iPhone-first | Smallest truthful MVP surface | Later iPad support becomes a separate decision | Yes |
| iOS Firebase posture | Enable Firebase on first iOS beta | More diagnostics and flags | Expands privacy labels and config/signing complexity | Only if needed |
| iOS Firebase posture | First iOS lane without Firebase runtime | Simplest privacy and setup story | Less operational telemetry | Yes |
| App preview | Produce preview video now | Richer product page | More production work; not required | No for first lane |

Recommendation could be wrong if:

- the owner explicitly wants iPad listed on day one and accepts the larger QA
  and screenshot scope, or
- stability evidence shows iOS Crashlytics/Remote Config are necessary before
  any meaningful beta.

## Recommended approach

### A. Split Apple readiness into three bounded lanes

1. `Build compatibility lane`
   - unblock `#82`
   - confirm deployment target, simulator/device build, and release-candidate
     screenshotability
2. `Apple metadata lane`
   - App Store Connect record inputs
   - privacy policy and nutrition labels
   - screenshots
   - age rating
   - export compliance answers
3. `Distribution lane`
   - internal TestFlight
   - optional external TestFlight
   - eventual App Store review/submission gates

This keeps `#83` from collapsing into a vague “ship iOS” epic.

### B. Make the first Apple distribution path internal TestFlight on iPhone only

Recommended first path:

- land and review-accept `#82`,
- decide whether to remove iPad support before asset work,
- prepare an App Store Connect record and privacy posture,
- run internal TestFlight first,
- defer external TestFlight and App Store submission until privacy labels,
  screenshots, and human review gates are accepted.

### C. Prefer a non-Firebase first iOS lane

The repo’s current policy and implementation evidence already treat Firebase as
Android-first. For iOS, the narrowest truthful first lane is:

- no iOS `GoogleService-Info.plist` committed or handled by agents,
- no iOS Crashlytics runtime enablement by default,
- no iOS Remote Config runtime fetches by default,
- no iOS Analytics or Performance Monitoring.

If humans later choose iOS Crashlytics or Remote Config, that decision should be
an explicit follow-up because it changes App Privacy answers, policy copy, and
release-review burden.

### D. Resolve iPad support before screenshot production

Current evidence says the app target still declares iPad support. That is the
wrong default for a readiness pass because it silently enlarges scope.

Recommended human decision:

- `preferred`: reduce the initial App Store target to iPhone only unless the
  product explicitly accepts iPad QA, layout review, and screenshot work now;
- `fallback`: keep iPad support only if a dedicated task proves core routes,
  empty states, and typography on iPad and produces iPad screenshots.

### E. Keep localization scope intentionally narrow for the first Apple listing

The app already has multiple UI localizations, but the listing should not inherit
all of them automatically. For first readiness:

- choose one primary App Store language first, likely `English (U.S.)` unless a
  different commercial default is explicitly chosen;
- do not add localized App Store metadata until privacy-policy URLs, screenshots,
  and copy exist for that language;
- fix brand drift before wider localization work so `Archivale` remains
  the human-facing name consistently.

## Blockers and risks

| Blocker / risk | Why it matters | Mitigation |
| --- | --- | --- |
| `#82` review gate | Apple runtime proof should not rely on an unreviewed compatibility branch | Accept `#82` review before any Apple distribution task moves beyond planning |
| iPad support is currently declared | Expands Apple screenshot and QA scope immediately | Make an explicit iPhone-only vs iPad decision first |
| No App Store Connect record yet | Prevents actual TestFlight/App Store setup | Human creates record once naming/language/bundle/SKU decisions are approved |
| No iOS Firebase config files under `ios/` | Good for privacy minimization, but means Firebase-on-iOS is not operationally ready | Keep first iOS lane non-Firebase unless a later task approves broader setup |
| Privacy label drift from SDK inclusion | Apple answers must include third-party code behavior | Base answers on actual linked SDK usage and Firebase Apple disclosure guidance |
| Brand strings can drift again during rename/localization work | Inconsistent screenshots or metadata undermine App Store readiness | Keep `Archivale` synchronized across ARB, Flutter title, install metadata, and store-copy drafts before final screenshot capture |

`#82` review acceptance is the only confirmed hard blocker today. The others
are scope and truth management risks, not reasons to stop planning.

## Acceptance checks

`#83` is ready to hand off when all of the following are specified:

1. The first Apple path is chosen: internal TestFlight first, with external
   TestFlight/App Store deferred or accepted explicitly.
2. The supported device decision is explicit: `iPhone only` or `iPhone + iPad`.
3. App Store Connect record inputs are documented:
   - app name,
   - primary language,
   - bundle ID,
   - SKU convention,
   - support URL owner,
   - privacy-policy URL owner.
4. Privacy posture is documented for the exact first iOS artifact:
   - Firebase off, or
   - Firebase on with expanded disclosures.
5. `#82` review acceptance is recorded as a required predecessor for any
   screenshot, upload, or TestFlight execution task.
6. Human gates are named before any Apple distribution action.
7. Follow-up work is split into small tasks with the correct review type.

## Visual review surface

When implementation begins, `$codex-visual-review` should cover:

- iPhone:
  - app icon on home screen,
  - installed display name,
  - splash / launch experience,
  - first branded screen,
  - core collection screen,
  - any screenshot surfaces selected for the first App Store set.
- iPad, only if retained:
  - launch,
  - collection screen,
  - settings/privacy screen,
  - layout density and truncation checks.
- Screenshot evidence:
  - exact exported App Store screenshot files,
  - mapping from each screenshot to the route/state it represents,
  - confirmation that no placeholder, secret, or private real-user data appears.

## Task breakdown

### Task 1: Review and accept iOS build floor (`#82`)

Scope:

- independently review the `1f8185a` deployment-target branch,
- confirm the effective target is `15.0`,
- confirm deterministic simulator/device build evidence or document remaining
  toolchain blockers if any.

Review:

- `$codex-task-work`
- independent `$codex-task-review`

### Task 2: Decide Apple device scope and listing language

Scope:

- choose `iPhone only` vs `iPhone + iPad`,
- choose primary App Store language,
- confirm whether first Apple listing stays English-only.

Review:

- lightweight human decision
- no code required unless device-family support changes

### Task 3: Prepare App Store Connect identity pack

Scope:

- final app name for Apple listing,
- bundle ID confirmation against Xcode,
- SKU convention,
- support URL owner,
- privacy-policy URL owner,
- App Store Connect role owner.

Review:

- `$codex-task-work` for documentation only
- human approval before any record creation

### Task 4: Write Apple privacy disclosure worksheet

Scope:

- map the first iOS artifact to Apple nutrition-label answers,
- map privacy-policy statements to the same artifact,
- record consequences of enabling iOS Crashlytics/Remote Config later.

Review:

- `$codex-task-work`
- `$codex-redteam-review` because policy/disclosure mismatch is high risk

### Task 5: Prepare Apple screenshot plan

Scope:

- define screenshot routes/states,
- define iPhone sizes to capture,
- define iPad sizes too if iPad remains supported,
- decide whether app preview stays deferred.

Review:

- `$codex-task-plan`
- `$codex-visual-review`

### Task 6: Prepare internal TestFlight runbook

Scope:

- internal tester group owner,
- build naming/versioning expectations,
- beta notes template,
- export-compliance answer owner,
- reviewer contact owner,
- rollback/removal notes.

Review:

- `$codex-task-work`
- `$codex-deployment-manager` before any real upload

### Task 7: Prepare external TestFlight / App Store submission gate

Scope:

- only after internal TestFlight is proven,
- finalize screenshots, age rating, privacy policy URL, review notes, and
  App Review contact info,
- define explicit “go / no-go” human checklist.

Review:

- `$codex-task-plan`
- `$codex-visual-review`
- `$codex-deployment-manager`

## Open decisions for humans

1. Is the first Apple distribution milestone `internal TestFlight only`, or
   does the owner want to fund external TestFlight/App Store readiness in the
   same phase?
2. Should the MVP Apple target be reduced to `iPhone only` before any listing
   asset work, or is iPad support a real launch requirement?
3. Does the owner want a non-Firebase first iOS artifact, or is iOS
   Crashlytics/Remote Config important enough to accept broader privacy-label
   work now?
4. What is the primary App Store language for the first Apple record?
5. Who is the human owner for:
   - App Store Connect app creation,
   - App ID registration,
   - signing/provisioning,
   - privacy-policy publishing,
   - export-compliance answers,
   - actual TestFlight/App Store upload?

## Human approval gates before any Apple distribution action

Before any App Store Connect record creation, build upload, internal TestFlight
share, external TestFlight invite, or App Store submission, require explicit
human approval for:

- Apple account/team to use,
- bundle ID and SKU,
- supported device scope,
- privacy-policy URL and Apple nutrition-label answers,
- whether iOS Firebase is off or on for the target artifact,
- screenshot set and any app preview,
- signing/provisioning owner and method,
- export-compliance answers,
- actual upload / distribution action.
