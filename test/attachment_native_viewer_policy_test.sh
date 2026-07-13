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

grep -F 'path="../app_flutter/attachments/artworks/"' "$android_paths"
grep -F 'val applicationDocumentsDirectory = getDir("flutter", Context.MODE_PRIVATE)' "$android_activity"
grep -F 'AttachmentViewerPolicy.isSupportingAttachmentPayload(' "$android_activity"
grep -F 'AttachmentViewerPolicy.launchSupportingAttachment(' "$android_activity"
grep -F 'error is ActivityNotFoundException' "$android_activity"
grep -F 'launch = { startActivity(openIntent) }' "$android_activity"
grep -F 'addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)' "$android_activity"
grep -F 'class ArchivaleFileProvider : FileProvider()' "$android_provider"
grep -F 'android:name=".ArchivaleFileProvider"' "$android_manifest"
grep -F 'File(applicationDocumentsDirectory, "attachments/artworks").canonicalFile' "$android_policy"
grep -F 'val candidate = sourceFile.canonicalFile' "$android_policy"
grep -F 'candidate.path.startsWith(attachmentRoot.path + File.separator)' "$android_policy"
if grep -F 'File(filesDir, "attachments/artworks")' "$android_activity"; then
  echo "Android viewer must use the path_provider application documents root." >&2
  exit 1
fi
if grep -F 'resolveActivity(' "$android_activity"; then
  echo "Android attachment viewing must launch and catch ActivityNotFoundException." >&2
  exit 1
fi
if grep -F 'android:name="androidx.core.content.FileProvider"' "$android_manifest"; then
  echo "Android must register the app-owned FileProvider subclass." >&2
  exit 1
fi
grep -F 'bash test/attachment_native_viewer_policy_test.sh' "$release_workflow"
grep -F ':app:testDebugUnitTest' "$release_workflow"
grep -F -- '--tests app.archivale.AttachmentViewerPolicyTest' "$release_workflow"
if grep -F '<root-path' "$android_paths"; then
  echo "Android FileProvider must not expose a broad filesystem root." >&2
  exit 1
fi
if grep -F -e 'READ_EXTERNAL_STORAGE' -e 'WRITE_EXTERNAL_STORAGE' -e 'MANAGE_EXTERNAL_STORAGE' "$android_manifest"; then
  echo "Supporting attachment viewing must not request broad storage permissions." >&2
  exit 1
fi
grep -F 'url.resolvingSymlinksInPath().standardizedFileURL' "$ios_delegate"
grep -F 'appendingPathComponent("attachments/artworks", isDirectory: true)' "$ios_delegate"
grep -F 'url.path.hasPrefix(rootPath)' "$ios_delegate"
