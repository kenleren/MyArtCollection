import 'dart:convert';
import 'dart:typed_data';

import '../external_references/external_reference_url_codec.dart';
import '../storage/external_reference.dart';

enum ExternalReferenceExportDecodeStatus { absent, present }

class ExternalReferenceExportDecodeResult {
  const ExternalReferenceExportDecodeResult._(this.status, this.references);

  const ExternalReferenceExportDecodeResult.absent()
    : this._(ExternalReferenceExportDecodeStatus.absent, null);

  ExternalReferenceExportDecodeResult.present(
    List<ExternalReferenceRecord> references,
  ) : this._(
        ExternalReferenceExportDecodeStatus.present,
        List.unmodifiable(references),
      );

  final ExternalReferenceExportDecodeStatus status;
  final List<ExternalReferenceRecord>? references;
}

class ExternalReferenceExportException implements Exception {
  const ExternalReferenceExportException(this.message);
  final String message;

  @override
  String toString() => message;
}

class ExternalReferenceExportCodec {
  const ExternalReferenceExportCodec({
    this.urlCodec = const ExternalReferenceUrlCodec(),
  });

  static const contract = 'EXTERNAL_REFERENCE_EXPORT_CONTRACT_V1';
  static const version = 1;

  final ExternalReferenceUrlCodec urlCodec;

  Uint8List encode(List<ExternalReferenceRecord> references) {
    final sorted = _validatedCanonicalRows(references);
    final envelope = <String, Object?>{
      'contract': contract,
      'version': version,
      'references': sorted.map(_encodeRow).toList(growable: false),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
  }

  Object encodeSectionValue(List<ExternalReferenceRecord> references) {
    final bytes = encode(references);
    return jsonDecode(utf8.decode(bytes))!;
  }

  ExternalReferenceExportDecodeResult decodeRoot(Map<String, Object?> root) {
    if (!root.containsKey('external_references')) {
      return const ExternalReferenceExportDecodeResult.absent();
    }
    return ExternalReferenceExportDecodeResult.present(
      decodeSectionValue(root['external_references']),
    );
  }

  List<ExternalReferenceRecord> decodeStandalone(Uint8List bytes) {
    final String source;
    try {
      source = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const ExternalReferenceExportException(
        'External reference export is not valid UTF-8.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const ExternalReferenceExportException(
        'External reference export is not valid JSON.',
      );
    }
    final records = decodeSectionValue(decoded);
    final canonical = encode(records);
    if (!_bytesEqual(bytes, canonical)) {
      throw const ExternalReferenceExportException(
        'External reference export bytes are not canonical.',
      );
    }
    return records;
  }

  List<ExternalReferenceRecord> decodeSectionValue(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const ExternalReferenceExportException(
        'External references must be an object.',
      );
    }
    _requireExactKeys(value, const ['contract', 'version', 'references']);
    if (value['contract'] != contract || value['version'] != version) {
      throw const ExternalReferenceExportException(
        'External reference contract or version is unsupported.',
      );
    }
    final rows = value['references'];
    if (rows is! List<Object?>) {
      throw const ExternalReferenceExportException(
        'External reference rows must be a list.',
      );
    }
    final records = <ExternalReferenceRecord>[];
    for (final row in rows) {
      records.add(_decodeRow(row));
    }
    final canonical = _validatedCanonicalRows(records);
    for (var index = 0; index < records.length; index++) {
      if (records[index].id != canonical[index].id) {
        throw const ExternalReferenceExportException(
          'External reference rows are not in canonical order.',
        );
      }
    }
    return List.unmodifiable(records);
  }

  List<ExternalReferenceRecord> _validatedCanonicalRows(
    List<ExternalReferenceRecord> references,
  ) {
    final sorted = List<ExternalReferenceRecord>.of(references)
      ..sort(_compareRows);
    final ids = <String>{};
    final urlsByArtwork = <String, Set<String>>{};
    final nextOrder = <String, int>{};
    for (final record in sorted) {
      try {
        record.validateStructure();
        final canonicalUrl = urlCodec.canonicalize(record.url);
        if (canonicalUrl != record.url) {
          throw const ExternalReferenceExportException(
            'External reference URL is not canonical.',
          );
        }
        if (normalizeExternalReferenceLabel(record.label) != record.label) {
          throw const ExternalReferenceExportException(
            'External reference label is not canonical.',
          );
        }
      } on ExternalReferenceValidationException catch (error) {
        throw ExternalReferenceExportException(error.message);
      } on ExternalReferenceUrlException catch (error) {
        throw ExternalReferenceExportException(error.message);
      }
      if (!ids.add(record.id)) {
        throw const ExternalReferenceExportException(
          'External reference IDs must be globally unique.',
        );
      }
      if (!(urlsByArtwork[record.artworkId] ??= <String>{}).add(record.url)) {
        throw const ExternalReferenceExportException(
          'External reference URLs must be unique within an artwork.',
        );
      }
      final expected = nextOrder[record.artworkId] ?? 0;
      if (record.sortOrder != expected) {
        throw const ExternalReferenceExportException(
          'External reference order must be contiguous within each artwork.',
        );
      }
      nextOrder[record.artworkId] = expected + 1;
    }
    return sorted;
  }

  Map<String, Object?> _encodeRow(ExternalReferenceRecord record) => {
    'reference_id': record.id,
    'artwork_id': record.artworkId,
    'reference_type': record.type.storageValue,
    'label': record.label,
    'url': record.url,
    'origin': record.origin.storageValue,
    'review_state': record.reviewState.storageValue,
    'last_confirmed_at': record.lastConfirmedAtText,
    'created_at': record.createdAtText,
    'updated_at': record.updatedAtText,
    'sort_order': record.sortOrder,
  };

  ExternalReferenceRecord _decodeRow(Object? value) {
    if (value is! Map<String, Object?>) {
      throw const ExternalReferenceExportException(
        'Each external reference row must be an object.',
      );
    }
    _requireExactKeys(value, const [
      'reference_id',
      'artwork_id',
      'reference_type',
      'label',
      'url',
      'origin',
      'review_state',
      'last_confirmed_at',
      'created_at',
      'updated_at',
      'sort_order',
    ]);
    final id = _string(value, 'reference_id');
    final artworkId = _string(value, 'artwork_id');
    final typeText = _string(value, 'reference_type');
    final label = value['label'];
    if (label != null && label is! String) throw _wrongType('label');
    final url = _string(value, 'url');
    final originText = _string(value, 'origin');
    final stateText = _string(value, 'review_state');
    final confirmedText = value['last_confirmed_at'];
    if (confirmedText != null && confirmedText is! String) {
      throw _wrongType('last_confirmed_at');
    }
    final createdText = _string(value, 'created_at');
    final updatedText = _string(value, 'updated_at');
    final order = value['sort_order'];
    if (order is! int) throw _wrongType('sort_order');

    try {
      return ExternalReferenceRecord(
        id: id,
        artworkId: artworkId,
        type: ExternalReferenceType.parse(typeText),
        label: label as String?,
        url: url,
        origin: ExternalReferenceOrigin.parse(originText),
        reviewState: ExternalReferenceReviewState.parse(stateText),
        lastConfirmedAt: confirmedText == null
            ? null
            : ExternalReferenceTimestampCodec.parse(confirmedText as String),
        createdAt: ExternalReferenceTimestampCodec.parse(createdText),
        updatedAt: ExternalReferenceTimestampCodec.parse(updatedText),
        sortOrder: order,
      );
    } on ExternalReferenceValidationException catch (error) {
      throw ExternalReferenceExportException(error.message);
    }
  }

  void _requireExactKeys(Map<String, Object?> value, List<String> expected) {
    final actual = value.keys.toList(growable: false);
    if (actual.length != expected.length) {
      throw const ExternalReferenceExportException(
        'External reference export has missing or unknown fields.',
      );
    }
    for (var index = 0; index < expected.length; index++) {
      if (actual[index] != expected[index]) {
        throw const ExternalReferenceExportException(
          'External reference fields are missing, unknown, or out of order.',
        );
      }
    }
  }

  String _string(Map<String, Object?> row, String key) {
    final value = row[key];
    if (value is! String) throw _wrongType(key);
    return value;
  }

  ExternalReferenceExportException _wrongType(String key) =>
      ExternalReferenceExportException(
        'External reference field $key has the wrong type.',
      );

  int _compareRows(
    ExternalReferenceRecord left,
    ExternalReferenceRecord right,
  ) {
    var compared = left.artworkId.compareTo(right.artworkId);
    if (compared != 0) return compared;
    compared = left.sortOrder.compareTo(right.sortOrder);
    if (compared != 0) return compared;
    compared = left.createdAtText.compareTo(right.createdAtText);
    if (compared != 0) return compared;
    return left.id.compareTo(right.id);
  }

  bool _bytesEqual(Uint8List left, Uint8List right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
