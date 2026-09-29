# Archivale Play Billing Backend

This package implements the disabled `play-billing-v3` lifecycle-routing
source contract in `docs/PLAY_BILLING_ROUTING_V3_SPEC.md`. The earlier internal
v1 gate remains documented in `docs/PLAY_BILLING_GATE_SPEC.md`. It is isolated to Firebase
Functions codebase `play-billing` and named Firestore database
`archivale-play-billing`.

The checked-in runtime defaults to a disabled Play adapter. The
`GoogleAndroidPublisherTransport` is an Android Publisher REST transport using
application-default credentials at request time, but it is not constructed
unless the owner-controlled `PLAY_BILLING_ANDROID_PUBLISHER_ENABLED=enabled`
runtime configuration is present. Local and test runtimes therefore fail
closed. This source change does not authorize deployment, Firebase or Play
mutation, a purchase, or paid rollout.

All v3 callables require `PLAY_BILLING_ROUTING_ENABLED=enabled`.
Purchase preparation, account recovery and new verification additionally require explicit
`PLAY_BILLING_RECOVERY_ENABLED=enabled`. Custody requires
`PLAY_BILLING_TOKEN_CUSTODY_ENABLED=enabled`, the non-secret Firebase string
parameters `PLAY_BILLING_TOKEN_KEY_VERSION` and
`PLAY_BILLING_TOKEN_RETAINED_VERSIONS` (comma-separated exact approved versions),
and reviewed KMS IAM. None of these is enabled by source defaults. Fingerprint
and encryption keys are separate; no agent should inspect credential files.

Active v3 bindings/indexes and lifecycle roots/routes do not have a TTL based on stale observed expiry.
Post-expiry/deletion retention and unattended lifecycle remain launch blockers.
The disabled [account authority Stage A](../../docs/PLAY_BILLING_ACCOUNT_AUTHORITY_SPEC.md)
adds exclusive cross-token observation admission and atomic latest-state outbox
records, with durable root markers and no new TTL. No background ingress or
publisher is enabled; v3 client response/lease limitations remain explicit.

## Local Checks

```sh
npm --prefix backend/play_billing ci --ignore-scripts
npm --prefix backend/play_billing test
npm --prefix backend/play_billing audit --package-lock-only --audit-level=high
firebase emulators:exec --project demo-archivale-billing --only firestore \
  "npm --prefix backend/play_billing run test:emulator"
# Requires Java 21. This uses the lockfile-pinned firebase-tools dependency.
npm --prefix backend/play_billing run test:emulator:ci
```

Run Firebase/emulator checks with isolated HOME/XDG and no inherited provider
credentials, using the demo project only. Do not read generated debug logs.

The deterministic suite covers reciprocal routing/retirement, disclosure synchronization,
epoch-bound custody, encrypted fresh-install recovery, exact-version
KMS AAD/integrity, late deadline/disclosure/index fences, disclosure ordering, product/account/state
validation, delivery-before-acknowledgement, retry cooldowns, token
single-flight, generation-advancing reclaim, stale-owner rejection,
canceled-pending predecessor recovery, redaction, named-database targeting,
deny-all client rules, Firebase parameter fail-closed behavior, and
Firestore-emulator persistence/CAS coverage.

## Callable Cost And Configuration Gate

All five billing callables share this minimum-cost internal-test envelope:

- `minInstances=0`, `maxInstances=1`, and `concurrency=10`;
- existing `us-central1`, 60-second timeout, 512 MiB memory, dedicated runtime
  identity, and App Check enforcement remain unchanged; and
- `PLAY_BILLING_APPROVED_APP_ID` is a non-secret Firebase string parameter
  owned by deployment. It must name the approved App Check application at
  deployment; missing, unreadable, or mismatched values fail closed.

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
- approved App Check application identity and Google-backed Firebase Auth configuration;
- deployment-owner custody of the non-secret
  `PLAY_BILLING_APPROVED_APP_ID` Firebase parameter;
- fingerprint-key custody and an explicit active key version;
- an Android Publisher adapter with read/acknowledge-only authority, absolute
  deadlines, and retries disabled;
- explicit owner custody of `PLAY_BILLING_ANDROID_PUBLISHER_ENABLED` and the
  application-default runtime identity, with Android Publisher read and
  acknowledgement authority only; and
- approved rollback, budget, monitoring, privacy, redteam, and payment-owner
  evidence.

Rollback targets the five callables/codebase, runtime IAM, and the named
database rules/IAM. Routine rollback must not delete the billing database or
modify AI broker entitlements.
