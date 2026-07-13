#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
android_activity="$repo_root/android/app/src/main/kotlin/app/archivale/MainActivity.kt"
android_paths="$repo_root/android/app/src/main/res/xml/filepaths.xml"
android_manifest="$repo_root/android/app/src/main/AndroidManifest.xml"
ios_delegate="$repo_root/ios/Runner/AppDelegate.swift"

android_policy="$repo_root/android/app/src/main/kotlin/app/archivale/AttachmentViewerPolicy.kt"

rg -F 'path="../app_flutter/attachments/artworks/"' "$android_paths"
rg -F 'val applicationDocumentsDirectory = getDir("flutter", Context.MODE_PRIVATE)' "$android_activity"
rg -F 'AttachmentViewerPolicy.isSupportingAttachmentPayload(' "$android_activity"
rg -F 'File(applicationDocumentsDirectory, "attachments/artworks").canonicalFile' "$android_policy"
rg -F 'val candidate = sourceFile.canonicalFile' "$android_policy"
rg -F 'candidate.path.startsWith(attachmentRoot.path + File.separator)' "$android_policy"
if rg -F 'File(filesDir, "attachments/artworks")' "$android_activity"; then
  echo "Android viewer must use the path_provider application documents root." >&2
  exit 1
fi
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
