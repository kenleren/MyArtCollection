# Workers Free release-policy adapter

Credential-free source adapter for the protected release-policy core. The public
Worker admits webhook and watchdog routes only; its Durable Object uses SQLite
CAS and an alarm-only drain signal. GitHub egress is constrained to the fixed
Check Runs route table. This package is synthetic evidence only: it neither
deploys nor registers an App, stores credentials, or proves Workers Free limits.
