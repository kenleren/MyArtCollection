/// Read-only inspection is not restore, authentication, or proof of authorship.
library;

enum ArchiveInspectionFailure {
  invalidArchive,
  unsupportedVersion,
  unsupportedResourceLimit,
  unsupportedZipFeature,
  sourceChanged,
  cancelled,
  ioFailure,
}

class ArchiveInspectionException implements Exception {
  const ArchiveInspectionException(this.failure);
  final ArchiveInspectionFailure failure;
  @override
  String toString() => 'Archive inspection: ${failure.name}.';
}

class ArchiveInspectionCancellation {
  bool _cancelled = false;
  void cancel() => _cancelled = true;
  void check() {
    if (_cancelled) {
      throw const ArchiveInspectionException(
        ArchiveInspectionFailure.cancelled,
      );
    }
  }
}

/// Fixed conservative inspection limits, not advertised backup capacity.
abstract final class ArchiveInspectionLimits {
  static const inputBytes = 128 * 1024 * 1024;
  static const expandedBytes = 512 * 1024 * 1024;
  static const payloadBytes = 64 * 1024 * 1024;
  static const manifestBytes = 1024 * 1024;
  static const structuredEntryBytes = 8 * 1024 * 1024;
  static const structuredTotalBytes = 16 * 1024 * 1024;
  static const entries = 2048;
  static const pathBytes = 256;
  static const pathDepth = 4;
  static const jsonDepth = 16;
  static const stringBytes = 64 * 1024;
  static const bufferBytes = 64 * 1024;
  static const jsonValues = 300000;
  static const deflateBlocks = 65536;
  static const artworkFields = 65536;
  static const arrayRows = <String, int>{
    'files': entries,
    'artworks': 4096,
    'attachments': 2048,
    'references': 16384,
    'groups': 1024,
    'memberships': 32768,
    'preferences': 4096,
    'fields': artworkFields,
  };
}

enum ArchiveFieldCoverage { present, presentNull, notRepresentedByVersion }

class InspectedArchiveField {
  const InspectedArchiveField.missing()
    : coverage = ArchiveFieldCoverage.notRepresentedByVersion,
      value = null;
  InspectedArchiveField.present(Object? value)
    : coverage = value == null
          ? ArchiveFieldCoverage.presentNull
          : ArchiveFieldCoverage.present,
      value = _freeze(value);
  final ArchiveFieldCoverage coverage;
  final Object? value;
}

/// Values use current logical database field names, with missingness retained.
class InspectedArchiveRow {
  InspectedArchiveRow(
    this.table,
    this.identity,
    Map<String, Object?> represented,
  ) : fields = Map.unmodifiable({
        for (final column in archiveV2SchemaCoverage[table]!.keys)
          column: represented.containsKey(column)
              ? InspectedArchiveField.present(represented[column])
              : const InspectedArchiveField.missing(),
      });
  final String table;
  final String identity;
  final Map<String, InspectedArchiveField> fields;
}

enum ArchivePayloadCoverage { included, excludedByLifecycle, unavailable }

class InspectedArchiveAttachment {
  const InspectedArchiveAttachment({
    required this.row,
    required this.payloadCoverage,
    required this.archiveStatus,
    required this.payloadPath,
  });
  final InspectedArchiveRow row;
  final ArchivePayloadCoverage payloadCoverage;
  final String archiveStatus;

  /// An archive entry name only; never a reusable trusted filesystem path.
  final String? payloadPath;
}

enum ArchiveRelationshipCoverage { verified, unprovableFromVersion }

class InspectedArchiveRelationship {
  const InspectedArchiveRelationship(this.kind, this.subject, this.coverage);
  final String kind;
  final String subject;
  final ArchiveRelationshipCoverage coverage;
}

class ArchiveInspection {
  ArchiveInspection({
    required this.sourceSha256,
    required this.sourceBytes,
    required this.createdAt,
    required List<InspectedArchiveRow> rows,
    required List<InspectedArchiveAttachment> attachments,
    required List<InspectedArchiveRelationship> relationships,
  }) : rows = List.unmodifiable(rows),
       attachments = List.unmodifiable(attachments),
       relationships = List.unmodifiable(relationships);

  final String sourceSha256;
  final int sourceBytes;
  final DateTime createdAt;
  final List<InspectedArchiveRow> rows;
  final List<InspectedArchiveAttachment> attachments;
  final List<InspectedArchiveRelationship> relationships;
  // V2 does not represent derivatives or any of these persisted history tables.
  final Set<String> unrepresentedTables = const {
    'ai_draft_jobs',
    'research_jobs',
    'research_source_hits',
    'candidate_attributions',
    'comparable_value_signals',
  };
  bool get derivativeRowCountKnown => false;
  bool get supportsCompleteRecovery => false;
}

Object? _freeze(Object? value) => switch (value) {
  Map<String, Object?> map => Map<String, Object?>.unmodifiable(
    map.map((key, value) => MapEntry(key, _freeze(value))),
  ),
  List<Object?> list => List<Object?>.unmodifiable(list.map(_freeze)),
  _ => value,
};

/// Explicit schema-10 column coverage. `conditional` means excluded attachment
/// rows omit it; `relocated` excludes device paths. History is not an empty table.
/// A schema introspection test must fail if a durable column has no policy.
const archiveV2SchemaCoverage = <String, Map<String, String>>{
  'artworks': {
    'artwork_id': 'present',
    'record_state': 'present',
    'lifecycle_status': 'present',
    'primary_image_attachment_id': 'present',
    'created_at': 'present',
    'updated_at': 'present',
  },
  'artwork_fields': {
    'artwork_id': 'parent',
    'field_key': 'present',
    'value': 'present',
    'money_amount': 'present',
    'money_currency_code': 'present',
    'source_state': 'renamed',
    'source_note': 'present',
    'last_confirmed_at': 'present',
  },
  'attachments': {
    'attachment_id': 'present',
    'artwork_id': 'present',
    'attachment_type': 'present',
    'attachment_role': 'present',
    'file_name': 'conditional',
    'mime_type': 'conditional',
    'file_size_bytes': 'conditional',
    'imported_at': 'conditional',
    'captured_at': 'missing',
    'source_state': 'missing',
    'relative_path': 'relocated',
    'checksum': 'conditional',
    'lifecycle_status': 'present',
    'lifecycle_updated_at': 'missing',
    'superseded_by_attachment_id': 'missing',
    'derived_from_attachment_id': 'missing',
    'transform_summary': 'missing',
    'extraction_summary': 'missing',
    'notes': 'missing',
  },
  'external_references': {
    'reference_id': 'present',
    'artwork_id': 'present',
    'reference_type': 'present',
    'label': 'present',
    'url': 'present',
    'origin': 'present',
    'review_state': 'present',
    'last_confirmed_at': 'present',
    'created_at': 'present',
    'updated_at': 'present',
    'sort_order': 'present',
  },
  'artwork_groups': {
    'group_id': 'present',
    'name': 'present',
    'normalized_name': 'present',
    'sort_order': 'present',
    'created_at': 'present',
    'updated_at': 'present',
  },
  'artwork_group_memberships': {
    'artwork_id': 'present',
    'group_id': 'present',
    'created_at': 'present',
  },
  'artwork_preferences': {
    'artwork_id': 'present',
    'is_favorite': 'present',
    'updated_at': 'present',
  },
  'ai_draft_jobs': {
    'draft_job_id': 'missing',
    'artwork_id': 'missing',
    'primary_image_attachment_id': 'missing',
    'status': 'missing',
    'created_at': 'missing',
    'updated_at': 'missing',
    'completed_at': 'missing',
    'device_model': 'missing',
    'prompt_version': 'missing',
    'visual_summary': 'missing',
    'signature_notes': 'missing',
    'subject_matter': 'missing',
    'medium_hint': 'missing',
    'style_period_hint': 'missing',
    'condition_notes': 'missing',
    'search_terms_json': 'missing',
    'error_message': 'missing',
  },
  'research_jobs': {
    'research_job_id': 'missing',
    'artwork_id': 'missing',
    'status': 'missing',
    'created_at': 'missing',
    'updated_at': 'missing',
    'completed_at': 'missing',
    'consent_summary': 'missing',
    'query_summary': 'missing',
    'provider': 'missing',
    'error_message': 'missing',
  },
  'research_source_hits': {
    'source_hit_id': 'missing',
    'research_job_id': 'missing',
    'source_name': 'missing',
    'source_type': 'missing',
    'confidence': 'missing',
    'source_url': 'missing',
    'object_id': 'missing',
    'title': 'missing',
    'artist': 'missing',
    'date_text': 'missing',
    'medium': 'missing',
    'dimensions': 'missing',
    'image_url': 'missing',
    'match_reason': 'missing',
    'raw_snippet': 'missing',
  },
  'candidate_attributions': {
    'candidate_id': 'missing',
    'research_job_id': 'missing',
    'source_hit_id': 'missing',
    'title': 'missing',
    'artist': 'missing',
    'year': 'missing',
    'medium': 'missing',
    'confidence': 'missing',
    'match_reason': 'missing',
    'field_sources_json': 'missing',
  },
  'comparable_value_signals': {
    'signal_id': 'missing',
    'research_job_id': 'missing',
    'source_hit_id': 'missing',
    'kind': 'missing',
    'label': 'missing',
    'source_name': 'missing',
    'source_url': 'missing',
    'amount_low': 'missing',
    'amount_high': 'missing',
    'currency': 'missing',
    'signal_date': 'missing',
    'caveat': 'missing',
  },
};
