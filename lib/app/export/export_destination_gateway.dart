import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import 'export_artifact_store.dart';

enum ExportDestinationResult { completed, dismissed, unavailable }

abstract interface class ExportDestinationGateway {
  Future<ExportDestinationResult> open(ExportArtifact artifact);

  Future<ExportDestinationResult> saveCopy(ExportArtifact artifact);

  Future<ExportDestinationResult> share(ExportArtifact artifact);
}

class SystemExportDestinationGateway implements ExportDestinationGateway {
  const SystemExportDestinationGateway({
    this.saveCopyChannel = const MethodChannel(
      'app.archivale/export_destination',
    ),
    this.useNativeMobileSaveCopy,
  });

  final MethodChannel saveCopyChannel;
  final bool? useNativeMobileSaveCopy;

  @override
  Future<ExportDestinationResult> open(ExportArtifact artifact) async {
    final validated = await artifact.revalidate();
    if (validated == null) return ExportDestinationResult.unavailable;
    final result = await OpenFilex.open(validated.file.path);
    return result.type == ResultType.done
        ? ExportDestinationResult.completed
        : ExportDestinationResult.unavailable;
  }

  @override
  Future<ExportDestinationResult> saveCopy(ExportArtifact artifact) async {
    final validated = await artifact.revalidate();
    if (validated == null) return ExportDestinationResult.unavailable;
    final useNative =
        useNativeMobileSaveCopy ?? (Platform.isAndroid || Platform.isIOS);
    if (useNative) {
      try {
        final outcome = await saveCopyChannel.invokeMethod<String>('saveCopy', {
          'sourcePath': validated.file.path,
          'suggestedName': validated.displayName,
          'mimeType': validated.mimeType,
        });
        return switch (outcome) {
          'completed' => ExportDestinationResult.completed,
          'dismissed' => ExportDestinationResult.dismissed,
          _ => ExportDestinationResult.unavailable,
        };
      } on MissingPluginException {
        return ExportDestinationResult.unavailable;
      } on PlatformException {
        return ExportDestinationResult.unavailable;
      }
    }
    final location = await getSaveLocation(
      suggestedName: validated.displayName,
    );
    if (location == null) return ExportDestinationResult.dismissed;
    await XFile(
      validated.file.path,
      mimeType: validated.mimeType,
      name: validated.displayName,
    ).saveTo(location.path);
    return ExportDestinationResult.completed;
  }

  @override
  Future<ExportDestinationResult> share(ExportArtifact artifact) async {
    final validated = await artifact.revalidate();
    if (validated == null) return ExportDestinationResult.unavailable;
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            validated.file.path,
            mimeType: validated.mimeType,
            name: validated.displayName,
          ),
        ],
        fileNameOverrides: [validated.displayName],
      ),
    );
    return switch (result.status) {
      ShareResultStatus.dismissed => ExportDestinationResult.dismissed,
      ShareResultStatus.success => ExportDestinationResult.completed,
      ShareResultStatus.unavailable => ExportDestinationResult.unavailable,
    };
  }
}
