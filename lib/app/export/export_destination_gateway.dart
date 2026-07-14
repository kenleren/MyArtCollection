import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

enum ExportDestinationResult { completed, dismissed, unavailable }

abstract interface class ExportDestinationGateway {
  Future<ExportDestinationResult> open(File file);

  Future<ExportDestinationResult> saveCopy(
    File file, {
    required String suggestedName,
    required String mimeType,
  });

  Future<ExportDestinationResult> share(
    File file, {
    required String displayName,
    required String mimeType,
  });
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
  Future<ExportDestinationResult> open(File file) async {
    final result = await OpenFilex.open(file.path);
    return result.type == ResultType.done
        ? ExportDestinationResult.completed
        : ExportDestinationResult.unavailable;
  }

  @override
  Future<ExportDestinationResult> saveCopy(
    File file, {
    required String suggestedName,
    required String mimeType,
  }) async {
    final useNative =
        useNativeMobileSaveCopy ?? (Platform.isAndroid || Platform.isIOS);
    if (useNative) {
      try {
        final outcome = await saveCopyChannel.invokeMethod<String>('saveCopy', {
          'sourcePath': file.path,
          'suggestedName': suggestedName,
          'mimeType': mimeType,
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
    final location = await getSaveLocation(suggestedName: suggestedName);
    if (location == null) return ExportDestinationResult.dismissed;
    await XFile(
      file.path,
      mimeType: mimeType,
      name: suggestedName,
    ).saveTo(location.path);
    return ExportDestinationResult.completed;
  }

  @override
  Future<ExportDestinationResult> share(
    File file, {
    required String displayName,
    required String mimeType,
  }) async {
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mimeType, name: displayName)],
        fileNameOverrides: [displayName],
      ),
    );
    return switch (result.status) {
      ShareResultStatus.dismissed => ExportDestinationResult.dismissed,
      ShareResultStatus.success => ExportDestinationResult.completed,
      ShareResultStatus.unavailable => ExportDestinationResult.unavailable,
    };
  }
}
