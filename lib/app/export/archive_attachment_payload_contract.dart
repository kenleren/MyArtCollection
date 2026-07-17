const approvedArchivePayloadExtensionsByMimeType = <String, String>{
  'application/pdf': 'pdf',
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/heic': 'heic',
  'image/heif': 'heif',
};

final _attachmentIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$');
final _approvedPayloadPathPattern = RegExp(
  r'^attachments/[A-Za-z0-9][A-Za-z0-9_-]{0,127}/payload\.(pdf|jpg|png|heic|heif)$',
);

String approvedArchivePayloadPath({
  required String attachmentId,
  required String mimeType,
}) {
  final extension = approvedArchivePayloadExtensionsByMimeType[mimeType];
  if (!_attachmentIdPattern.hasMatch(attachmentId) || extension == null) {
    throw ArgumentError.value(
      attachmentId,
      'attachmentId',
      'Attachment identity or MIME type is not archive-safe.',
    );
  }
  return 'attachments/$attachmentId/payload.$extension';
}

bool isApprovedArchivePayloadPath(String path) =>
    _approvedPayloadPathPattern.hasMatch(path);
