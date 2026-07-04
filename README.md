# MyArtCollection

MyArtCollection is a planned iPhone and Android app for serious hobby collectors who want a private, polished record of their art collection without building a spreadsheet or hiring a registrar.

The core promise:

> Take a photo of your artwork. AI drafts the record. You confirm the facts. Your collection stays privately organized, with storage and backup decisions documented separately.

The first product should not be an AI appraiser, authenticity engine, marketplace, or social catalog. The paid wedge is simpler and stronger: fast AI-assisted intake, document-backed records, and insurance-ready exports for collectors who already care enough to organize what they own.

## Current Decision

Build a local-first Flutter app with optional Google Drive backup, AI-assisted record drafting, and premium export/reporting.

## Flutter App Shell

The repository now includes a root Flutter scaffold for iOS and Android with a
basic route shell aligned to [Mobile Information Architecture](docs/MOBILE_IA.md):

- `Splash`
- `Onboarding`
- `Collection`
- `Incomplete`
- `Reports`
- `Settings`
- placeholder drill-ins for add, capture, import, and artwork detail flows

Placeholder copy follows [Copy and Trust Rules](docs/COPY_TRUST_SPEC.md): AI can
suggest, the user confirms, and the app does not claim authenticity or market
value.

## Commands

Install dependencies:

```sh
flutter pub get
```

Lint and tests:

```sh
flutter analyze
flutter test
```

Run the app:

```sh
flutter run
```

Platform build checks:

```sh
flutter build apk --debug
flutter build ios --simulator --debug --no-codesign
```

If no simulator or emulator is booted, use `flutter emulators` and your local
device tooling to start one before `flutter run`.

Android beta distribution is documented in
[Firebase App Distribution](docs/FIREBASE_APP_DISTRIBUTION.md). Firebase is the
tester delivery layer by default. Crashlytics can be enabled only for Android
internal beta crash triage with an explicit release build flag; local/debug
collection remains off. Credential handling and repository secret scanning are
documented in [Secret Hygiene](docs/SECRET_HYGIENE.md).

Primary audience:

- Hobby collectors with roughly 10 to 200 artworks
- Collection value roughly USD 5k to USD 250k
- People buying from artists, galleries, fairs, auctions, and online platforms
- Users who need better records for insurance, memory, provenance, estate planning, or household organization

Primary job:

- Create a credible, exportable, private record of each artwork in under two minutes.

## Documentation

- [North Star](docs/NORTH_STAR.md)
- [Product Plan](docs/PRODUCT_PLAN.md)
- [Prototype Storyboard](docs/PROTOTYPE_STORYBOARD.md)
- [Copy and Trust Rules](docs/COPY_TRUST_SPEC.md)
- [Go-To-Market Plan](docs/GTM_PLAN.md)
- [Marketing System Spec](docs/MARKETING_SYSTEM_SPEC.md)
- [Architecture Plan](docs/ARCHITECTURE.md)
- [Local Storage Spec](docs/LOCAL_STORAGE_SPEC.md)
- [Mobile Information Architecture](docs/MOBILE_IA.md)
- [Artwork Record Schema](docs/ARTWORK_RECORD_SCHEMA.md)
- [Secret Hygiene](docs/SECRET_HYGIENE.md)
- [Firebase Telemetry Privacy Policy](docs/FIREBASE_TELEMETRY_POLICY.md)
- [MVP Task Breakdown](docs/MVP_TASKS.md)
- [ADR 0001: Local-First Flutter With Google Drive Backup](docs/adr/0001-local-first-flutter-google-drive.md)

## Non-Goals

For the MVP, do not build:

- Authenticity determination
- Appraisal-grade valuation
- Investment advice
- Marketplace or resale
- Gallery CRM
- Museum collection workflows
- Broad household inventory
- Social sharing or public collection pages

## Key Product Rule

AI assists. The user confirms.

Every AI-populated field must be visibly reviewable. The app should use careful language such as "possible", "likely", "could not determine", and "please confirm". It must not confidently claim artist attribution, authenticity, or market value.
