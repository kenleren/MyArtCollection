# Archivale Static Website

This directory contains the repo-managed static website surface for
`archivale.app`.

## Scope

Included routes:

- `/`
- `/privacy/`
- `/support/`
- `/pricing/`
- `/beta/`
- `/blog/`
- `/blog/collector-records-that-age-well/`
- `/blog/how-to-organize-provenance-records-private-art-collection/`
- `/blog/how-to-document-artwork-for-insurance-conversations/`
- `/blog/art-inventory-template-private-collectors/`
- `/blog/artwork-condition-report-checklist-private-collectors/`

`/updates/` is intentionally omitted in this task because the repo did not have
public-safe update content ready to publish.

## Boundaries

- Static HTML, CSS, and first-party local JavaScript only.
- No deploy, DNS change, Firebase Hosting mutation, or external publication.
- No analytics, cookies, trackers, JavaScript frameworks, external scripts, or
  third-party form tools.
- Support uses a static form that opens the user's mail client.
- Beta signup uses the repo-side first-party endpoint
  `/api/forms/beta-signup`, backed by the separate `backend/forms` package.
  Submissions are manual beta-interest records only, not beta access.

## Copy posture

This site is written as a launch-intent surface, not as proof that every app
flow is already live. That keeps the public copy factual while still allowing a
real pricing page.

Guardrails used here:

- Archivale is a private art record tool for serious hobby collectors.
- The product must not imply authenticity determination, certified provenance,
  appraisal certainty, official insurance approval, or guaranteed attribution.
- Backup, reports, exports, and AI-assisted behavior should only be described in
  ways that remain compatible with the current accepted product direction.

## Beta signup posture

The `/beta/` page collects only:

- email, required;
- name, optional;
- platform interest: Android, iOS, or both;
- country or time zone, optional;
- notes, optional and capped at 500 characters;
- consent and copy/retention versions;
- source route, client submit timestamp, and a hidden honeypot field.

The beta form must not ask for artwork, document, price, location, provenance,
photo, value, or collection details. Public copy must say that beta access is
manually approved and that submitting the form does not automatically add anyone
to Firebase App Distribution, Google Play testing, Auth, Remote Config, or
tester lists.

Retention copy for publication:

- pending beta-interest records: up to 90 days unless Archivale is actively
  contacting the person;
- rejected records: up to 30 days for audit and abuse review;
- honeypot spam: not queued by the repo handler;
- deletion requests: routed through support with a 30-day manual handling
  target.

The current backend package is buildable and testable without secrets, but its
default queue is in-memory only. Before collecting real submissions, a separate
reviewed change must add an approved durable queue/deletion adapter and record
the App Check or reCAPTCHA posture. Deployment still requires task review,
redteam/privacy review, visual review, deployment-manager approval, and explicit
human deploy approval.

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

## Collector notes

Blog posts are plain static HTML under `site/blog/<slug>/index.html`, with the
index at `site/blog/index.html`. Each published post should include:

- a page-specific `<title>` and meta description;
- conservative inline `schema.org` JSON-LD that matches visible page copy;
- a link from the blog index;
- copy that supports collector education without presenting Archivale as an
  authenticator, appraiser, insurer, certifier, or marketplace authority;
- footer/support routing through `/support/`, not a plain visible email address
  as the primary support UI.

Publication approval rule: every new post needs owner approval before it is
merged or published. Approval should check product truth, privacy posture,
claims guardrails, and whether the post describes only shipped behavior or
clearly labeled launch intent.

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
- `http://127.0.0.1:8000/beta/`
- `http://127.0.0.1:8000/blog/`
- `http://127.0.0.1:8000/blog/collector-records-that-age-well/`
- `http://127.0.0.1:8000/blog/how-to-organize-provenance-records-private-art-collection/`
- `http://127.0.0.1:8000/blog/how-to-document-artwork-for-insurance-conversations/`
- `http://127.0.0.1:8000/blog/art-inventory-template-private-collectors/`
- `http://127.0.0.1:8000/blog/artwork-condition-report-checklist-private-collectors/`

## Firebase Hosting config

Repo-side Firebase Hosting is intentionally minimal:

- `firebase.json` serves the `site/` directory only.
- Public HTML routes are configured to revalidate on every request.
- Static CSS, image, and logo assets use short-lived cache headers so brand
  fixes and rollback verification are not hidden by long browser or edge cache
  lifetimes.
- No `.firebaserc` is committed here, so Firebase project selection stays human/local CLI owned.
- No secrets, tokens, service accounts, or Google Cloud credential files are stored in the repo.

### Cache-control policy

Firebase Hosting headers in `firebase.json` use this policy:

- `/`, `/privacy/`, `/support/`, `/pricing/`, `/beta/`, `/blog/`,
  `/blog/collector-records-that-age-well/`,
  `/blog/how-to-organize-provenance-records-private-art-collection/`,
  `/blog/how-to-document-artwork-for-insurance-conversations/`,
  `/blog/art-inventory-template-private-collectors/`, and
  `/blog/artwork-condition-report-checklist-private-collectors/` send
  `Cache-Control: public, max-age=0, s-maxage=0, must-revalidate`.
- Direct HTML file requests matching `/**/*.html` send the same revalidation
  header so route documents do not persist stale HTML after deploy.
- `/styles.css`, `/scripts/**`, and `/assets/**` send
  `Cache-Control: public, max-age=3600, must-revalidate`.

The asset policy allows ordinary short browser and edge caching without
long-lived `immutable` behavior. That keeps post-deploy checks, urgent brand
fixes, and rollback verification understandable while still avoiding a no-cache
policy for every static byte.

### Syntax check

Validate the hosting config from the repository root:

```sh
jq . firebase.json
```

If `jq` is unavailable, use:

```sh
python3 -m json.tool firebase.json
```

### Static site validation

Validate static HTML shape, inline JSON-LD parsing, local `href`/`src`
resolution, first-party local script references, trust-copy guardrails for
structured data, disallowed external assets, and expected route smoke coverage
from the repository root:

```sh
python3 scripts/validate_static_site.py
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
- `/beta/`

For a full beta signup emulator path, the `backend/forms` Functions package
must also be built and wired into a Firebase emulator configuration. The
committed Hosting rewrite is only repo-side configuration; do not deploy it
until the backend review and deployment gates are approved.

### Human-owned publish steps

Publishing remains separate from repo config work and needs human-owned Firebase Console and deployment review:

1. Select the correct Firebase project in the local CLI.
2. Attach the `archivale.app` custom domain in Firebase Hosting.
3. Complete the DNS verification and certificate issuance steps in Firebase Console.
4. Run a live hosting smoke check after the site is attached.
5. Get deployment-manager review before any real publish or deploy.

Live smoke after a deploy should use both normal browsing and no-cache or
cache-busted requests. Confirm these live routes return the current Archivale
title/body copy, not stale MyArtCollection HTML, and confirm response headers
match the policy above:

- `https://archivale.app/`
- `https://archivale.app/privacy/`
- `https://archivale.app/support/`
- `https://archivale.app/pricing/`
- `https://archivale.app/beta/`
- `https://archivale.app/blog/`
- `https://archivale.app/blog/collector-records-that-age-well/`
- `https://archivale.app/blog/how-to-organize-provenance-records-private-art-collection/`
- `https://archivale.app/blog/how-to-document-artwork-for-insurance-conversations/`
- `https://archivale.app/blog/art-inventory-template-private-collectors/`
- `https://archivale.app/blog/artwork-condition-report-checklist-private-collectors/`
