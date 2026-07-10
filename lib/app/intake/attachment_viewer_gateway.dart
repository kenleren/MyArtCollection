import 'package:flutter/services.dart';

abstract class AttachmentViewerGateway {
  Future<void> open({required Uri scopedUri, required String mimeType});
}

class SystemAttachmentViewerGateway implements AttachmentViewerGateway {
  const SystemAttachmentViewerGateway();

  static const _channel = MethodChannel('app.archivale/attachment_viewer');

  @override
  Future<void> open({required Uri scopedUri, required String mimeType}) async {
    if (!scopedUri.isScheme('file')) {
      throw const AttachmentViewerException('The attachment is unavailable.');
    }
    final bool? opened;
    try {
      opened = await _channel.invokeMethod<bool>('openSupportingAttachment', {
        'uri': scopedUri.toString(),
        'mimeType': mimeType,
      });
    } on PlatformException {
      throw const AttachmentViewerException(
        'Could not open this supporting record.',
      );
    } on MissingPluginException {
      throw const AttachmentViewerException(
        'Could not open this supporting record.',
      );
    }
    if (opened != true) {
      throw AttachmentViewerException('Could not open this supporting record.');
    }
  }
}

class AttachmentViewerException implements Exception {
  const AttachmentViewerException(this.message);

  final String message;

  @override
  String toString() => message;
}
