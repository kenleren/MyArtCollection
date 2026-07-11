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
- `/blog/annual-art-collection-record-review-checklist/`
- `/blog/art-inventory-template-private-collectors/`
- `/blog/artwork-condition-report-checklist-private-collectors/`
- `/blog/artwork-location-inventory-for-private-collections/`
- `/blog/collector-records-that-age-well/`
- `/blog/how-to-document-artwork-for-insurance-conversations/`
- `/blog/how-to-organize-provenance-records-private-art-collection/`
- `/blog/how-to-photograph-artwork-for-private-records/`
- `/blog/how-to-prepare-art-records-for-family-handoff/`
- `/blog/how-to-prepare-artwork-records-before-a-move/`
- `/blog/how-to-record-artwork-labels-and-inscriptions/`
- `/blog/what-to-record-after-buying-artwork/`

`/updates/` is intentionally omitted in this task because the repo did not have
public-safe update content ready to publish.

## Boundaries

- Static HTML, CSS, and first-party local JavaScript only.
- No deploy, DNS change, Firebase Hosting mutation, or external publication.
- No third-party analytics, cookies, tracking pixels, JavaScript frameworks,
  external scripts, or third-party form tools. The existing first-party,
  DNT-aware aggregate pageview counter is frozen and must not expand here.
- Support uses a static form that opens the user's mail client.
- The beta page is wired for the reserved first-party route
  `/api/forms/beta-signup`, backed by the separate `backend/forms` package.
  Public Hosting keeps that route disabled by default until a durable queue and
  explicit deployment gate are approved. When enabled in a reviewed deploy,
  submissions are manual beta-interest records only, not beta access.

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
test queue is in-memory only and the public route is disabled by default.
Before collecting real submissions, a separate reviewed change must add an
approved durable queue/deletion adapter, record the App Check or reCAPTCHA
posture, and explicitly open the deployment gate. Deployment still requires
task review, redteam/privacy review, visual review, deployment-manager
approval, and explicit human deploy approval.

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
- a self-referencing `https://archivale.app` canonical URL with a trailing slash;
- exactly ten Open Graph fields and five Twitter fields aligned with the title,
  description, canonical URL, and primary schema node;
- `og:site_name=Archivale`, `twitter:card=summary_large_image`, and
  `og:type=article`;
- the checked-in `collector-room.png` social image declared as PNG at 1672x941,
  with neutral matching Open Graph and Twitter alt text;
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

The six non-article routes use `og:type=website`; only the twelve article routes
use `og:type=article`. Primary schema nodes are `WebPage#webpage` for home,
pricing, and beta; `ContactPage#webpage` for support; `PrivacyPolicy#webpage`
for privacy; `Blog#blog` for the notes index; and `BlogPosting#post` for each
article. The shared collection-room image is intentionally generic: it is an
accurate, already-public visual without article-specific attribution or a new
claim. Article-specific cards require separately approved assets.

Every route keeps the existing `/styles.css`, logo, JSON-LD, and
`/scripts/pageview-counter.js` inventory. Only home includes the collection-room
body image; only beta adds `/scripts/beta-signup.js` and its reserved form
action; only support uses its existing `mailto:` action. Metadata changes must
not expand executable code, body resources, pixels, trackers, or external calls.

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
- `http://127.0.0.1:8000/blog/annual-art-collection-record-review-checklist/`
- `http://127.0.0.1:8000/blog/art-inventory-template-private-collectors/`
- `http://127.0.0.1:8000/blog/artwork-condition-report-checklist-private-collectors/`
- `http://127.0.0.1:8000/blog/artwork-location-inventory-for-private-collections/`
- `http://127.0.0.1:8000/blog/collector-records-that-age-well/`
- `http://127.0.0.1:8000/blog/how-to-document-artwork-for-insurance-conversations/`
- `http://127.0.0.1:8000/blog/how-to-organize-provenance-records-private-art-collection/`
- `http://127.0.0.1:8000/blog/how-to-photograph-artwork-for-private-records/`
- `http://127.0.0.1:8000/blog/how-to-prepare-art-records-for-family-handoff/`
- `http://127.0.0.1:8000/blog/how-to-prepare-artwork-records-before-a-move/`
- `http://127.0.0.1:8000/blog/how-to-record-artwork-labels-and-inscriptions/`
- `http://127.0.0.1:8000/blog/what-to-record-after-buying-artwork/`

## Firebase Hosting config

Repo-side Firebase Hosting is intentionally minimal:

- `firebase.json` serves the `site/` directory only.
- `firebase.json` does not include the beta-signup Hosting rewrite by default.
- Public HTML routes are configured to revalidate on every request.
- Static CSS, image, and logo assets use short-lived cache headers so brand
  fixes and rollback verification are not hidden by long browser or edge cache
  lifetimes.
- No `.firebaserc` is committed here, so Firebase project selection stays human/local CLI owned.
- No secrets, tokens, service accounts, or Google Cloud credential files are stored in the repo.

### Cache-control policy

Firebase Hosting headers in `firebase.json` use this policy:

- `/`, `/privacy/`, `/support/`, `/pricing/`, `/beta/`, `/blog/`,
  `/blog/annual-art-collection-record-review-checklist/`,
  `/blog/art-inventory-template-private-collectors/`,
  `/blog/artwork-condition-report-checklist-private-collectors/`,
  `/blog/artwork-location-inventory-for-private-collections/`,
  `/blog/collector-records-that-age-well/`,
  `/blog/how-to-document-artwork-for-insurance-conversations/`,
  `/blog/how-to-organize-provenance-records-private-art-collection/`,
  `/blog/how-to-photograph-artwork-for-private-records/`,
  `/blog/how-to-prepare-art-records-for-family-handoff/`,
  `/blog/how-to-prepare-artwork-records-before-a-move/`,
  `/blog/how-to-record-artwork-labels-and-inscriptions/`, and
  `/blog/what-to-record-after-buying-artwork/` send
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

The validator enforces exactly 18 routes, globally unique normalized canonical
URLs, exact Open Graph and Twitter fields, primary-schema alignment, PNG bytes
and dimensions, sitemap equality, and the frozen first-party script/body-resource
inventory. It also rejects hidden unsafe claims, external assets, added scripts,
pixels, preloads, frames, cookies, and form-action expansion.

Run the focused fixtures and full validator from the repository root:

```sh
python3 -m unittest discover -s test -p 'validate_static_site_test.py'
python3 scripts/validate_static_site.py
python3 -m py_compile scripts/validate_static_site.py test/validate_static_site_test.py
```

Confirm that the checked-in sitemap is exactly what the deterministic generator
would produce without writing a file:

```sh
python3 -c 'from scripts import generate_sitemap as s; routes=sorted(s.route_for_html(p) for p in s.SITE_ROOT.glob("**/*.html")); routes.remove("/"); routes.insert(0, "/"); expected=s.sitemap_xml(routes); actual=s.SITEMAP_PATH.read_text(encoding="utf-8"); assert actual == expected, "site/sitemap.xml is stale"'
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
- `/blog/`
- `/blog/annual-art-collection-record-review-checklist/`
- `/blog/art-inventory-template-private-collectors/`
- `/blog/artwork-condition-report-checklist-private-collectors/`
- `/blog/artwork-location-inventory-for-private-collections/`
- `/blog/collector-records-that-age-well/`
- `/blog/how-to-document-artwork-for-insurance-conversations/`
- `/blog/how-to-organize-provenance-records-private-art-collection/`
- `/blog/how-to-photograph-artwork-for-private-records/`
- `/blog/how-to-prepare-art-records-for-family-handoff/`
- `/blog/how-to-prepare-artwork-records-before-a-move/`
- `/blog/how-to-record-artwork-labels-and-inscriptions/`
- `/blog/what-to-record-after-buying-artwork/`

For a full beta signup emulator path, the `backend/forms` Functions package
must also be built, given a durable queue implementation, and wired into a
Firebase emulator configuration with the explicit deployment gate enabled. Do
not expose the route publicly until the backend review and deployment gates are
approved.

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
- `https://archivale.app/blog/annual-art-collection-record-review-checklist/`
- `https://archivale.app/blog/art-inventory-template-private-collectors/`
- `https://archivale.app/blog/artwork-condition-report-checklist-private-collectors/`
- `https://archivale.app/blog/artwork-location-inventory-for-private-collections/`
- `https://archivale.app/blog/collector-records-that-age-well/`
- `https://archivale.app/blog/how-to-document-artwork-for-insurance-conversations/`
- `https://archivale.app/blog/how-to-organize-provenance-records-private-art-collection/`
- `https://archivale.app/blog/how-to-photograph-artwork-for-private-records/`
- `https://archivale.app/blog/how-to-prepare-art-records-for-family-handoff/`
- `https://archivale.app/blog/how-to-prepare-artwork-records-before-a-move/`
- `https://archivale.app/blog/how-to-record-artwork-labels-and-inscriptions/`
- `https://archivale.app/blog/what-to-record-after-buying-artwork/`
