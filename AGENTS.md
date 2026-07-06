# Repository Guidance

This repository builds MyArtCollection, the private, local-first art inventory
app currently branded publicly as Archivale. The product promise is: photograph
an artwork, let AI draft cautious suggestions, let the collector confirm the
facts, attach supporting records, and keep the archive exportable.

## Product Rules

- Private by default and local-first.
- AI suggests; the user confirms.
- User-confirmed facts outrank AI output.
- Never claim authenticity, attribution certainty, appraisal certainty, market
  value, insurance approval, or provenance proof.
- Supporting documents enrich a record; they do not prove authenticity.
- Exports and reports must be clear about what is included and what is
  user-provided.

## Secret And Credential Rules

Do not read, print, move, validate, delete, screenshot, commit, or copy local
credentials or secrets. This includes:

- `.env.local`
- `/google/`
- `android/app/google-services.json`
- Firebase tokens, tester lists, service-account files, and debug logs
- OpenAI/admin/provider keys
- Android keystores, signing files, and signing passwords
- Apple signing or provisioning secrets
- billing or provider account secrets

Keep secret handling aligned with `docs/SECRET_HYGIENE.md`. If a task needs a
secret, record the human-owned blocker instead of inspecting the file.

## AI And Provider Boundaries

- Do not put provider keys in the mobile app.
- Do not call OpenAI or paid providers from mobile.
- Live OpenAI/provider use must go through a server-side broker with explicit
  consent, quota/credit metering, idempotency, redaction, rollback, and
  redteam/privacy/deployment review.
- On-device AI must stay behind `MY_ART_ON_DEVICE_AI_ENABLED` and must not send
  artwork images online for local draft attempts.
- `online_research_enabled` governs online professional-source research only;
  it must not control local on-device AI execution.
- Do not enable Blaze, mutate Firebase/provider/billing accounts, deploy
  provider infrastructure, or submit store builds without explicit owner
  approval and the accepted gates.

## Engineering Workflow

- Treat GitHub Projects as the live task source.
- Use a dedicated branch/worktree for implementation or rework.
- Start from `git status` and preserve unrelated dirty work.
- Do not reset, checkout, clean, or revert user/agent changes unless explicitly
  authorized and proven safe.
- Prefer existing app patterns over new abstractions.
- Keep changes scoped to the issue being worked.
- Add focused tests for changed behavior and run the relevant checks.
- UI-facing work needs mobile visual evidence when feasible.
- Security/privacy/provider/deployment-sensitive work needs redteam review.
- Do not mark implementation work complete without independent review.

## Frontend And Copy

- Build the actual product surface, not marketing filler, unless the task is
  explicitly a public website/blog/marketing task.
- Keep app UI collector-grade: calm, premium, dense enough for repeated use,
  and not decorative for its own sake.
- Use clear controls and familiar icons where appropriate.
- Text must fit on mobile and desktop without overlap.
- Follow `docs/COPY_TRUST_SPEC.md` for AI, privacy, documents, exports, and
  valuation-adjacent language.

## Documentation Sources

When changing behavior, check the relevant local docs first:

- `docs/NORTH_STAR.md`
- `docs/ARCHITECTURE.md`
- `docs/SECRET_HYGIENE.md`
- `docs/COPY_TRUST_SPEC.md`
- `docs/AI_BROKER_AUTH_AND_QUOTA_SPEC.md`
- `docs/AI_BROKER_PAYLOAD_AND_TELEMETRY_SPEC.md`
- `docs/COSTED_AI_BACKEND_GATE_SPEC.md`
- `docs/AI_PROVIDER_DATA_AND_SOURCE_RIGHTS_SPEC.md`
- `docs/FIREBASE_TELEMETRY_POLICY.md`
