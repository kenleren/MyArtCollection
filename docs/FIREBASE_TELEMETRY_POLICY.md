# Firebase Telemetry Privacy Policy

This policy defines what MyArtCollection may send to Firebase telemetry tools
before any Firebase telemetry SDK is enabled. It preserves the local-first
storage model and prevents artwork metadata from leaking into operational logs.

## Status

- Firebase App Distribution is allowed for Android beta delivery.
- Crashlytics is allowed for Android internal beta crash triage only when an
  explicit internal-beta build flag enables it.
- Remote Config may be added for non-sensitive beta kill switches after this
  policy is accepted and implemented.
- Analytics and Performance Monitoring remain deferred until a separate issue
  enables them after review and redteam acceptance.

## Absolute Ban

Firebase-bound data must never include the following, whether it is produced by
an SDK, release note, console field, issue evidence, screenshot, logcat excerpt,
tester email, or operator-written summary:

- artwork titles
- artist names
- current locations or room names
- acquisition, purchase, sale, insurance, or estimate amounts
- seller, buyer, gallery, auction house, estate, or contact names
- document filenames
- image paths, attachment paths, export paths, or checksums
- user notes, condition notes, provenance notes, or free-text field values
- collection contents, collection size by title/artist, or record lists
- AI prompts, AI responses, source snippets, citations, or research queries
- service-account paths, tokens, API keys, or tester email lists

When in doubt, do not send it.

## Default-Off Requirement

Firebase telemetry SDK collection must be disabled by default in platform
configuration and at runtime until the specific product has passed its review
gate.

Rules:

- Debug/local builds must not send Crashlytics, Analytics, or Performance data.
- Internal beta builds may enable only the Firebase products explicitly accepted
  for that beta.
- Analytics consent defaults to denied.
- Performance Monitoring collection defaults to disabled.
- Any Firebase SDK added to `pubspec.yaml`, Android config, or iOS config must
  include a test or static check proving disallowed products are still off.

## Allowed Crashlytics Data

Crashlytics may collect crash data needed to diagnose beta stability:

- app version, build number, platform, OS version, device model
- exception type, stack trace, thread state, and crash timestamp
- coarse app area using fixed enum values only, such as `startup`, `collection`,
  `intake`, `draft_review`, `documents`, `report_preview`, `settings`
- fixed feature flag states, such as `online_research_enabled=false`

Crashlytics must be integrated through a single app-owned facade. Direct calls
such as `recordError(error, stack)` are banned for storage, intake, AI,
research, export, path-handling, and other user-content code. The facade must:

- map errors to fixed enum categories,
- strip exception messages, reasons, diagnostics, and user-provided
  `informationCollector` output,
- avoid user identifiers,
- disable Analytics breadcrumbs,
- avoid raw route names and raw object identifiers,
- avoid logging URLs, paths, source citations, filenames, notes, prompts,
  responses, or field values.

Crashlytics custom keys must use a documented allowlist. Custom logs are
disallowed unless they use the same fixed enum vocabulary and contain no user
record data. Any custom key or log addition requires a test fixture proving a
synthetic title, path, token, source URL, and research query are not sent.

Crashlytics collection must be disabled by default for debug/local development
and must remain off in beta until tester/user disclosure is in place.

Current Android implementation:

- Runtime collection is disabled unless the app is a release-mode build and
  running on Android with both
  `--dart-define=MY_ART_COLLECTION_FIREBASE_ANDROID=true` and
  `--dart-define=MY_ART_COLLECTION_INTERNAL_BETA_CRASHLYTICS=true` present.
- Android manifest defaults set Crashlytics collection to `false`.
- Firebase initialization is skipped when collection is off, so local/debug
  builds do not require `google-services.json`.
- Crashlytics SDK calls are isolated to `lib/app/telemetry/crash_telemetry.dart`.
- The facade records only fixed sanitized error categories:
  `flutter_framework_error`, `platform_dispatcher_error`, and
  `dart_zone_error`.
- No Crashlytics custom keys or custom logs are currently allowed.
- Deliberate setup crashes require both internal beta Crashlytics enablement and
  `--dart-define=MY_ART_COLLECTION_CRASHLYTICS_TEST_CRASH=true`; this path is
  for one-off human verification only and is not reachable from normal app UI.

## Allowed Remote Config Data

Remote Config may fetch non-sensitive app behavior flags:

- disable online research entry points
- disable experimental beta flows
- show or hide beta-only UI affordances
- adjust local-only copy variants

Remote Config values are client-visible. They must not contain secrets,
credentials, private URLs, pricing rules, user-specific decisions, or anything
that bypasses consent, platform review, local-first storage rules, or app-store
privacy declarations.

The app must keep safe local defaults for every Remote Config key.

## Analytics Policy

Analytics is deferred. Before enabling Analytics, create and review an event
taxonomy that includes:

- allowed event names
- allowed parameter names and value classes
- consent and disclosure text
- retention expectations
- app-store privacy/data safety mapping

Analytics event names and parameters must not encode artwork metadata, user
free text, image/document information, location names, prices, or AI/research
payloads.

Analytics must be disabled by default in platform configuration and runtime
before any SDK is merged. Automatic collection must be accounted for explicitly.
Allowed screen names must be fixed enums, not route strings. Raw routes such as
`/artwork/<id>`, record IDs, attachment IDs, source URLs, and research URLs must
never be sent.

## Performance Monitoring Policy

Performance Monitoring is deferred. Before enabling it, verify that traces,
screen names, URLs, and network attributes cannot reveal artwork metadata,
document names, image paths, export paths, source citations, or user-entered
free text.

Performance Monitoring must be disabled by default in platform configuration
and runtime before any SDK is merged. Automatic screen rendering, lifecycle, and
HTTP/S network instrumentation must remain disabled unless an allowlist and
redaction design is reviewed. Network traces must not include AI broker paths,
research/source URLs, attachment paths, export paths, or record IDs.

## App Distribution Operational Data

App Distribution release notes, tester emails, console evidence, screenshots,
logcat excerpts, and issue comments are Firebase-bound operational data.

Rules:

- Release notes must use fixed-category wording such as `lifecycle controls`,
  `crash fix`, or `beta UI polish`.
- Release notes must not include artwork titles, filenames, paths, tester
  emails, collection contents, AI/research queries, source citations, or raw
  crash messages.
- Firebase release evidence must redact tester emails and credential paths.
- Logcat excerpts attached to issues must be scanned for banned metadata before
  commit or upload.
- Screenshots used as release evidence must not reveal private user artwork
  metadata unless they are generated fixtures.

## Consent And Disclosure

Before any wider beta with Crashlytics or future telemetry enabled, privacy copy
must disclose:

- which Firebase products are enabled
- that crash/diagnostic data may leave the device
- that artwork records, photos, documents, notes, and collection contents are
  not intentionally sent through telemetry
- how the user or tester can leave the beta or request removal where applicable

Analytics and Performance Monitoring require a separate consent/disclosure
review before implementation.

## App-Store Privacy Checklist

Before store or broad beta release, confirm:

- Firebase SDKs enabled in the build match this policy.
- Apple App Privacy and Google Play Data Safety declarations match actual SDK
  behavior.
- Crashlytics custom keys/logs are allowlisted and reviewed.
- Crashlytics uses only the app-owned sanitized facade.
- Analytics and Performance Monitoring remain disabled unless separately
  approved.
- Analytics and Performance automatic collection are disabled by default.
- No telemetry event, key, trace, log, or parameter includes banned metadata.
- App Distribution release notes and evidence contain only sanitized fixed
  categories.
- Firebase credentials, tester lists, and config secrets are outside Git.

## Review Gate

Any task that adds or changes Firebase telemetry must include:

- this policy in scope,
- static review for banned metadata,
- focused tests or code review for telemetry wrappers,
- default-off platform/runtime configuration checks,
- independent task review,
- redteam review when adding Analytics, Performance Monitoring, custom
  Crashlytics keys/logs, backend telemetry, or any user/content-derived signal.
