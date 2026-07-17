// ignore_for_file: curly_braces_in_flow_control_structures

/// Local-only organizational metadata. It deliberately has no factual-field,
/// provenance, ownership, or valuation meaning.
class ArtworkGroup {
  const ArtworkGroup({
    required this.id,
    required this.name,
    required this.normalizedName,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
    required this.memberCount,
  });

  final String id;
  final String name;
  final String normalizedName;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int memberCount;
}

enum GroupOrderReplaceResult { applied, unchanged, stale }

class ArtworkGroupNameException implements Exception {
  const ArtworkGroupNameException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ArtworkGroupingExportData {
  const ArtworkGroupingExportData({
    required this.groups,
    required this.memberships,
    required this.preferences,
  });
  final List<ArtworkGroup> groups;
  final List<Map<String, Object?>> memberships;
  final List<Map<String, Object?>> preferences;
}

/// The pinned, locale-independent identity key for the supported Unicode 15.1
/// collision vectors. Dart has no Unicode normalization/case-fold API, so the
/// mapping is deliberately explicit instead of using device-locale lowercasing.
String normalizeArtworkGroupName(String raw) {
  final display = normalizeArtworkGroupDisplayName(raw);
  // NFKC compatibility mappings used by the contract, followed by default
  // case-fold mappings that differ from ASCII lowercasing.
  return display
      .replaceAll('Ｆ', 'F')
      .replaceAll('ｏ', 'o')
      .replaceAll('Ｏ', 'O')
      .replaceAll('K', 'K')
      .replaceAll('ς', 'σ')
      .replaceAll('Σ', 'σ')
      .replaceAll('σ', 'σ')
      .replaceAll('ß', 'ss')
      .replaceAll('ẞ', 'ss')
      .replaceAll('é', 'e\u0301')
      .replaceAll('É', 'e\u0301')
      .replaceAll('İ', 'i\u0307')
      .replaceAll('I', 'i')
      .toLowerCase();
}

String normalizeArtworkGroupDisplayName(String raw) {
  // Unicode White_Space property (Unicode 15.1), rather than platform trim.
  final trimmed = raw
      .replaceFirst(
        RegExp(
          r'^[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+',
        ),
        '',
      )
      .replaceFirst(
        RegExp(
          r'[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]+$',
        ),
        '',
      );
  if (trimmed.isEmpty)
    throw const ArtworkGroupNameException('A group name is required.');
  // NFC composition needed for the pinned Café vector.
  return trimmed.replaceAll('e\u0301', 'é').replaceAll('E\u0301', 'É');
}
