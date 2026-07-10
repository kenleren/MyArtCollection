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

/// The retention state of an attachment record. This is separate from the
/// artwork lifecycle: supporting files can become unavailable or be replaced
/// while the artwork record remains active.
enum AttachmentLifecycleStatus {
  active('active'),
  unavailable('unavailable'),
  superseded('superseded'),
  removed('removed');

  const AttachmentLifecycleStatus(this.storageValue);

  final String storageValue;

  static AttachmentLifecycleStatus fromStorage(String? value) {
    return AttachmentLifecycleStatus.values.firstWhere(
      (status) => status.storageValue == value,
      orElse: () => AttachmentLifecycleStatus.active,
    );
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
    this.lifecycleStatus = AttachmentLifecycleStatus.active,
    this.lifecycleUpdatedAt,
    this.supersededByAttachmentId,
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
  final AttachmentLifecycleStatus lifecycleStatus;
  final DateTime? lifecycleUpdatedAt;
  final String? supersededByAttachmentId;
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

  bool get isVisibleInActiveUi =>
      lifecycleStatus == AttachmentLifecycleStatus.active ||
      lifecycleStatus == AttachmentLifecycleStatus.unavailable;

  AttachmentRecord copyWith({
    AttachmentLifecycleStatus? lifecycleStatus,
    DateTime? lifecycleUpdatedAt,
    String? supersededByAttachmentId,
  }) {
    return AttachmentRecord(
      id: id,
      artworkId: artworkId,
      type: type,
      role: role,
      fileName: fileName,
      mimeType: mimeType,
      fileSizeBytes: fileSizeBytes,
      importedAt: importedAt,
      capturedAt: capturedAt,
      derivedFromAttachmentId: derivedFromAttachmentId,
      transformSummary: transformSummary,
      source: source,
      relativePath: relativePath,
      checksum: checksum,
      lifecycleStatus: lifecycleStatus ?? this.lifecycleStatus,
      lifecycleUpdatedAt: lifecycleUpdatedAt ?? this.lifecycleUpdatedAt,
      supersededByAttachmentId:
          supersededByAttachmentId ?? this.supersededByAttachmentId,
      extractionSummary: extractionSummary,
      notes: notes,
    );
  }
}
