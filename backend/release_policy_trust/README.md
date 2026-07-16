# Release policy trust core

This isolated Node 22 package is the credential-free, provider-neutral source
core for Archivale's dedicated external release-policy GitHub App. It accepts
injected raw webhook bytes, canonical policy bytes, expected numeric App and
installation identities, a durable-store port, and an allowlisted GitHub Check
Runs port. Policy selectors, repository/base identity, limits, check name, and
digest are derived only from the validated policy bytes. It does not read environment
variables, credentials, tokens, files, or sockets at runtime.

The conformance store executes the durable receipt, generation, fanout,
outbox, fenced Check binding, possible-send reconciliation, and terminal
aggregation protocols. A Check create/update is callable only while the exact
current generation holds the per-PR effect fence; creation is persisted as a
unique possible-send intent before the API call, and an ambiguous create is
reconcile-only forever.

The package is source and synthetic conformance evidence only. It does not
register, install, host, deploy, or authorize an App; provide a production
store or queue; change repository settings or rulesets; call a live GitHub API;
or establish that the trusted release policy is operational. See
`docs/RELEASE_POLICY_TRUST.md` for the ownership and deployment boundary.
