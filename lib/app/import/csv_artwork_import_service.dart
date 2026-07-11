import 'dart:convert';
import 'dart:typed_data';

import '../storage/artwork_record.dart';

enum CsvArtworkImportFailure {
  emptyFile,
  fileTooLarge,
  rowLimitExceeded,
  malformedCsv,
}

class CsvArtworkImportException implements Exception {
  const CsvArtworkImportException(this.failure, this.message);

  final CsvArtworkImportFailure failure;
  final String message;

  @override
  String toString() => message;
}

class CsvArtworkImportPreview {
  const CsvArtworkImportPreview({
    required this.headers,
    required this.headerMappings,
    required this.rows,
    required this.skippedColumns,
  });

  final List<String> headers;
  final List<CsvArtworkColumnMapping> headerMappings;
  final List<CsvArtworkImportRowPreview> rows;
  final List<String> skippedColumns;

  Iterable<CsvArtworkImportRowPreview> get importableRows =>
      rows.where((row) => row.isImportable);
}

class CsvArtworkImportRowPreview {
  const CsvArtworkImportRowPreview({
    required this.rowNumber,
    required this.rawValues,
    required this.fields,
    required this.warnings,
    required this.errors,
    required this.duplicateCandidates,
    required this.record,
  });

  final int rowNumber;
  final Map<String, String> rawValues;
  final Map<String, ArtworkFieldValue> fields;
  final List<String> warnings;
  final List<String> errors;
  final List<CsvArtworkDuplicateCandidate> duplicateCandidates;
  final ArtworkRecord? record;

  bool get isImportable => errors.isEmpty && record != null;
}

class CsvArtworkDuplicateCandidate {
  const CsvArtworkDuplicateCandidate({
    required this.source,
    required this.reason,
    this.existingArtworkId,
    this.incomingRowNumber,
  });

  final CsvArtworkDuplicateSource source;
  final String reason;
  final String? existingArtworkId;
  final int? incomingRowNumber;
}

enum CsvArtworkDuplicateSource { existingRecord, incomingRow }

enum CsvArtworkColumnMappingKind { canonical, reference, unmapped, skip }

class CsvArtworkColumnMapping {
  const CsvArtworkColumnMapping.canonical(this.fieldKey)
    : kind = CsvArtworkColumnMappingKind.canonical;
  const CsvArtworkColumnMapping.reference()
    : kind = CsvArtworkColumnMappingKind.reference,
      fieldKey = null;
  const CsvArtworkColumnMapping.unmapped()
    : kind = CsvArtworkColumnMappingKind.unmapped,
      fieldKey = null;
  const CsvArtworkColumnMapping.skip()
    : kind = CsvArtworkColumnMappingKind.skip,
      fieldKey = null;

  final CsvArtworkColumnMappingKind kind;
  final String? fieldKey;

  String get id => switch (kind) {
    CsvArtworkColumnMappingKind.canonical => 'field:$fieldKey',
    CsvArtworkColumnMappingKind.reference => 'reference',
    CsvArtworkColumnMappingKind.unmapped => 'unmapped',
    CsvArtworkColumnMappingKind.skip => 'skip',
  };

  @override
  bool operator ==(Object other) {
    return other is CsvArtworkColumnMapping &&
        other.kind == kind &&
        other.fieldKey == fieldKey;
  }

  @override
  int get hashCode => Object.hash(kind, fieldKey);
}

class CsvArtworkImportService {
  CsvArtworkImportService({
    DateTime Function()? now,
    String Function()? idFactory,
    this.appendUnmappedColumnsToNotes = true,
  }) : _now = now ?? DateTime.now,
       _idFactory = idFactory ?? _timestampId;

  static const maxFileBytes = 2 * 1024 * 1024;
  static const maxRows = 500;

  final DateTime Function() _now;
  final String Function() _idFactory;
  final bool appendUnmappedColumnsToNotes;

  CsvArtworkImportPreview previewFromBytes(
    Uint8List bytes, {
    List<ArtworkRecord> existingRecords = const [],
    List<CsvArtworkColumnMapping>? headerMappings,
  }) {
    if (bytes.isEmpty) {
      throw const CsvArtworkImportException(
        CsvArtworkImportFailure.emptyFile,
        'This spreadsheet is empty.',
      );
    }
    if (bytes.length > maxFileBytes) {
      throw const CsvArtworkImportException(
        CsvArtworkImportFailure.fileTooLarge,
        'This spreadsheet is larger than the 2 MB import limit.',
      );
    }

    final text = _decodeUtf8(bytes);
    return previewFromString(
      text,
      existingRecords: existingRecords,
      headerMappings: headerMappings,
    );
  }

  CsvArtworkImportPreview previewFromString(
    String csv, {
    List<ArtworkRecord> existingRecords = const [],
    List<CsvArtworkColumnMapping>? headerMappings,
  }) {
    if (utf8.encode(csv).length > maxFileBytes) {
      throw const CsvArtworkImportException(
        CsvArtworkImportFailure.fileTooLarge,
        'This spreadsheet is larger than the 2 MB import limit.',
      );
    }

    final rows = _CsvParser().parse(_stripUtf8Bom(csv));
    if (rows.isEmpty || rows.every((row) => row.every(_isBlank))) {
      throw const CsvArtworkImportException(
        CsvArtworkImportFailure.emptyFile,
        'This spreadsheet is empty.',
      );
    }

    final headers = rows.first.map((header) => header.trim()).toList();
    if (headers.every(_isBlank)) {
      throw const CsvArtworkImportException(
        CsvArtworkImportFailure.emptyFile,
        'The first row needs column headings.',
      );
    }

    final dataRows = rows
        .skip(1)
        .where((row) => row.any((cell) => !_isBlank(cell)));
    if (dataRows.length > maxRows) {
      throw const CsvArtworkImportException(
        CsvArtworkImportFailure.rowLimitExceeded,
        'This import can review up to 500 artworks at a time.',
      );
    }

    final mappings = <CsvArtworkColumnMapping>[
      for (var index = 0; index < headers.length; index += 1)
        if (headerMappings != null && index < headerMappings.length)
          headerMappings[index]
        else
          _mappingForHeader(headers[index]),
    ];
    final skippedColumns = <String>[
      for (var index = 0; index < headers.length; index += 1)
        if (mappings[index].kind == CsvArtworkColumnMappingKind.skip)
          headers[index],
    ];

    final existingKeys = existingRecords
        .map((record) => _DuplicateKey.fromFields(record.fields))
        .toList();
    final incomingKeys = <_DuplicateKey>[];
    final previews = <CsvArtworkImportRowPreview>[];

    var sourceRowIndex = 1;
    for (final row in rows.skip(1)) {
      sourceRowIndex += 1;
      if (row.every((cell) => _isBlank(cell))) {
        continue;
      }

      final preview = _previewRow(
        rowNumber: sourceRowIndex,
        headers: headers,
        values: row,
        mappings: mappings,
        existingRecords: existingRecords,
        existingKeys: existingKeys,
        incomingKeys: incomingKeys,
      );
      previews.add(preview);
      if (preview.record != null) {
        incomingKeys.add(
          _DuplicateKey.fromFields(
            preview.record!.fields,
            rowNumber: preview.rowNumber,
          ),
        );
      }
    }

    return CsvArtworkImportPreview(
      headers: headers,
      headerMappings: List.unmodifiable(mappings),
      rows: previews,
      skippedColumns: skippedColumns,
    );
  }

  CsvArtworkImportRowPreview _previewRow({
    required int rowNumber,
    required List<String> headers,
    required List<String> values,
    required List<CsvArtworkColumnMapping> mappings,
    required List<ArtworkRecord> existingRecords,
    required List<_DuplicateKey> existingKeys,
    required List<_DuplicateKey> incomingKeys,
  }) {
    final rawValues = <String, String>{};
    final fieldText = <String, String>{};
    final unmappedNotes = <String>[];
    final referenceNotes = <String>[];
    final warnings = <String>[];
    final errors = <String>[];

    for (var index = 0; index < headers.length; index += 1) {
      final header = headers[index];
      final value = index < values.length ? values[index].trim() : '';
      rawValues[header] = value;
      if (_isBlank(value)) {
        continue;
      }

      final mapping = mappings[index];
      switch (mapping.kind) {
        case CsvArtworkColumnMappingKind.canonical:
          fieldText.putIfAbsent(mapping.fieldKey!, () => value);
        case CsvArtworkColumnMappingKind.reference:
          referenceNotes.add('- $header: $value');
        case CsvArtworkColumnMappingKind.unmapped:
          if (appendUnmappedColumnsToNotes) {
            unmappedNotes.add('- $header: $value');
          }
        case CsvArtworkColumnMappingKind.skip:
          break;
      }
    }
    if (values.length > headers.length) {
      warnings.add(
        'This row has more cells than headings, so the extra details were kept in notes.',
      );
      for (var index = headers.length; index < values.length; index += 1) {
        final header = 'Unmapped column ${index + 1}';
        final value = values[index].trim();
        rawValues[header] = value;
        if (!_isBlank(value) && appendUnmappedColumnsToNotes) {
          unmappedNotes.add('- $header: $value');
        }
      }
    }

    final composedNotes = _composeNotes(
      fieldText[ArtworkFieldKeys.notes],
      unmappedNotes: unmappedNotes,
      referenceNotes: referenceNotes,
    );
    if (composedNotes != null) {
      fieldText[ArtworkFieldKeys.notes] = composedNotes;
    }

    if (!_hasIdentifyingText(fieldText)) {
      errors.add(
        'Add at least a title, artist, note, reference, or other identifying detail for this row.',
      );
    }

    _addAmbiguityWarnings(fieldText, warnings);

    final fields = _fieldsFromText(fieldText);
    ArtworkRecord? record;
    final duplicateCandidates = <CsvArtworkDuplicateCandidate>[];

    if (errors.isEmpty) {
      final now = _now();
      record = ArtworkRecord(
        id: 'csv-import-${_idFactory()}',
        recordState: ArtworkRecordState.needsReview,
        createdAt: now,
        updatedAt: now,
        fields: fields,
      );

      final duplicateKey = _DuplicateKey.fromFields(fields);
      for (var index = 0; index < existingKeys.length; index += 1) {
        final reason = duplicateKey.matchReason(existingKeys[index]);
        if (reason != null) {
          duplicateCandidates.add(
            CsvArtworkDuplicateCandidate(
              source: CsvArtworkDuplicateSource.existingRecord,
              existingArtworkId: existingRecords[index].id,
              reason: reason,
            ),
          );
        }
      }
      for (final incomingKey in incomingKeys) {
        final reason = duplicateKey.matchReason(incomingKey);
        if (reason != null) {
          duplicateCandidates.add(
            CsvArtworkDuplicateCandidate(
              source: CsvArtworkDuplicateSource.incomingRow,
              incomingRowNumber: incomingKey.rowNumber,
              reason: reason,
            ),
          );
        }
      }
    }

    return CsvArtworkImportRowPreview(
      rowNumber: rowNumber,
      rawValues: rawValues,
      fields: fields,
      warnings: warnings,
      errors: errors,
      duplicateCandidates: duplicateCandidates,
      record: record,
    );
  }

  Map<String, ArtworkFieldValue> _fieldsFromText(
    Map<String, String> fieldText,
  ) {
    return {
      for (final entry in fieldText.entries)
        if (!_isBlank(entry.value))
          entry.key: ArtworkFieldValue(
            value: entry.value,
            source: entry.key == ArtworkFieldKeys.notes
                ? ArtworkFieldSource.unknown
                : ArtworkFieldSource.documentExtracted,
            note: entry.key == ArtworkFieldKeys.notes
                ? 'Imported notes and unmapped reference text need review.'
                : 'Imported from a CSV column and needs review.',
            moneyAmount: _moneyAmountFor(entry.key, entry.value),
            moneyCurrencyCode: _moneyCurrencyFor(entry.key, entry.value),
          ),
    };
  }

  static String _decodeUtf8(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException catch (error) {
      throw CsvArtworkImportException(
        CsvArtworkImportFailure.malformedCsv,
        'This spreadsheet could not be read. Save it again as a standard CSV and try again: ${error.message}',
      );
    }
  }

  static String _stripUtf8Bom(String text) {
    if (text.startsWith('\uFEFF')) {
      return text.substring(1);
    }
    return text;
  }

  static CsvArtworkColumnMapping _mappingForHeader(String header) {
    final normalized = _normalizeHeader(header);
    final compact = normalized.replaceAll('_', '');
    if (normalized.isEmpty) {
      return const CsvArtworkColumnMapping.skip();
    }
    if (_referenceHeaderCompacts.contains(compact) ||
        compact.contains('photo') ||
        compact.contains('image') ||
        compact.contains('document') ||
        compact.contains('attachment') ||
        compact.contains('reference') ||
        compact.endsWith('url') ||
        compact.endsWith('link')) {
      return const CsvArtworkColumnMapping.reference();
    }
    final fieldKey =
        _canonicalHeaderMap[normalized] ?? _canonicalCompactMap[compact];
    if (fieldKey != null) {
      return CsvArtworkColumnMapping.canonical(fieldKey);
    }
    return const CsvArtworkColumnMapping.unmapped();
  }

  static String _normalizeHeader(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll('&', ' and ')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }

  static String? _composeNotes(
    String? importedNotes, {
    required List<String> unmappedNotes,
    required List<String> referenceNotes,
  }) {
    final sections = <String>[];
    if (!_isBlank(importedNotes)) {
      sections.add(importedNotes!.trim());
    }
    if (unmappedNotes.isNotEmpty) {
      sections.add('Imported unmapped fields:\n${unmappedNotes.join('\n')}');
    }
    if (referenceNotes.isNotEmpty) {
      sections.add(
        'Unresolved imported references:\n${referenceNotes.join('\n')}',
      );
    }
    return sections.isEmpty ? null : sections.join('\n\n');
  }

  static bool _hasIdentifyingText(Map<String, String> fieldText) {
    return !_isBlank(fieldText[ArtworkFieldKeys.title]) ||
        !_isBlank(fieldText[ArtworkFieldKeys.artist]) ||
        !_isBlank(fieldText[ArtworkFieldKeys.notes]) ||
        !_isBlank(fieldText[ArtworkFieldKeys.conditionNotes]);
  }

  static void _addAmbiguityWarnings(
    Map<String, String> fieldText,
    List<String> warnings,
  ) {
    final year = fieldText[ArtworkFieldKeys.year];
    if (!_isBlank(year) && !_isUnambiguousYear(year!)) {
      warnings.add('Year looks uncertain, so it was kept exactly as imported.');
    }

    final purchasePrice = fieldText[ArtworkFieldKeys.purchasePrice];
    if (!_isBlank(purchasePrice) &&
        _moneyAmountFor(ArtworkFieldKeys.purchasePrice, purchasePrice!) ==
            null) {
      warnings.add(
        'Purchase price needs a closer look, so it was kept exactly as imported.',
      );
    }

    final insuranceValue = fieldText[ArtworkFieldKeys.insuranceValue];
    if (!_isBlank(insuranceValue) &&
        _moneyAmountFor(ArtworkFieldKeys.insuranceValue, insuranceValue!) ==
            null) {
      warnings.add(
        'Insurance value needs a closer look, so it was kept exactly as imported.',
      );
    }

    final purchaseDate = fieldText[ArtworkFieldKeys.purchaseDate];
    if (!_isBlank(purchaseDate) && !_isUnambiguousIsoDate(purchaseDate!)) {
      warnings.add(
        'Purchase date looks uncertain, so it was kept exactly as imported.',
      );
    }

    final dimensions = fieldText[ArtworkFieldKeys.dimensions];
    if (!_isBlank(dimensions) && !_isUnambiguousDimensions(dimensions!)) {
      warnings.add(
        'Dimensions need a closer look, so they were kept exactly as imported.',
      );
    }
  }

  static bool _isUnambiguousYear(String value) {
    final match = RegExp(r'^\d{4}$').firstMatch(value.trim());
    if (match == null) {
      return false;
    }
    final year = int.parse(match.group(0)!);
    return year >= 1000 && year <= DateTime.now().year + 1;
  }

  static bool _isUnambiguousIsoDate(String value) {
    final trimmed = value.trim();
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(trimmed)) {
      return false;
    }
    final parsed = DateTime.tryParse(trimmed);
    return parsed != null && parsed.toIso8601String().startsWith(trimmed);
  }

  static bool _isUnambiguousDimensions(String value) {
    return RegExp(
      r'^\d+(\.\d+)?\s*(x|×)\s*\d+(\.\d+)?(\s*(x|×)\s*\d+(\.\d+)?)?\s*(cm|mm|m|in|inch|inches|ft|feet)$',
      caseSensitive: false,
    ).hasMatch(value.trim());
  }

  static String? _moneyAmountFor(String fieldKey, String value) {
    if (fieldKey != ArtworkFieldKeys.purchasePrice &&
        fieldKey != ArtworkFieldKeys.insuranceValue) {
      return null;
    }
    final parsed = _parseSimpleMoney(value);
    return parsed?.amount;
  }

  static String? _moneyCurrencyFor(String fieldKey, String value) {
    if (fieldKey != ArtworkFieldKeys.purchasePrice &&
        fieldKey != ArtworkFieldKeys.insuranceValue) {
      return null;
    }
    final parsed = _parseSimpleMoney(value);
    return parsed?.currencyCode;
  }

  static _ParsedMoney? _parseSimpleMoney(String value) {
    final trimmed = value.trim();
    if (RegExp(
      r'(~|≈|about|approx|around|between|to|\-)',
      caseSensitive: false,
    ).hasMatch(trimmed)) {
      return null;
    }

    final match = RegExp(
      r'^(?:(USD|EUR|NOK|GBP|DKK|SEK|CHF|CAD|AUD)\s*)?([$€£krKR]*)\s*([0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?)\s*(USD|EUR|NOK|GBP|DKK|SEK|CHF|CAD|AUD)?$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (match == null) {
      return null;
    }

    final code = match.group(1)?.toUpperCase() ?? match.group(4)?.toUpperCase();
    final symbol = match.group(2);
    final currencyCode =
        code ??
        switch (symbol) {
          r'$' => 'USD',
          '€' => 'EUR',
          '£' => 'GBP',
          'kr' || 'KR' => 'NOK',
          _ => null,
        };
    return _ParsedMoney(
      amount: match.group(3)!.replaceAll(',', ''),
      currencyCode: currencyCode,
    );
  }

  static bool _isBlank(String? value) => value == null || value.trim().isEmpty;

  static String _timestampId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  static const _canonicalHeaderMap = <String, String>{
    'title': ArtworkFieldKeys.title,
    'artwork_title': ArtworkFieldKeys.title,
    'work_title': ArtworkFieldKeys.title,
    'object_title': ArtworkFieldKeys.title,
    'name': ArtworkFieldKeys.title,
    'artist': ArtworkFieldKeys.artist,
    'artist_name': ArtworkFieldKeys.artist,
    'creator': ArtworkFieldKeys.artist,
    'maker': ArtworkFieldKeys.artist,
    'year': ArtworkFieldKeys.year,
    'date': ArtworkFieldKeys.year,
    'date_created': ArtworkFieldKeys.year,
    'creation_date': ArtworkFieldKeys.year,
    'created': ArtworkFieldKeys.year,
    'medium': ArtworkFieldKeys.medium,
    'material': ArtworkFieldKeys.medium,
    'materials': ArtworkFieldKeys.medium,
    'technique': ArtworkFieldKeys.medium,
    'dimensions': ArtworkFieldKeys.dimensions,
    'dimension': ArtworkFieldKeys.dimensions,
    'size': ArtworkFieldKeys.dimensions,
    'measurements': ArtworkFieldKeys.dimensions,
    'edition': ArtworkFieldKeys.edition,
    'edition_number': ArtworkFieldKeys.edition,
    'edition_no': ArtworkFieldKeys.edition,
    'purchase_price': ArtworkFieldKeys.purchasePrice,
    'acquisition_price': ArtworkFieldKeys.purchasePrice,
    'price': ArtworkFieldKeys.purchasePrice,
    'cost': ArtworkFieldKeys.purchasePrice,
    'amount_paid': ArtworkFieldKeys.purchasePrice,
    'purchase_date': ArtworkFieldKeys.purchaseDate,
    'date_purchased': ArtworkFieldKeys.purchaseDate,
    'acquisition_date': ArtworkFieldKeys.purchaseDate,
    'acquired_date': ArtworkFieldKeys.purchaseDate,
    'seller_or_gallery': ArtworkFieldKeys.sellerOrGallery,
    'seller_gallery': ArtworkFieldKeys.sellerOrGallery,
    'seller': ArtworkFieldKeys.sellerOrGallery,
    'gallery': ArtworkFieldKeys.sellerOrGallery,
    'dealer': ArtworkFieldKeys.sellerOrGallery,
    'vendor': ArtworkFieldKeys.sellerOrGallery,
    'location': ArtworkFieldKeys.currentLocation,
    'current_location': ArtworkFieldKeys.currentLocation,
    'room': ArtworkFieldKeys.currentLocation,
    'current_room': ArtworkFieldKeys.currentLocation,
    'insurance_value': ArtworkFieldKeys.insuranceValue,
    'insured_value': ArtworkFieldKeys.insuranceValue,
    'appraisal_value': ArtworkFieldKeys.insuranceValue,
    'appraised_value': ArtworkFieldKeys.insuranceValue,
    'value': ArtworkFieldKeys.insuranceValue,
    'condition': ArtworkFieldKeys.conditionNotes,
    'condition_notes': ArtworkFieldKeys.conditionNotes,
    'notes': ArtworkFieldKeys.notes,
    'note': ArtworkFieldKeys.notes,
    'description': ArtworkFieldKeys.notes,
    'comments': ArtworkFieldKeys.notes,
    'provenance': ArtworkFieldKeys.notes,
  };

  static final _canonicalCompactMap = {
    for (final entry in _canonicalHeaderMap.entries)
      entry.key.replaceAll('_', ''): entry.value,
    'locationcurrentlocationroom': ArtworkFieldKeys.currentLocation,
  };

  static const _referenceHeaderCompacts = <String>{
    'photo',
    'photos',
    'image',
    'images',
    'document',
    'documents',
    'file',
    'files',
    'reference',
    'references',
    'receipt',
    'invoice',
    'certificate',
    'certificates',
  };
}

class _ParsedMoney {
  const _ParsedMoney({required this.amount, required this.currencyCode});

  final String amount;
  final String? currencyCode;
}

class _DuplicateKey {
  const _DuplicateKey({
    required this.title,
    required this.artist,
    required this.year,
    required this.dimensions,
    this.rowNumber,
  });

  factory _DuplicateKey.fromFields(
    Map<String, ArtworkFieldValue> fields, {
    int? rowNumber,
  }) {
    return _DuplicateKey(
      title: _normalizeDuplicateValue(fields[ArtworkFieldKeys.title]?.value),
      artist: _normalizeDuplicateValue(fields[ArtworkFieldKeys.artist]?.value),
      year: _normalizeDuplicateValue(fields[ArtworkFieldKeys.year]?.value),
      dimensions: _normalizeDuplicateValue(
        fields[ArtworkFieldKeys.dimensions]?.value,
      ),
      rowNumber: rowNumber,
    );
  }

  final String title;
  final String artist;
  final String year;
  final String dimensions;
  final int? rowNumber;

  String? matchReason(_DuplicateKey other) {
    if (title.isEmpty || other.title.isEmpty) {
      return null;
    }
    if (artist.isNotEmpty &&
        other.artist.isNotEmpty &&
        artist == other.artist &&
        title == other.title) {
      return 'Title and artist closely match.';
    }
    if ((artist.isEmpty || other.artist.isEmpty) &&
        title == other.title &&
        ((year.isNotEmpty && year == other.year) ||
            (dimensions.isNotEmpty && dimensions == other.dimensions))) {
      return 'Title plus year or dimensions closely match.';
    }
    return null;
  }

  static String _normalizeDuplicateValue(String? value) {
    return (value ?? '')
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
  }
}

class _CsvParser {
  List<List<String>> parse(String input) {
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    var fieldStartedWithQuote = false;
    var justClosedQuote = false;

    void endField() {
      row.add(field.toString());
      field.clear();
      fieldStartedWithQuote = false;
      justClosedQuote = false;
    }

    void endRow() {
      endField();
      rows.add(row);
      row = <String>[];
    }

    for (var index = 0; index < input.length; index += 1) {
      final char = input[index];

      if (inQuotes) {
        if (char == '"') {
          final nextIsQuote =
              index + 1 < input.length && input[index + 1] == '"';
          if (nextIsQuote) {
            field.write('"');
            index += 1;
          } else {
            inQuotes = false;
            justClosedQuote = true;
          }
        } else {
          field.write(char);
        }
        continue;
      }

      if (char == '"') {
        if (field.isEmpty && !fieldStartedWithQuote) {
          inQuotes = true;
          fieldStartedWithQuote = true;
          continue;
        }
        throw const CsvArtworkImportException(
          CsvArtworkImportFailure.malformedCsv,
          'A quoted field is not formatted correctly.',
        );
      }

      if (justClosedQuote && char != ',' && char != '\n' && char != '\r') {
        if (char.trim().isEmpty) {
          continue;
        }
        throw const CsvArtworkImportException(
          CsvArtworkImportFailure.malformedCsv,
          'A quoted field has extra text after the closing quote.',
        );
      }

      if (char == ',') {
        endField();
      } else if (char == '\n') {
        endRow();
      } else if (char == '\r') {
        endRow();
        if (index + 1 < input.length && input[index + 1] == '\n') {
          index += 1;
        }
      } else {
        field.write(char);
      }
    }

    if (inQuotes) {
      throw const CsvArtworkImportException(
        CsvArtworkImportFailure.malformedCsv,
        'A quoted field is missing a closing quote.',
      );
    }

    final endedWithNewline = input.endsWith('\n') || input.endsWith('\r');
    if (field.isNotEmpty || row.isNotEmpty || !endedWithNewline) {
      endField();
      rows.add(row);
    }

    return rows;
  }
}
