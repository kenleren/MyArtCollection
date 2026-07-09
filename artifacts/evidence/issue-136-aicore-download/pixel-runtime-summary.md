# Issue 136 Pixel runtime summary

Date: 2026-07-06
Worktree: /Users/kenleren/Private/Ken/MyArtCollection-issue136-aicore-download
Branch: codex/issue-136-aicore-download
Build: build/app/outputs/flutter-apk/app-debug.apk
Flag: MY_ART_ON_DEVICE_AI_ENABLED=true

## Device facts
- Device: Pixel 10 Pro XL
- Android: 16
- API level: 36
- AICore package: com.google.android.aicore
  - versionCode: 456989
  - versionName: 0.release.prod_aicore_20260528.01_RC08.934495584
- Private Compute Services package: com.google.android.as
  - versionCode: 14952894
  - versionName: B.26.playstore.pixel10.940155965
- Network context: Wi-Fi connected state observed from `dumpsys wifi`; SSID intentionally not recorded.

## What was verified on-device
- Installed the debug APK built from this branch with `MY_ART_ON_DEVICE_AI_ENABLED=true`.
- Launched the app on the attached Pixel.
- Reached the real collection screen without clearing existing app data.
- Navigated on-device through:
  1. Collection
  2. Add artwork
  3. Import photo
  4. Android system photo picker
- Preserved only sanitized artifacts. Screens or dumps that exposed existing collection content or personal picker media were deleted.

## External blocker
- The Pixel dropped off ADB after install and picker navigation, before a local image could be selected and before the app could surface the AICore readiness/download state on the import result screen.
- Because of that disconnect, the following acceptance evidence could not be completed in this run:
  - app-triggered `DOWNLOADABLE` -> `DOWNLOADING` -> `AVAILABLE` runtime proof on the physical Pixel
  - manual retry after app-triggered download if needed
  - device DB proof for `ai_draft_jobs` and `research_jobs=0`
  - final on-device generation result or final explicit AICore/model readiness blocker from the app screen itself

## Captured artifacts
- `artifacts/visual/issue-136-aicore-download/03-add-artwork.png`
- `artifacts/visual/issue-136-aicore-download/03-add-artwork.xml`
- `artifacts/visual/issue-136-aicore-download/04-import-photo.png`
- `artifacts/visual/issue-136-aicore-download/04-import-photo.xml`

## Privacy boundary notes
- No provider/OpenAI/backend/Firebase/billing/deploy mutation was performed.
- No app secrets or local credentials were read.
- No artwork image was sent online by this work.
- Existing device photos were not intentionally selected for draft generation.
