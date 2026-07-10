import 'package:file_selector/file_selector.dart';

abstract class SupportingDocumentPicker {
  Future<XFile?> pickDocument();
}

class SystemSupportingDocumentPicker implements SupportingDocumentPicker {
  const SystemSupportingDocumentPicker();

  static const _documentTypeGroup = XTypeGroup(
    label: 'Supporting records',
    extensions: ['pdf', 'jpg', 'jpeg', 'png', 'heic', 'heif'],
    mimeTypes: [
      'application/pdf',
      'image/jpeg',
      'image/png',
      'image/heic',
      'image/heif',
    ],
  );

  @override
  Future<XFile?> pickDocument() {
    return openFile(acceptedTypeGroups: const [_documentTypeGroup]);
  }
}
