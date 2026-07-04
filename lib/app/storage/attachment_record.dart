import 'artwork_record.dart';

enum AttachmentType {
  photo('photo'),
  receipt('receipt'),
  certificate('certificate'),
  appraisal('appraisal'),
  auctionRecord('auction_record'),
  provenanceNote('provenance_note'),
  otherSupportingDocument('other_supporting_document');

  const AttachmentType(this.storageValue);

  final String storageValue;

  static AttachmentType fromStorage(String value) {
    return AttachmentType.values.firstWhere(
      (type) => type.storageValue == value,
      orElse: () => AttachmentType.otherSupportingDocument,
    );
  }
}

class AttachmentRecord {
  const AttachmentRecord({
    required this.id,
    required this.artworkId,
    required this.type,
    required this.fileName,
    required this.mimeType,
    required this.fileSizeBytes,
    required this.importedAt,
    required this.source,
    required this.relativePath,
    required this.checksum,
    this.capturedAt,
    this.extractionSummary,
    this.notes,
  });

  final String id;
  final String artworkId;
  final AttachmentType type;
  final String fileName;
  final String mimeType;
  final int fileSizeBytes;
  final DateTime importedAt;
  final DateTime? capturedAt;
  final ArtworkFieldSource source;
  final String relativePath;
  final String checksum;
  final String? extractionSummary;
  final String? notes;

  bool get isPrimaryImageCandidate => type == AttachmentType.photo;
}
