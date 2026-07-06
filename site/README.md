# Archivale Static Website

This directory contains the repo-managed static website surface for
`archivale.app`.

## Scope

Included routes:

- `/`
- `/privacy/`
- `/support/`
- `/pricing/`
- `/blog/`
- `/blog/collector-records-that-age-well/`
- `/blog/how-to-document-artwork-for-insurance-conversations/`

`/updates/` is intentionally omitted in this task because the repo did not have
public-safe update content ready to publish.

## Boundaries

- Static HTML and CSS only.
- No deploy, DNS change, Firebase Hosting mutation, or external publication.
- No analytics, cookies, trackers, JavaScript frameworks, or backend form
  endpoint.
- Support uses a static form that opens the user's mail client.

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
- `http://127.0.0.1:8000/blog/`
- `http://127.0.0.1:8000/blog/collector-records-that-age-well/`
- `http://127.0.0.1:8000/blog/how-to-document-artwork-for-insurance-conversations/`

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

- `/`, `/privacy/`, `/support/`, `/pricing/`, `/blog/`,
  `/blog/collector-records-that-age-well/`, and
  `/blog/how-to-document-artwork-for-insurance-conversations/` send
  `Cache-Control: public, max-age=0, s-maxage=0, must-revalidate`.
- Direct HTML file requests matching `/**/*.html` send the same revalidation
  header so route documents do not persist stale HTML after deploy.
- `/styles.css` and `/assets/**` send
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
2. Attach the `archivale.app` custom domain in Firebase Hosting.
3. Complete the DNS verification and certificate issuance steps in Firebase Console.
4. Run a live hosting smoke check after the site is attached.
5. Get deployment-manager review before any real publish or deploy.

Live smoke after a deploy should use both normal browsing and no-cache or
cache-busted requests. Confirm `https://archivale.app/`,
`https://archivale.app/privacy/`, `https://archivale.app/support/`,
`https://archivale.app/pricing/`, `https://archivale.app/blog/`,
`https://archivale.app/blog/collector-records-that-age-well/`, and
`https://archivale.app/blog/how-to-document-artwork-for-insurance-conversations/`
return the current Archivale title/body copy, not stale MyArtCollection HTML,
and confirm response headers match the policy above.
