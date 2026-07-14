#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
android_activity="$repo_root/android/app/src/main/kotlin/app/archivale/MainActivity.kt"
android_provider="$repo_root/android/app/src/main/kotlin/app/archivale/ArchivaleFileProvider.kt"
android_paths="$repo_root/android/app/src/main/res/xml/filepaths.xml"
android_manifest="$repo_root/android/app/src/main/AndroidManifest.xml"
ios_delegate="$repo_root/ios/Runner/AppDelegate.swift"
ios_export_policy="$repo_root/ios/Runner/ExportArtifactPolicy.swift"
android_policy="$repo_root/android/app/src/main/kotlin/app/archivale/AttachmentViewerPolicy.kt"
android_export_policy="$repo_root/android/app/src/main/kotlin/app/archivale/ExportSaveCopyPolicy.kt"
release_workflow="$repo_root/.github/workflows/release-readiness.yml"
native_access="$repo_root/android/app/src/main/kotlin/app/archivale/AttachmentCustodyNativeAccess.kt"
source_guard="$repo_root/test/attachment_native_viewer_policy_guard.py"

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
python3 "$source_guard" "$release_workflow" "$native_access" "$android_activity"
python3 "$source_guard" --self-test "$release_workflow" "$native_access" "$android_activity"
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
grep -F 'Intent(Intent.ACTION_CREATE_DOCUMENT)' "$android_activity"
grep -F 'putExtra(Intent.EXTRA_TITLE, source.metadata.fileName)' "$android_activity"
grep -F 'contentResolver.openOutputStream(requireNotNull(destination), "w")' "$android_activity"
grep -F 'ExportSaveCopyPolicy.openValidated(' "$android_activity"
grep -F 'AttachmentCustodyNative.openExportPair(' "$android_activity"
grep -F 'ParcelFileDescriptor.adoptFd(' "$android_activity"
grep -F 'pending.source.revalidateAndCopy(it)' "$android_activity"
grep -F 'ExportSaveCallbackPolicy.complete(' "$android_activity"
grep -F 'metadata_version' "$android_export_policy"
grep -F 'checksum_sha256' "$android_export_policy"
grep -F 'UIDocumentPickerViewController(' "$ios_delegate"
grep -F 'forExporting: [pickerCopy.url]' "$ios_delegate"
grep -F 'ExportArtifactPolicy.makePickerCopy(' "$ios_delegate"
grep -F 'pickerCopy.isReadyForPicker()' "$ios_delegate"
grep -F 'attachmentCustodyOpenExportPair(' "$ios_export_policy"
grep -F 'openOrCreateDirectoryAt(' "$ios_export_policy"
grep -F 'O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW' "$ios_export_policy"
grep -F 'generated_exports/' "$ios_export_policy"
if grep -F -e 'READ_EXTERNAL_STORAGE' -e 'WRITE_EXTERNAL_STORAGE' -e 'MANAGE_EXTERNAL_STORAGE' "$android_manifest"; then
  echo "Export save must not request broad storage permissions." >&2
  exit 1
fi
