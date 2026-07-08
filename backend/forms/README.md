# Archivale Forms Backend

This package contains the repo-side beta signup endpoint for Firebase Functions
2nd gen. It is intentionally separate from `backend/broker` because beta signup
submissions are manual queue records, not AI/provider broker traffic.

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

Unknown fields are rejected. The handler validates method, content type, origin
when an origin header is present, consent, length caps, honeypot, duplicate
submissions, and per-submitters rate limits.

## Queue Boundary

The default Firebase export uses an in-memory queue adapter so the repo can be
built and tested without secrets, service accounts, Firestore setup, App
Distribution access, Google Play access, or deploys. It is not durable and is
not a production storage implementation.

A production queue adapter must be added in a separate reviewed change before
collecting real submissions. That adapter should write only manual beta-interest
records and must not add people to Firebase App Distribution, Google Play,
Auth, Remote Config, tester lists, or any other tester system.

## Local Checks

From this directory:

```sh
npm install
npm test
```

No `.env.local`, Firebase credential files, service accounts, tester lists, or
provider keys are required or should be read for these checks.

## Deployment Gate

The Firebase Hosting rewrite in `firebase.json` is repo-side config only. No
deploy is authorized by this package. A real deploy still requires task review,
redteam/privacy review, visual review, deployment-manager approval, owner
approval for the Firebase project and billing posture, App Check or reCAPTCHA
decision, budget alert evidence, durable queue/deletion implementation, and
explicit deploy approval.
