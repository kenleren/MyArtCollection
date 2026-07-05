# Secret Hygiene

This repository treats Firebase credentials, tester lists, and local Firebase
debug output as non-source artifacts. They must stay out of Git history and out
of pull request logs.

## Firebase Credential Rules

- Prefer an out-of-repository service-account JSON path for automation:
  `GOOGLE_APPLICATION_CREDENTIALS=/path/outside/repo/service-account.json`.
- Local developer environment values may live in `.env.local`, which is
  ignored by Git. Keep `.env.local.example` as the tracked template and never
  paste real values into commits, issue comments, screenshots, or logs.
- The legacy local `/google/` directory remains ignored only as a compatibility
  boundary. Do not inspect it, validate it, move it, or commit anything from it.
- Do not commit service-account JSON, `google-services.json`,
  `GoogleService-Info.plist`, Firebase tokens, tester email lists, or
  `firebase-debug.log`.
- Do not paste credential values into issue comments, release notes, CI logs,
  screenshots, or scanner baselines.

## Secret Scan

Run the repository guardrail before pushing Firebase or release-process changes:

```sh
scripts/secret_scan.sh
```

The wrapper first blocks tracked Firebase credential/config paths, then runs
Gitleaks with `.gitleaks.toml` and full redaction enabled. If Gitleaks is not
installed, the wrapper fails closed with install guidance instead of silently
skipping the scan.

The GitHub Actions `Secret Scan` workflow installs the pinned Gitleaks release,
verifies the release archive checksum, and runs the same wrapper against full
Git history.

## Rotation Gate

If a Firebase Admin service-account key was ever committed, placed under the
repository, shared outside the owner machine, or cannot be proven to have stayed
local-only, the owner must rotate/revoke that key in Firebase or Google Cloud
before using it for automation. Agents may record this gate and the owner's
decision, but must not delete, revoke, rotate, display, or validate Firebase
credentials.
