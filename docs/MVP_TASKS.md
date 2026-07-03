# MVP Task Breakdown

This is the initial task map for MyArtCollection. The GitHub Project is verified at:

https://github.com/users/kenleren/projects/1

Current status: the Project exists and is named `MyArtCollection`, but it has no items yet.

## Recommended Sequencing

Do not start by building screens. Start by locking the trust, data, and product rules that all screens must obey.

## Phase 0: Project Setup

### 1. Configure GitHub Project workflow

Acceptance check:

- Project has statuses that support Backlog, Todo, In Work, For Review, Ready to Deploy, Blocked, and Complete, or an explicit documented mapping from the current default statuses.
- Project has fields or issue conventions for owner type, priority, evidence, risk, and next action.

Suggested skill:

- `codex-github-projects-cutover`

### 2. Create initial issue backlog

Acceptance check:

- The first MVP issues are created and added to the verified Project.
- Each issue has scope, non-goals, acceptance check, owner type, evidence required, and review path.

Suggested skill:

- `codex-task-manager`

## Phase 1: Product And Trust Foundation

### 3. Define product language and trust rules

Acceptance check:

- Repo contains a UX copy spec for AI uncertainty, privacy, and non-claims.
- Disallowed claims are explicit.
- Copy examples exist for onboarding, AI draft review, settings, and export.

Suggested skill:

- `codex-task-work`

### 4. Write mobile information architecture

Acceptance check:

- Routes, navigation model, object model, and record states are documented.
- First-run flow and returning-user flow are both covered.

Suggested skills:

- `codex-task-plan`
- `codex-task-plan-review`

### 5. Specify artwork record schema

Acceptance check:

- Required and optional fields are documented.
- Attachment model and provenance labels are defined.
- Export fields and validation rules are documented.

Suggested skill:

- `codex-task-work`

## Phase 2: Technical Foundation

### 6. Scaffold Flutter app

Acceptance check:

- iOS and Android Flutter project builds locally.
- Basic app shell runs.
- Initial route structure exists.
- Lint/test command is documented.

Suggested skills:

- `codex-task-plan`
- `codex-task-work`
- `codex-task-review`

### 7. Implement local record storage

Acceptance check:

- SQLite schema supports artworks, photos, documents, reports, AI jobs, and sync state.
- Basic create/read/update/delete flows are covered by tests.
- Sensitive local storage approach is documented.

Suggested skills:

- `codex-task-plan`
- `codex-task-work`
- `codex-task-review`

### 8. Design and implement attachment storage

Acceptance check:

- Photos, scans, PDFs, and generated reports can be saved in app-private storage.
- Size and file-type limits are defined.
- Attachment metadata links to artwork records.

Suggested skills:

- `codex-task-work`
- `codex-task-review`

### 9. Design crypto envelope

Acceptance check:

- Master key, platform key storage, passphrase wrapping, manifest format, and chunk format are specified.
- Restore and lost-passphrase behavior are documented.
- Redteam review gates are listed.

Suggested skills:

- `codex-research-spec`
- `codex-redteam-review`

## Phase 3: Capture And Review Experience

### 10. Build camera/photo/document import

Acceptance check:

- App can capture or import artwork photos.
- App uses privacy-preserving system pickers.
- No broad photo-library permission is required where platform pickers avoid it.

Suggested skills:

- `codex-task-plan`
- `codex-task-work`
- `codex-visual-review`

### 11. Build AI draft review screen

Acceptance check:

- Suggested fields are visually distinct from confirmed fields.
- Low-confidence and unknown states are clear.
- User confirmation is required before saving as verified.

Suggested skills:

- `codex-task-plan`
- `codex-task-work`
- `codex-visual-review`

### 12. Build collection home and incomplete-record queue

Acceptance check:

- User can scan the collection quickly.
- Completeness and missing documents are visible.
- Empty states guide the next action.

Suggested skills:

- `codex-task-work`
- `codex-visual-review`

## Phase 4: Backup, AI, And Reports

### 13. Implement Google Drive backup and restore

Acceptance check:

- Uses Drive `appDataFolder`.
- Backup payload is encrypted.
- Restore works on a fresh app install with the recovery path.
- Disconnect behavior is documented and tested.

Suggested skills:

- `codex-task-plan`
- `codex-task-work`
- `codex-redteam-review`

### 14. Build AI broker contract

Acceptance check:

- Request and response schemas are documented and validated.
- AI output includes field source, uncertainty, and evidence snippets.
- AI upload consent is explicit.
- No client-side AI vendor secret exists in the mobile app.

Suggested skills:

- `codex-task-plan`
- `codex-task-work`
- `codex-redteam-review`

### 15. Generate insurance PDF

Acceptance check:

- User can generate a clean PDF from selected or all artworks.
- PDF includes images, confirmed metadata, attached-document index, and date generated.
- PDF avoids authenticity or appraisal claims.

Suggested skills:

- `codex-task-work`
- `codex-visual-review`

### 16. Generate full export archive

Acceptance check:

- User can export structured data plus attachments.
- Export format is documented.
- Export destination is explicit and user-selected.

Suggested skills:

- `codex-task-work`
- `codex-redteam-review`

## Phase 5: Monetization And Release Readiness

### 17. Define pricing and paywall triggers

Acceptance check:

- Free and paid entitlements are documented.
- Paywall placement is defined.
- Cancellation and export posture is documented.

Suggested skill:

- `codex-task-work`

### 18. Implement billing

Acceptance check:

- Apple IAP and Google Play Billing strategy is documented before implementation.
- Entitlement model is tested.
- Purchase restore flow works.

Suggested skills:

- `codex-task-plan`
- `codex-task-work`
- `codex-redteam-review`

### 19. Create store privacy and data safety checklist

Acceptance check:

- Apple App Privacy and Google Play Data safety answers are drafted.
- SDK behavior matches declarations.
- Encryption/export compliance questions are identified.

Suggested skills:

- `codex-task-work`
- `codex-redteam-review`
- `codex-deployment-manager`

### 20. Beta readiness review

Acceptance check:

- Build can be distributed to a beta channel.
- Core add-artwork flow works end to end.
- Backup, export, and report flows have evidence.
- Privacy and AI consent flows are reviewed.

Suggested skills:

- `codex-task-review`
- `codex-visual-review`
- `codex-redteam-review`
- `codex-deployment-manager`
- `codex-beta-tester`

## Initial Parallel Work Map

Safe to run in parallel after Project setup:

- Product language and trust rules
- Artwork record schema
- GTM validation page/interview script
- Technical ADR and storage schema

Run serially:

- Crypto envelope before Drive backup implementation
- AI broker contract before AI review UI implementation
- Billing after pricing and entitlement decisions

