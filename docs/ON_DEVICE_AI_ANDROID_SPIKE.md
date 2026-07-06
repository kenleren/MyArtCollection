# Android On-Device AI Provider Spike

Issue: #123

Date checked: 2026-07-06

## Decision

The Pixel-first native spike uses ML Kit GenAI Prompt API through Android
AICore, behind `MY_ART_ON_DEVICE_AI_ENABLED`.

This branch keeps the provider disabled by default. When the Dart define is not
present, the Flutter provider returns `disabled` before invoking the native
method channel. When the define is present, Android checks ML Kit feature
status and only runs inference when the Prompt API reports `AVAILABLE`.

`DOWNLOADABLE` and `DOWNLOADING` are surfaced as not-ready states. The branch
does not start a model download or run inference from those states.

## Primary Sources

- Android Gemini Nano overview:
  https://developer.android.com/ai/gemini-nano
- ML Kit GenAI overview:
  https://developers.google.com/ml-kit/genai
- ML Kit Prompt API:
  https://developers.google.com/ml-kit/genai/prompt/android
- Prompt API get started:
  https://developers.google.com/ml-kit/genai/prompt/android/get-started
- Prompt API Kotlin reference:
  https://developers.google.com/android/reference/kotlin/com/google/mlkit/genai/prompt/package-summary
- ML Kit Image Description API:
  https://developers.google.com/ml-kit/genai/image-description/android
- LiteRT-LM overview:
  https://developers.google.com/edge/litert-lm/overview
- MediaPipe LLM Inference Android guide:
  https://developers.google.com/edge/mediapipe/solutions/genai/llm_inference/android

## Current API Constraints

- ML Kit GenAI APIs are built on AICore and process input, inference, and
  output locally.
- Prompt API is beta and can change without SLA or deprecation guarantees.
- Prompt API accepts text-only or image-plus-text prompts, which fits the
  artwork draft use case better than the feature-specific Image Description API.
- Prompt API requires Android API level 26 or newer.
- Runtime feature status is authoritative. Supported device lists are useful
  for planning, but `checkStatus()` or feature-specific status checks must drive
  the app UI.
- Current Prompt API device support is Pixel-first but not Pixel-only. The
  Pixel support listed in current docs starts with Pixel 9 for nano-v2 and
  Pixel 10 for nano-v3.
- Common setup failures include AICore not initialized, AICore missing or reset,
  feature configuration not yet downloaded, network failure during model/config
  download, and unlocked bootloaders.
- AICore enforces per-app inference and battery quotas.
- GenAI inference is allowed only while the app is the top foreground app.

## Implemented Spike Behavior

- Android dependency:
  `com.google.mlkit:genai-prompt:1.0.0-beta2`.
- Flutter define:
  `MY_ART_ON_DEVICE_AI_ENABLED=true`.
- App minSdk remains unchanged. The ML Kit Prompt API manifest declares API
  level 26, so the Android manifest explicitly overrides the Prompt API and
  GenAI common library declarations while native code returns `unavailable`
  before creating the ML Kit client on API level 25 or older.
- Native status mapping:
  - `FeatureStatus.AVAILABLE` -> `available`
  - `FeatureStatus.DOWNLOADABLE` -> `downloadable`
  - `FeatureStatus.DOWNLOADING` -> `downloading`
  - other status or API/setup failure -> `unavailable`
  - define missing -> `disabled`
- Native inference:
  - decodes the existing app-private image path,
  - sends the bitmap plus a cautious artwork-draft prompt to the local Prompt
    API,
  - expects compact JSON,
  - maps optional draft fields into the existing method-channel result shape.

No cloud endpoint, provider API key, Firebase AI Logic, broker bypass, backend
provider call, billing change, or Remote Config rollout was added.

## Runtime Evidence

Physical Pixel evidence was not captured in this environment because no Android
Pixel device or emulator with AICore/Prompt API support was attached to the
workspace.

This is not confidence-critical for the privacy boundary because the branch
defaults disabled, preserves local-only input, never calls cloud/provider hosts,
and only runs native inference when ML Kit reports `AVAILABLE`. It is
confidence-critical before claiming production-ready model quality or supported
Pixel UX.

Required Pixel check before rollout:

1. Install a build with `--dart-define=MY_ART_ON_DEVICE_AI_ENABLED=true` on a
   supported Pixel with a locked bootloader and initialized AICore.
2. Capture `checkAvailability` output for `available`, `downloadable`, or
   `downloading`.
3. If `available`, create a draft from a local photo with network disabled
   after model readiness and verify no online research job starts.
4. Record model/device details, elapsed time, generated fields, and any AICore
   error code.
