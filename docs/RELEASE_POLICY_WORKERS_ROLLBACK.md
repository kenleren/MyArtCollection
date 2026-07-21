# Workers Free release-policy rollback boundary

This source-only runbook never authorizes deployment. Before any code change,
freeze the reviewed artifact, activation, compatibility, and schema digests;
stop ingress and alarm draining; and capture a verified backup. A code-only
rollback is permitted only to an independently reviewed artifact declaring the
identical reader/writer schema, compatibility digest, and activation digest.

Do not start a v1 or otherwise incompatible artifact against a v2 database.
For any digest or reader/writer mismatch, preserve the source database and
restore a verified compatible snapshot into a separate empty namespace. Run
synthetic adoption and replay checks there, abort on drift, and obtain the
separate deployment-review authorization before changing routing. Live backup,
credential custody, real-App scope inspection, and deployed recovery proof
remain owner-operated gates.
