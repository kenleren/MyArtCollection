# Release policy trust core

This isolated Node 22 package is the credential-free, provider-neutral source
core for Archivale's dedicated external release-policy GitHub App. It accepts
injected raw webhook bytes, expected numeric identities, a durable-store port,
and an allowlisted GitHub Check Runs port. It does not read environment
variables, credentials, tokens, files, or sockets at runtime.

The package is source and synthetic conformance evidence only. It does not
register, install, host, deploy, or authorize an App; provide a production
store or queue; change repository settings or rulesets; call a live GitHub API;
or establish that the trusted release policy is operational. See
`docs/RELEASE_POLICY_TRUST.md` for the ownership and deployment boundary.
