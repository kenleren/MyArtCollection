// ignore_for_file: curly_braces_in_flow_control_structures

import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'unicode_15_1_casefold.dart';
import 'unicode_15_1_default_ignorables.dart';

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

/// The pinned, locale-independent Unicode 15.1 NFKC_Casefold identity key.
///
/// The vendored normalizer and generated tables are deliberately data-versioned
/// rather than delegated to a device locale or platform Unicode library. See
/// `third_party/unorm_dart_15_1/README.md` for normalization provenance and the
/// generated tables beside this file for CaseFolding and Default_Ignorable data.
String normalizeArtworkGroupName(String raw) {
  final display = normalizeArtworkGroupDisplayName(raw);
  return unorm.nfc(
    _removeDefaultIgnorables(_fullCaseFold(unorm.nfkc(display))),
  );
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
  return unorm.nfc(trimmed);
}

String _fullCaseFold(String value) {
  final result = StringBuffer();
  for (final rune in value.runes) {
    final mapping = unicode151CaseFold[rune];
    if (mapping == null) {
      result.writeCharCode(rune);
    } else {
      for (final mappedRune in mapping) {
        result.writeCharCode(mappedRune);
      }
    }
  }
  return result.toString();
}

String _removeDefaultIgnorables(String value) {
  final result = StringBuffer();
  for (final rune in value.runes) {
    final isIgnorable = unicode151DefaultIgnorableRanges.any(
      (range) => rune >= range.$1 && rune <= range.$2,
    );
    if (!isIgnorable) result.writeCharCode(rune);
  }
  return result.toString();
}
