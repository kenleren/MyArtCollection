# Release policy trust source and deployment boundary

Archivale's release-policy trust check is designed as a dedicated external
GitHub App check. The repository-owned package at
`backend/release_policy_trust/` is only its provider-neutral, credential-free
source core and synthetic conformance harness. Source acceptance does not make
the check operational and does not establish that a pull request is safe to
merge.

## What this repository owns

The package verifies an injected raw webhook body before parsing it, binds
positive numeric App, installation, and repository identities, builds an
immutable pull-request/main/files snapshot, evaluates current and prior paths,
and emits work through durable CAS/outbox interfaces. Its GitHub port has only
typed pull-request, main-ref, file, open-PR, App-owned Check Run listing,
Check Run creation, and bound Check Run update operations. Commit statuses,
generic HTTP, GraphQL, token acquisition, `neutral`, and `skipped` conclusions
are not part of the port.

The canonical policy treats protected-path additions, modifications, removals,
copies, rename sources, and rename targets as failures. Malformed, duplicate,
case-folding, Unicode, identity, pagination, snapshot, storage, lease, API, or
check-creation ambiguity is fail-closed and cannot produce success. A
same-named GitHub Actions check is not accepted as the external App check.

The committed base evidence is anchored only to ancestry of
`f42582c8eb0d1405cd5e214f6b9c80980225b5f1`. The policy, exact current-tree
inventory, full-history relations, external-input manifest, CODEOWNERS file,
claim matrix, reproducibility record, and final candidate summary are
deterministic review inputs. They contain no credentials or provider data.

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
candidate SHA. Exact-head Release Readiness must then succeed while `main`
remains the recorded bootstrap base. Deployment or merge authorization is not
implied by any of those source checks.
