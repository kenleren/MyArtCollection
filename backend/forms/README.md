# Archivale Forms Backend

This package contains repo-side public website endpoints for Firebase Functions
2nd gen. It is intentionally separate from `backend/broker` because these
requests are website form or aggregate counter traffic, not AI/provider broker
traffic.

## Endpoint

- Hosting route: `POST /api/forms/beta-signup`
- Firebase export: `betaSignup`
- Runtime adapter: `src/firebase.ts`
- Pure testable handler: `src/beta_signup.ts`

The public request body is JSON only and accepts these fields:

- `email` required
- `name` optional
- `platform` required: `android`, `ios`, or `both`
- `country` optional
- `notes` optional, capped at 500 characters
- `consent` required and must be `true`
- `consentVersion` required: `beta-signup-2026-07-08`
- `retentionVersion` required: `beta-signup-retention-2026-07-08`
- `sourceRoute` required: `/beta/`
- `submittedAtClientMs` required for spam timing checks
- `website` hidden honeypot, expected to be empty

Unknown fields are rejected. The handler validates method, content type,
required same-origin `Origin`, consent, length caps, honeypot, duplicate
submissions, and per-submitter rate limits.

## Queue Boundary

The pure queue/test adapter uses an in-memory queue so the repo can be built
and tested without secrets, service accounts, Firestore setup, App
Distribution access, Google Play access, or deploys. It is not durable and is
not a production storage implementation.

A production queue adapter must be added in a separate reviewed change before
collecting real submissions. That adapter should write only manual beta-interest
records and must not add people to Firebase App Distribution, Google Play,
Auth, Remote Config, tester lists, or any other tester system.

Queued records intentionally contain only the minimal beta-interest fields,
consent/retention versions, and submit time. The repo handler does not persist
raw IP address, browser origin, or user-agent in the queue record.

## Local Checks

From this directory:

```sh
npm install
npm test
```

No `.env.local`, Firebase credential files, service accounts, tester lists, or
provider keys are required or should be read for these checks.

## Aggregate Site Counter

- Hosting route: `POST /api/site/pageview`
- Firebase export: `sitePageview`
- Runtime adapter: `src/firebase.ts`
- Pure testable handler: `src/site_analytics.ts`
- Firestore collection: `site_daily_pageviews` by default, or
  `SITE_PAGEVIEW_COLLECTION` when set

The public request body accepts only:

- `path`: normalized site path only, without query string or hash
- `referrerCategory`: `direct`, `internal`, or `external`
- `screenBucket`: `small`, `medium`, `large`, or `unknown`

The handler requires same-origin JSON POST requests and writes daily aggregate
increments by path. It does not store IP address, user-agent, raw referrer,
cookies, local storage identifiers, visitor IDs, email addresses, artwork
details, prompts, provider responses, or per-visitor event rows.

## Deployment Gate

`firebase.json` does not expose the beta-signup Hosting rewrite by default. The
beta-signup Firebase export in `src/firebase.ts` also fails closed with `503
beta_signup_disabled` unless both of these non-default settings are present:

- `BETA_SIGNUP_HTTP_ENABLED=true`
- `BETA_SIGNUP_QUEUE_MODE=durable`

Those beta-signup flags are a deployment-manager gate only. This repo does not
include a durable beta signup queue/deletion implementation yet, so the
beta-signup export still returns `503 beta_signup_disabled` even when both flags
are set.

The aggregate site counter is intentionally narrower and may be deployed
independently when the owner approves website analytics. It still requires
normal review, Firebase project approval, rollback evidence, and post-deploy
smoke checks.
