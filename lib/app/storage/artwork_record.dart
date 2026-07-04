enum ArtworkRecordState {
  draft('Draft'),
  needsReview('Needs review'),
  verifiedByYou('Verified by you'),
  missingDocuments('Missing documents');

  const ArtworkRecordState(this.label);

  final String label;

  static ArtworkRecordState fromStorage(String value) {
    return ArtworkRecordState.values.firstWhere(
      (state) => state.name == value,
      orElse: () => ArtworkRecordState.draft,
    );
  }
}

enum ArtworkLifecycleStatus {
  active('active', 'Active'),
  sold('sold', 'Sold'),
  lost('lost', 'Lost'),
  stolen('stolen', 'Stolen'),
  removed('removed', 'Removed');

  const ArtworkLifecycleStatus(this.storageValue, this.label);

  final String storageValue;
  final String label;

  static ArtworkLifecycleStatus fromStorage(String? value) {
    return ArtworkLifecycleStatus.values.firstWhere(
      (status) => status.storageValue == value,
      orElse: () => ArtworkLifecycleStatus.active,
    );
  }
}

enum ArtworkFieldSource {
  aiSuggested('AI-suggested'),
  userConfirmed('user-confirmed'),
  documentExtracted('document-extracted'),
  unknown('unknown');

  const ArtworkFieldSource(this.label);

  final String label;

  static ArtworkFieldSource fromStorage(String value) {
    return ArtworkFieldSource.values.firstWhere(
      (source) => source.label == value,
      orElse: () => ArtworkFieldSource.unknown,
    );
  }
}

class ArtworkFieldValue {
  const ArtworkFieldValue({
    required this.value,
    required this.source,
    required this.note,
    this.lastConfirmedAt,
  });

  final String value;
  final ArtworkFieldSource source;
  final String note;
  final DateTime? lastConfirmedAt;

  ArtworkFieldValue copyWith({
    String? value,
    ArtworkFieldSource? source,
    String? note,
    DateTime? lastConfirmedAt,
  }) {
    return ArtworkFieldValue(
      value: value ?? this.value,
      source: source ?? this.source,
      note: note ?? this.note,
      lastConfirmedAt: lastConfirmedAt ?? this.lastConfirmedAt,
    );
  }
}

class ArtworkRecord {
  const ArtworkRecord({
    required this.id,
    required this.recordState,
    required this.createdAt,
    required this.updatedAt,
    required this.fields,
    this.lifecycleStatus = ArtworkLifecycleStatus.active,
    this.primaryImageAttachmentId,
  });

  final String id;
  final ArtworkRecordState recordState;
  final ArtworkLifecycleStatus lifecycleStatus;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? primaryImageAttachmentId;
  final Map<String, ArtworkFieldValue> fields;

  ArtworkFieldValue? field(String key) => fields[key];

  ArtworkRecord copyWith({
    ArtworkRecordState? recordState,
    ArtworkLifecycleStatus? lifecycleStatus,
    DateTime? updatedAt,
    String? primaryImageAttachmentId,
    Map<String, ArtworkFieldValue>? fields,
  }) {
    return ArtworkRecord(
      id: id,
      recordState: recordState ?? this.recordState,
      lifecycleStatus: lifecycleStatus ?? this.lifecycleStatus,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      primaryImageAttachmentId:
          primaryImageAttachmentId ?? this.primaryImageAttachmentId,
      fields: fields ?? this.fields,
    );
  }
}

abstract final class ArtworkFieldKeys {
  static const title = 'title';
  static const artist = 'artist';
  static const year = 'year';
  static const medium = 'medium';
  static const dimensions = 'dimensions';
  static const currentLocation = 'current_location';
  static const insuranceValue = 'insurance_value';
  static const conditionNotes = 'condition_notes';
}
