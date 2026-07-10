#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
android_activity="$repo_root/android/app/src/main/kotlin/app/archivale/MainActivity.kt"
android_paths="$repo_root/android/app/src/main/res/xml/filepaths.xml"
ios_delegate="$repo_root/ios/Runner/AppDelegate.swift"

rg -F '<files-path name="supporting_attachment_payloads" path="attachments/artworks/" />' "$android_paths"
rg -F 'File(filesDir, "attachments/artworks").canonicalFile' "$android_activity"
rg -F 'val candidate = sourceFile.canonicalFile' "$android_activity"
rg -F 'candidate.path.startsWith(attachmentRoot.path + File.separator)' "$android_activity"
rg -F 'url.resolvingSymlinksInPath().standardizedFileURL' "$ios_delegate"
rg -F 'appendingPathComponent("attachments/artworks", isDirectory: true)' "$ios_delegate"
rg -F 'url.path.hasPrefix(rootPath)' "$ios_delegate"
