#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
android_activity="$repo_root/android/app/src/main/kotlin/app/archivale/MainActivity.kt"
android_provider="$repo_root/android/app/src/main/kotlin/app/archivale/ArchivaleFileProvider.kt"
android_paths="$repo_root/android/app/src/main/res/xml/filepaths.xml"
android_manifest="$repo_root/android/app/src/main/AndroidManifest.xml"
ios_delegate="$repo_root/ios/Runner/AppDelegate.swift"
android_policy="$repo_root/android/app/src/main/kotlin/app/archivale/AttachmentViewerPolicy.kt"
release_workflow="$repo_root/.github/workflows/release-readiness.yml"

rg -F 'path="../app_flutter/attachments/artworks/"' "$android_paths"
rg -F 'val applicationDocumentsDirectory = getDir("flutter", Context.MODE_PRIVATE)' "$android_activity"
rg -F 'AttachmentViewerPolicy.isSupportingAttachmentPayload(' "$android_activity"
rg -F 'AttachmentViewerPolicy.launchSupportingAttachment(' "$android_activity"
rg -F 'error is ActivityNotFoundException' "$android_activity"
rg -F 'launch = { startActivity(openIntent) }' "$android_activity"
rg -F 'addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)' "$android_activity"
rg -F 'class ArchivaleFileProvider : FileProvider()' "$android_provider"
rg -F 'android:name=".ArchivaleFileProvider"' "$android_manifest"
rg -F 'File(applicationDocumentsDirectory, "attachments/artworks").canonicalFile' "$android_policy"
rg -F 'val candidate = sourceFile.canonicalFile' "$android_policy"
rg -F 'candidate.path.startsWith(attachmentRoot.path + File.separator)' "$android_policy"
if rg -F 'File(filesDir, "attachments/artworks")' "$android_activity"; then
  echo "Android viewer must use the path_provider application documents root." >&2
  exit 1
fi
if rg -F 'resolveActivity(' "$android_activity"; then
  echo "Android attachment viewing must launch and catch ActivityNotFoundException." >&2
  exit 1
fi
if rg -F 'android:name="androidx.core.content.FileProvider"' "$android_manifest"; then
  echo "Android must register the app-owned FileProvider subclass." >&2
  exit 1
fi
rg -F 'bash test/attachment_native_viewer_policy_test.sh' "$release_workflow"
rg -F ':app:testDebugUnitTest' "$release_workflow"
rg -F -- '--tests app.archivale.AttachmentViewerPolicyTest' "$release_workflow"
if rg -F '<root-path' "$android_paths"; then
  echo "Android FileProvider must not expose a broad filesystem root." >&2
  exit 1
fi
if rg -F -e 'READ_EXTERNAL_STORAGE' -e 'WRITE_EXTERNAL_STORAGE' -e 'MANAGE_EXTERNAL_STORAGE' "$android_manifest"; then
  echo "Supporting attachment viewing must not request broad storage permissions." >&2
  exit 1
fi
rg -F 'url.resolvingSymlinksInPath().standardizedFileURL' "$ios_delegate"
rg -F 'appendingPathComponent("attachments/artworks", isDirectory: true)' "$ios_delegate"
rg -F 'url.path.hasPrefix(rootPath)' "$ios_delegate"
