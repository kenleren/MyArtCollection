# Account observation authority — disabled L2 Stage A (#194)

Status: implementation candidate for independent task/payment/privacy review.
The v3 mobile wire and disclosure contract remain unchanged. No live background
trigger, event inbox, scheduler, broker publisher, deletion workflow, provider
configuration or activation is included. Stage A alone does not complete #194
or public paid launch.

## Shared verification and exclusive admission

Authenticated callable wrappers derive the existing opaque account subject and
request fingerprint once. `processAccountObservation` takes that server-internal
context and a foreground/background source label; it does not require a raw
UID. It is not a callable or external API. A future background adapter must
resolve an account through trusted routing before invoking it. Root, reciprocal
route, disclosure, token, index and account-owner checks remain mandatory; a
TypeScript handle is not sufficient authority. The unchanged callables still
require fresh approved-app App Check and revoked-checked Google identity.

One exclusive observation covers an account across different tokens. Admission
atomically reserves the account generation/nonce, token owner, replay and existing
cost counter. Failed token/account admission writes none of them. A live account
lease blocks another token. After the 90-second lease expires, new admission
increments the safe-integer generation and replaces its random nonce; old work
cannot stage, acknowledge, publish or pass final response validation. Existing
token leases, cooldowns, chain checks and nontransferable verified ownership
remain. Never-verified unbound token bookkeeping still cannot permanently block
the rightful account. A canceled-pending predecessor switch uses one account
observation with a new selected-token owner and one bounded hop.

The source-only background entry currently uses the same conservative test
budget as foreground. No background traffic is enabled. Stage B must introduce
its separately reserved operator budgets before exposing an ingress or pump;
this slice does not claim production background capacity.

## Durable high-water and latest-state outbox

Two server-only collections are added: `playBillingAccountAuthority` and
`playBillingAuthorityOutbox`, both keyed by opaque account subject. The strict,
bounded authority record contains epoch/generation, observation generation,
optional owner (work fingerprint, nonce, selected token, source, phase/lease),
optional acknowledgement-recovery token fingerprint, publication revision and
the latest complete snapshot. The outbox holds that snapshot and its canonical
SHA-256 consistency digest. Neither contains a raw UID, token or ciphertext.
These fixed schemas fit within 4 KiB each; no arbitrary metadata or attempt
history is accepted. No TTL is added.

First initialization atomically adds `authorityVersion` and
`authorityPublicationRevision` to the lifecycle root and writes authority plus
outbox. Initial state is requires-verification at revision zero, never cached
paid state. Subsequently root marker, authority revision and outbox snapshot
must agree. Missing/malformed authority/outbox, a lost marker or unequal payload
at the same revision fails closed, including prepare/disclosure operations;
there is no reset or silent repair. Loss of the root with surviving authority
also fails. Generation/revision exhaustion rejects admission and mutations.

Existing valid L1 accounts may initialize after a coordinated writer cutover.
Validated current/candidate bindings preserve any already-started or ambiguous
acknowledgement barrier, including when disclosure reacceptance is the first
Stage A action. Legacy/malformed records are not migrated. Retired L1 roots
remain terminal and never adopt old-generation custody. Deploying mixed L1/L2
writers is unsupported: stop old writers and drain their 90-second leases before
activating this source. This is a future deployment requirement, not an executed
migration or approval.

Paid finalization atomically updates binding/index, completes the account owner,
advances publication revision and stores the complete authority snapshot/outbox.
A fresh account-current inactive observation likewise commits index invalidation
and the no-paid snapshot together. An unrelated or pending successor's inactive
result cannot overwrite a still-current chain's account snapshot. It neither
refreshes the old snapshot's verified time nor establishes fresh paid authority
for it. Later lifecycle processing still needs to recheck that current chain.

A latest-state slot is convergence state, not a payment ledger. New complete
snapshots replace older unsent snapshots. This slice never sends or marks one
delivered. A future publisher must bind delivery acknowledgement to the captured
revision/digest; it cannot clear a newer slot. Consumers, retention and financial
history are separate reviewed work.

## Interrupted acknowledgement and disclosure

Before ACK dispatch, custody/index are already durable and the account stores an
acknowledgement-recovery token. A different token cannot steal that barrier after
lease expiry or uncertain network response. Only a fresh same-token query may
resume: an acknowledged or authoritative terminal observation clears the barrier;
an eligible unacknowledged observation may use an existing bounded ACK attempt.
Transient/malformed results preserve the barrier. No blind replay of an old POST
or stored Play response is permitted. A barrier that cannot resolve remains
blocked; no new support reset or automatic transfer is introduced.

Disclosure acceptance/revocation atomically invalidates outstanding account
observation ownership with a new generation and publishes requires-verification
or revoked state. Reacceptance never republishes cached paid access. A retained
ACK barrier survives pause/reaccept. Internal lifecycle retirement advances the
epoch's lifecycle generation and publishes retired authority in the root/route
transaction. Reacceptance cannot revive it. Missing high-water is not repaired to
make deletion succeed; the actual deletion workflow remains separate work.

## Precisely bounded response guarantee

Server mutations and **final server validation** reject a stale observation after
a newer account commit. Both old-paid/new-inactive and old-inactive/new-paid
orderings are tested. This ordering guarantee ends at that final validation.
A response already validated or emitted can still arrive after another server
commit, and the unchanged v3 mobile client receives no publication revision or
background invalidation message. Stage A cannot retract that response or an
existing maximum 15-minute memory lease. Tests preserve this limitation rather
than claiming instant mobile revocation. The seven-day signed lease/client
revision and broker contracts remain separately reviewed follow-ons.

A deadline invalidates later provider dispatch and authority checks, but cannot
physically undo a Firestore commit whose callback already returned or a remote
ACK already dispatched. Durable owners and retries handle those ambiguous cases.

## Validation and remaining launch work

Focused tests cover opaque-subject recovery, exclusive cross-token admission,
failed-reservation rollback, forged handles, nonce/generation/publication overflow,
root/authority/outbox loss, disclosure/retirement, L1 cutover, interrupted ACK and
final-response ordering. Named Firestore tests exercise concurrent admission,
rollback of finalization, restart/reclaim, consistent snapshot/outbox commits and
client denial of both new collections. Provider interaction remains synthetic.

Stage B ingress/event custody/retry transport, L3 reconciliation and void scans,
L4 broker credits/deletion, seven-day offline creation, retention/privacy/spend
policy, operational monitoring and real Play purchase/lifecycle evidence are
still required before public paid launch. No owner retention or pricing decision
is implied by these disabled source records.
