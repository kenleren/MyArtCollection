# Workers Free release-policy adapter

Credential-free source adapter for the protected release-policy core. The public
Worker admits webhook and watchdog routes only; its Durable Object uses SQLite
CAS and an alarm-only drain signal. GitHub egress is constrained to the fixed
Check Runs route table. This package is synthetic evidence only: it neither
deploys nor registers an App, stores credentials, or proves Workers Free limits.

The duplicate-delivery SQLite fixture verifies completion of its original 17
receipts at a controlled checkpoint. After the second alarm captures that
cohort, it admits one additional witness and holds the witness's first snapshot
response in the next alarm. [Only one alarm runs at a time per object](https://developers.cloudflare.com/durable-objects/api/alarms/),
so reaching that next snapshot demonstrates that the original alarm finished.
The final readback response of the original cohort is deliberately delayed by
350 ms to reject a request-arrival counter used as a completion signal.

The witness remains gated through runtime disposal and stopped read-only SQLite
inspection. Each original receipt must be terminal, the separately named
witness must be the sole snapshotting receipt, and there must still be only one
generation, current pointer, binding, create and update. Both uninstrumented
lanes retain exact external equality. This checkpoint proves the original
cohort completed; it does not claim that all admitted work is idle. No live SQL,
runtime inspection hook, alternate bundle or production change is involved.
