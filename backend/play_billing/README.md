# Archivale Play Billing Backend

This package implements the internal-track `play-billing-v1` verification
contract from `docs/PLAY_BILLING_GATE_SPEC.md`. It is isolated to Firebase
Functions codebase `play-billing` and named Firestore database
`archivale-play-billing`.

The checked-in runtime uses a disabled Play adapter. It cannot call Android
Publisher until a separately reviewed adapter and deployment gate replace that
fail-closed boundary. Nothing in this package authorizes deployment, Firebase
or Play mutation, a purchase, or paid rollout.

## Local Checks

```sh
npm --prefix backend/play_billing ci
npm --prefix backend/play_billing test
npm --prefix backend/play_billing audit --package-lock-only --audit-level=high
firebase emulators:exec --project demo-archivale-billing --only firestore \
  "npm --prefix backend/play_billing run test:emulator"
```

The deterministic suite covers disclosure ordering, product/account/state
validation, delivery-before-acknowledgement, retry cooldowns, token
single-flight, generation-advancing reclaim, stale-owner rejection,
canceled-pending predecessor recovery, redaction, named-database targeting,
and deny-all client rules.

## Deployment Gate

Before any deployment, the human-owned gate must provide and independently
review all of the following without recording credential or billing identity
material:

- creation of the named database in `us-central1` with delete protection;
- database-targeted deny-all rules, indexes, and TTL policies;
- a dedicated verifier runtime identity with database-conditioned IAM and no
  access to `(default)` or broker data;
- negative IAM evidence proving the broker cannot access billing records and
  the verifier cannot access broker, artwork, or attachment records;
- approved App Check application identity and anonymous Auth configuration;
- fingerprint-key custody and an explicit active key version;
- an Android Publisher adapter with read/acknowledge-only authority, absolute
  deadlines, and retries disabled; and
- approved rollback, budget, monitoring, privacy, redteam, and payment-owner
  evidence.

Rollback targets the three callables/codebase, runtime IAM, and the named
database rules/IAM. Routine rollback must not delete the billing database or
modify AI broker entitlements.
