# Release policy trust source and deployment boundary

Archivale's release-policy trust check is designed as a dedicated external
GitHub App check. The repository-owned package at
`backend/release_policy_trust/` is only its provider-neutral, credential-free
source core and synthetic conformance harness. Source acceptance does not make
the check operational and does not establish that a pull request is safe to
merge.

## What this repository owns

The package validates canonical policy bytes and computes their digest
internally before using their repository/base identity, limits, selectors, or
check name. Its emitted JavaScript exports no policy constructor; a module-private
factory token and registry make prototype, property, or symbol copying fail the
runtime origin assertion. It verifies an injected raw webhook body before parsing it, binds
positive numeric App, installation, and repository identities, builds an
immutable pull-request/main/files snapshot, evaluates current and prior paths,
and persists the complete tuple, snapshot, file digest, policy, and decision.
Only a CAS-protected `decision_ready` generation can proceed to completion.
Its GitHub port has only
typed pull-request, main-ref, file, open-PR, App-owned Check Run listing,
Check Run creation, and bound Check Run update operations. Commit statuses,
generic HTTP, GraphQL, token acquisition, `neutral`, and `skipped` conclusions
are not part of the port.

The canonical policy treats protected-path additions, modifications, removals,
copies, rename sources, and rename targets as failures. Malformed, duplicate,
full-Unicode-case-folding, identity, pagination, snapshot, storage, lease, API, or
check-creation ambiguity is fail-closed and cannot produce success. A
same-named GitHub Actions check is not accepted as the external App check.

Receipt processing is resumable through the explicit `received`, `snapshotting`,
`enqueued`, and terminal states; there is no unused synthetic processing state.
Delivery-ID conflict is an absorbing durable state before or after completion.
When work already completed, the receipt retains its terminal outcome separately
without allowing either payload to replay the side effect. Pull
generation/current/outbox state is atomic. Push target lists and digests are
durable, each child has a CAS lease, and the parent receipt records its terminal
outcome only after all children do. Ambiguous store commits are resolved by exact
durable reread. The Check binding stores
App/repository/head/name/external/check identities. Unique create and update
intents enter possible-send state before an external call. Ambiguous creation
is reconciled without recreation; ambiguous update retries only its already
bound numeric Check ID. A per-PR fence prevents a newer generation from being
admitted while an external effect is in flight.

The committed base evidence is anchored only to ancestry of
`f42582c8eb0d1405cd5e214f6b9c80980225b5f1`. Pull-request verification keeps
that base immutable while requiring `origin/main` to equal the event's exact
base SHA and the candidate to descend from it. Post-merge verification requires
the candidate, the event's expected main SHA, and `origin/main` to be identical;
the prior push SHA (or the candidate's first parent for manual dispatch) must be
an ancestor, and the frozen base must remain an ancestor of both. The workflow
and package verifier independently classify the exact event change range and
fail if their results differ. Their agreed result selects one of two fail-closed
paths. If the trust-source
package, workflow, CODEOWNERS mirror, or trust/readiness runbooks changed, CI
runs the complete frozen policy, candidate inventory, summary, and reproducibility
gate. If none changed, CI still builds and tests the unchanged source, verifies
its frozen evidence, anchors the exact candidate and event main, checks the
generated CODEOWNERS and external-input contracts, and reproduces the package;
only the obsolete full-repository candidate byte comparison is skipped. The policy, exact current-tree
inventory, full-history relations, external-input manifest, CODEOWNERS file,
claim matrix, reproducibility record, and final candidate summary are
deterministic review inputs. They contain no credentials or provider data.
The summary verifies every dependent digest and test count. For trust-source
changes, CI regenerates and byte-compares the complete candidate inventory; all
runs byte-compare reproducibility evidence. External
integrity algorithms have strict digest syntax; workflow Action/tool pins,
locks, apt/audit runtime evidence, and generated-output contracts are
mechanically reconciled with the external manifest.

## What remains outside this repository

Issue #196 separately owns provider and host selection, a production durable
store/outbox and single-writer queue, monitoring and rollback, webhook and App
private-key custody, App registration and installation, live disposable
preflight, ruleset creation and activation, integration-ID inspection, and
negative/positive merge proof. Those steps require their accepted deployment
and security gates plus explicit owner authorization.

Agents and this source task must not read credentials, call live Check APIs,
register or install an App, host or deploy the package, mutate repository
settings or rulesets, create a bypass, or merge the bootstrap pull request.
Any change to the frozen base, candidate artifact, policy, inventory, package
lock, external manifest, ruleset hash, or reviewed commit invalidates dependent
evidence and requires regeneration and the applicable independent reviews.

## Synthetic verification

From the repository root, use the exact commands recorded in
`backend/release_policy_trust/evidence/claim-matrix.v1.json`. The focused tests
cover raw HMAC ordering, replay and delivery conflict, strict pagination,
protected paths, fork/head/base/main races, receipt/outbox crash boundaries,
CAS loss, stale or ambiguous work, exact App-owned check adoption, and the
typed API boundary. `scripts/secret_scan.sh` remains the redacted repository
secret gate; it must never be replaced with manual inspection of ignored or
local credential paths.

Independent task review and security redteam must both ACCEPT the same frozen
candidate SHA. Exact-head Release Readiness must succeed for the reviewed pull
request head, and the exact merge SHA must pass again on `main`. Deployment or
merge authorization is not implied by any of those source checks.
