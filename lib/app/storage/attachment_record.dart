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

enum AttachmentRole {
  primaryArtworkPhoto('primary_artwork_photo'),
  supportingPhoto('supporting_photo'),
  supportingDocument('supporting_document');

  const AttachmentRole(this.storageValue);

  final String storageValue;

  static AttachmentRole fromStorage(String? value, AttachmentType type) {
    if (value == null) {
      return defaultFor(type);
    }

    return AttachmentRole.values.firstWhere(
      (role) => role.storageValue == value,
      orElse: () => defaultFor(type),
    );
  }

  static AttachmentRole defaultFor(AttachmentType type) {
    return switch (type) {
      AttachmentType.photo => AttachmentRole.primaryArtworkPhoto,
      AttachmentType.receipt ||
      AttachmentType.certificate ||
      AttachmentType.appraisal ||
      AttachmentType.auctionRecord ||
      AttachmentType.provenanceNote ||
      AttachmentType.otherSupportingDocument =>
        AttachmentRole.supportingDocument,
    };
  }
}

class AttachmentRecord {
  AttachmentRecord({
    required this.id,
    required this.artworkId,
    required this.type,
    AttachmentRole? role,
    required this.fileName,
    required this.mimeType,
    required this.fileSizeBytes,
    required this.importedAt,
    required this.source,
    required this.relativePath,
    required this.checksum,
    this.capturedAt,
    this.derivedFromAttachmentId,
    this.transformSummary,
    this.extractionSummary,
    this.notes,
  }) : role = role ?? AttachmentRole.defaultFor(type);

  final String id;
  final String artworkId;
  final AttachmentType type;
  final AttachmentRole role;
  final String fileName;
  final String mimeType;
  final int fileSizeBytes;
  final DateTime importedAt;
  final DateTime? capturedAt;
  final String? derivedFromAttachmentId;
  final String? transformSummary;
  final ArtworkFieldSource source;
  final String relativePath;
  final String checksum;
  final String? extractionSummary;
  final String? notes;

  bool get isPrimaryImageCandidate =>
      type == AttachmentType.photo &&
      role == AttachmentRole.primaryArtworkPhoto;

  bool get isSupportingPhoto =>
      type == AttachmentType.photo && role == AttachmentRole.supportingPhoto;

  bool get isSupportingDocument => role == AttachmentRole.supportingDocument;

  bool get isDerivative => derivedFromAttachmentId != null;

  bool get isOriginalCapture => derivedFromAttachmentId == null;
}
