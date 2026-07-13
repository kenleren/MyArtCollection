enum ExternalReferenceType {
  galleryOrArtist('gallery_or_artist', 'Gallery or artist'),
  museumOrInstitution('museum_or_institution', 'Museum or institution'),
  auctionOrMarketplace('auction_or_marketplace', 'Auction or marketplace'),
  exhibitionOrArtFair('exhibition_or_art_fair', 'Exhibition or art fair'),
  publicationOrCatalogue(
    'publication_or_catalogue',
    'Publication or catalogue',
  ),
  other('other', 'Other');

  const ExternalReferenceType(this.storageValue, this.label);
  final String storageValue;
  final String label;

  static ExternalReferenceType parse(String value) => values.firstWhere(
    (type) => type.storageValue == value,
    orElse: () => throw const ExternalReferenceValidationException(
      ExternalReferenceValidationFailure.invalidType,
      'Unknown external reference type.',
    ),
  );
}

enum ExternalReferenceOrigin {
  manual('manual', 'Added by you'),
  aiSuggestion('ai_suggestion', 'AI suggestion');

  const ExternalReferenceOrigin(this.storageValue, this.label);
  final String storageValue;
  final String label;

  static ExternalReferenceOrigin parse(String value) => values.firstWhere(
    (origin) => origin.storageValue == value,
    orElse: () => throw const ExternalReferenceValidationException(
      ExternalReferenceValidationFailure.invalidOrigin,
      'Unknown external reference origin.',
    ),
  );
}

enum ExternalReferenceReviewState {
  suggested('suggested', 'Suggested'),
  confirmed('confirmed', 'Confirmed by you');

  const ExternalReferenceReviewState(this.storageValue, this.label);
  final String storageValue;
  final String label;

  static ExternalReferenceReviewState parse(String value) => values.firstWhere(
    (state) => state.storageValue == value,
    orElse: () => throw const ExternalReferenceValidationException(
      ExternalReferenceValidationFailure.invalidReviewState,
      'Unknown external reference review state.',
    ),
  );
}

enum ExternalReferenceValidationFailure {
  invalidId,
  invalidLabel,
  invalidType,
  invalidOrigin,
  invalidReviewState,
  invalidStateCombination,
  invalidTimestamp,
  invalidSortOrder,
}

class ExternalReferenceValidationException implements Exception {
  const ExternalReferenceValidationException(this.failure, this.message);
  final ExternalReferenceValidationFailure failure;
  final String message;

  @override
  String toString() => message;
}

abstract final class ExternalReferenceTimestampCodec {
  static final RegExp _shape = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$',
  );

  static DateTime normalize(DateTime value) {
    final utc = value.toUtc();
    return DateTime.utc(
      utc.year,
      utc.month,
      utc.day,
      utc.hour,
      utc.minute,
      utc.second,
      utc.millisecond,
    );
  }

  static String format(DateTime value) {
    final utc = normalize(value);
    if (utc.year < 1 || utc.year > 9999) {
      throw const ExternalReferenceValidationException(
        ExternalReferenceValidationFailure.invalidTimestamp,
        'External reference timestamps require years 0001 through 9999.',
      );
    }
    String two(int part) => part.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-'
        '${two(utc.day)}T${two(utc.hour)}:${two(utc.minute)}:'
        '${two(utc.second)}.${utc.millisecond.toString().padLeft(3, '0')}Z';
  }

  static DateTime parse(String value) {
    if (!_shape.hasMatch(value)) {
      throw const ExternalReferenceValidationException(
        ExternalReferenceValidationFailure.invalidTimestamp,
        'External reference timestamp is not canonical UTC milliseconds.',
      );
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null || format(parsed) != value) {
      throw const ExternalReferenceValidationException(
        ExternalReferenceValidationFailure.invalidTimestamp,
        'External reference timestamp is not a valid calendar instant.',
      );
    }
    return parsed;
  }
}

class ExternalReferenceRecord {
  const ExternalReferenceRecord({
    required this.id,
    required this.artworkId,
    required this.type,
    required this.label,
    required this.url,
    required this.origin,
    required this.reviewState,
    required this.lastConfirmedAt,
    required this.createdAt,
    required this.updatedAt,
    required this.sortOrder,
  });

  final String id;
  final String artworkId;
  final ExternalReferenceType type;
  final String? label;
  final String url;
  final ExternalReferenceOrigin origin;
  final ExternalReferenceReviewState reviewState;
  final DateTime? lastConfirmedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int sortOrder;

  String get createdAtText => ExternalReferenceTimestampCodec.format(createdAt);
  String get updatedAtText => ExternalReferenceTimestampCodec.format(updatedAt);
  String? get lastConfirmedAtText => lastConfirmedAt == null
      ? null
      : ExternalReferenceTimestampCodec.format(lastConfirmedAt!);

  void validateStructure() {
    validateExternalReferenceId(id);
    validateExternalReferenceId(artworkId);
    normalizeExternalReferenceLabel(label);
    ExternalReferenceTimestampCodec.format(createdAt);
    ExternalReferenceTimestampCodec.format(updatedAt);
    if (sortOrder < 0) {
      throw const ExternalReferenceValidationException(
        ExternalReferenceValidationFailure.invalidSortOrder,
        'External reference order cannot be negative.',
      );
    }
    if (reviewState == ExternalReferenceReviewState.suggested) {
      if (origin != ExternalReferenceOrigin.aiSuggestion ||
          lastConfirmedAt != null) {
        throw const ExternalReferenceValidationException(
          ExternalReferenceValidationFailure.invalidStateCombination,
          'Only an unconfirmed AI suggestion can be suggested.',
        );
      }
    } else if (lastConfirmedAt == null) {
      throw const ExternalReferenceValidationException(
        ExternalReferenceValidationFailure.invalidStateCombination,
        'A confirmed reference requires a confirmation timestamp.',
      );
    } else {
      ExternalReferenceTimestampCodec.format(lastConfirmedAt!);
    }
  }

  ExternalReferenceRecord copyWith({
    ExternalReferenceType? type,
    String? label,
    bool clearLabel = false,
    String? url,
    ExternalReferenceReviewState? reviewState,
    DateTime? lastConfirmedAt,
    DateTime? updatedAt,
    int? sortOrder,
  }) => ExternalReferenceRecord(
    id: id,
    artworkId: artworkId,
    type: type ?? this.type,
    label: clearLabel ? null : label ?? this.label,
    url: url ?? this.url,
    origin: origin,
    reviewState: reviewState ?? this.reviewState,
    lastConfirmedAt: lastConfirmedAt ?? this.lastConfirmedAt,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    sortOrder: sortOrder ?? this.sortOrder,
  );
}

void validateExternalReferenceId(String value) {
  if (value.isEmpty ||
      value.length > 128 ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw const ExternalReferenceValidationException(
      ExternalReferenceValidationFailure.invalidId,
      'External reference IDs must be 1-128 ASCII letters, digits, _ or -.',
    );
  }
}

String? normalizeExternalReferenceLabel(String? value) {
  if (value == null) return null;
  var start = 0;
  var end = value.length;
  while (start < end && value.codeUnitAt(start) == 0x20) {
    start++;
  }
  while (end > start && value.codeUnitAt(end - 1) == 0x20) {
    end--;
  }
  final trimmed = value.substring(start, end);
  if (trimmed.isEmpty || trimmed.runes.length > 120) {
    throw const ExternalReferenceValidationException(
      ExternalReferenceValidationFailure.invalidLabel,
      'Reference labels must contain 1-120 characters.',
    );
  }
  for (final rune in trimmed.runes) {
    if (rune <= 0x1f || rune == 0x7f || (rune >= 0x80 && rune <= 0x9f)) {
      throw const ExternalReferenceValidationException(
        ExternalReferenceValidationFailure.invalidLabel,
        'Reference labels cannot contain control characters.',
      );
    }
  }
  return trimmed;
}
