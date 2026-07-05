# MyArtCollection Static Website

This directory contains the repo-managed static website surface for
`myartcollection.app`.

## Scope

Included routes:

- `/`
- `/privacy/`
- `/support/`
- `/pricing/`

`/updates/` is intentionally omitted in this task because the repo did not have
public-safe update content ready to publish.

## Boundaries

- Static HTML and CSS only.
- No deploy, DNS change, Firebase Hosting mutation, or external publication.
- No analytics, cookies, trackers, JavaScript frameworks, forms, or backend.
- Support uses `mailto:ken.leren@icloud.com`.

## Copy posture

This site is written as a launch-intent surface, not as proof that every app
flow is already live. That keeps the public copy factual while still allowing a
real pricing page.

Guardrails used here:

- MyArtCollection is a private art record tool for serious hobby collectors.
- The product must not imply authenticity determination, certified provenance,
  appraisal certainty, official insurance approval, or guaranteed attribution.
- Backup, reports, exports, and AI-assisted behavior should only be described in
  ways that remain compatible with the current accepted product direction.

## Pricing rationale

The accepted pricing decision for issue `#93` is:

- Free tier included
- Paid `Collector` plan at `USD 9/month` or `USD 79/year`

The public-safe rationale, drawn from the linked issue decisions and GTM docs:

- free lowers trial friction;
- paid is for serious hobby collectors who want organized records, supporting
  documents, and report-oriented workflows without registrar-level pricing.

Future edits to pricing copy should stay deliberate and should be checked
against `docs/GTM_PLAN.md`, `docs/PRODUCT_PLAN.md`, and
`docs/COPY_TRUST_SPEC.md`.

## Local preview

From the repository root:

```sh
cd site
python3 -m http.server 8000
```

Then open:

- `http://127.0.0.1:8000/`
- `http://127.0.0.1:8000/privacy/`
- `http://127.0.0.1:8000/support/`
- `http://127.0.0.1:8000/pricing/`

## Firebase Hosting config

Repo-side Firebase Hosting is intentionally minimal:

- `firebase.json` serves the `site/` directory only.
- No `.firebaserc` is committed here, so Firebase project selection stays human/local CLI owned.
- No secrets, tokens, service accounts, or Google Cloud credential files are stored in the repo.

### Syntax check

Validate the hosting config from the repository root:

```sh
jq . firebase.json
```

If `jq` is unavailable, use:

```sh
python3 -m json.tool firebase.json
```

### Ad hoc local hosting preview

When you want a Firebase-style static preview without adding a repo dependency, run the Firebase CLI ad hoc from the repository root:

```sh
npx --yes firebase-tools@latest emulators:start --only hosting --project demo-myartcollection
```

Then open the local URL printed by the emulator and confirm the same public routes:

- `/`
- `/privacy/`
- `/support/`
- `/pricing/`

### Human-owned publish steps

Publishing remains separate from repo config work and needs human-owned Firebase Console and deployment review:

1. Select the correct Firebase project in the local CLI.
2. Attach the `myartcollection.app` custom domain in Firebase Hosting.
3. Complete the DNS verification and certificate issuance steps in Firebase Console.
4. Run a live hosting smoke check after the site is attached.
5. Get deployment-manager review before any real publish or deploy.
