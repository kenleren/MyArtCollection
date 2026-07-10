import 'package:file_selector/file_selector.dart';

abstract class SupportingDocumentPicker {
  Future<XFile?> pickDocument();
}

class SupportingDocumentPickerException implements Exception {
  const SupportingDocumentPickerException();
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
    uniformTypeIdentifiers: [
      'com.adobe.pdf',
      'public.jpeg',
      'public.png',
      'public.heic',
      'public.heif',
    ],
  );

  @override
  Future<XFile?> pickDocument() async {
    try {
      return await openFile(acceptedTypeGroups: const [_documentTypeGroup]);
    } catch (_) {
      throw const SupportingDocumentPickerException();
    }
  }
}
