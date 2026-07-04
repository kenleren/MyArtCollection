# Firebase Telemetry Privacy Policy

This policy defines what MyArtCollection may send to Firebase telemetry tools
before any Firebase telemetry SDK is enabled. It preserves the local-first
storage model and prevents artwork metadata from leaking into operational logs.

## Status

- Firebase App Distribution is allowed for Android beta delivery.
- Crashlytics may be added for internal beta crash triage after this policy is
  accepted and implemented.
- Remote Config may be added for non-sensitive beta kill switches after this
  policy is accepted and implemented.
- Analytics and Performance Monitoring remain deferred until a separate issue
  enables them after review and redteam acceptance.

## Absolute Ban

Firebase telemetry must never include:

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

## Allowed Crashlytics Data

Crashlytics may collect crash data needed to diagnose beta stability:

- app version, build number, platform, OS version, device model
- exception type, stack trace, thread state, and crash timestamp
- coarse app area using fixed enum values only, such as `startup`, `collection`,
  `intake`, `draft_review`, `documents`, `report_preview`, `settings`
- fixed feature flag states, such as `online_research_enabled=false`

Crashlytics custom keys must use a documented allowlist. Custom logs are
disallowed unless they use the same fixed enum vocabulary and contain no user
record data.

Crashlytics collection must be disabled by default for debug/local development.

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

## Performance Monitoring Policy

Performance Monitoring is deferred. Before enabling it, verify that traces,
screen names, URLs, and network attributes cannot reveal artwork metadata,
document names, image paths, export paths, source citations, or user-entered
free text.

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
- Analytics and Performance Monitoring remain disabled unless separately
  approved.
- No telemetry event, key, trace, log, or parameter includes banned metadata.
- Firebase credentials, tester lists, and config secrets are outside Git.

## Review Gate

Any task that adds or changes Firebase telemetry must include:

- this policy in scope,
- static review for banned metadata,
- focused tests or code review for telemetry wrappers,
- independent task review,
- redteam review when adding Analytics, Performance Monitoring, custom
  Crashlytics keys/logs, backend telemetry, or any user/content-derived signal.
