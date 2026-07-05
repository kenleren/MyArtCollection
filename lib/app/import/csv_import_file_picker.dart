import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

class CsvImportFileSelection {
  const CsvImportFileSelection({
    required this.displayName,
    required this.path,
    required this.bytes,
  });

  final String displayName;
  final String path;
  final Uint8List bytes;
}

abstract class CsvImportFilePicker {
  const CsvImportFilePicker();

  Future<CsvImportFileSelection?> pickCsvFile();
}

class SystemCsvImportFilePicker implements CsvImportFilePicker {
  const SystemCsvImportFilePicker();

  static const _csvTypeGroup = XTypeGroup(
    label: 'CSV',
    extensions: ['csv'],
    mimeTypes: ['text/csv', 'text/plain', 'application/vnd.ms-excel'],
  );

  @override
  Future<CsvImportFileSelection?> pickCsvFile() async {
    final file = await openFile(acceptedTypeGroups: [_csvTypeGroup]);
    if (file == null) {
      return null;
    }

    return CsvImportFileSelection(
      displayName: file.name,
      path: file.path,
      bytes: await file.readAsBytes(),
    );
  }
}
