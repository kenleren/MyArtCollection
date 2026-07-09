import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/import/csv_artwork_import_service.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('CSV parsing', () {
    test('supports UTF-8 BOM, quoted commas/newlines, empty cells, and LF', () {
      final service = _service();
      final bytes = Uint8List.fromList([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(
          'Title,Artist,Notes\n'
          '"Blue, Interior",,"Line one\nline two"\n',
        ),
      ]);

      final preview = service.previewFromBytes(bytes);

      expect(preview.headers, ['Title', 'Artist', 'Notes']);
      expect(preview.rows, hasLength(1));
      expect(preview.rows.single.rawValues['Artist'], '');
      expect(
        preview.rows.single.record!.field(ArtworkFieldKeys.title)?.value,
        'Blue, Interior',
      );
      expect(
        preview.rows.single.record!.field(ArtworkFieldKeys.notes)?.value,
        'Line one\nline two',
      );
    });

    test('supports CRLF line endings', () {
      final preview = _service().previewFromString(
        'Title,Artist\r\nHarbor,A. Painter\r\nStudio,B. Painter\r\n',
      );

      expect(preview.rows.map((row) => row.rowNumber), [2, 3]);
      expect(
        preview.rows.last.record!.field(ArtworkFieldKeys.title)?.value,
        'Studio',
      );
    });

    test('rejects malformed quoted CSV', () {
      expect(
        () => _service().previewFromString('Title,Artist\n"Open quote,Name\n'),
        throwsA(
          isA<CsvArtworkImportException>().having(
            (error) => error.failure,
            'failure',
            CsvArtworkImportFailure.malformedCsv,
          ),
        ),
      );
    });

    test('enforces 500 artwork rows and 2 MB byte limit', () {
      final tooManyRows = StringBuffer('Title\n');
      for (
        var index = 0;
        index < CsvArtworkImportService.maxRows + 1;
        index += 1
      ) {
        tooManyRows.writeln('Artwork $index');
      }

      expect(
        () => _service().previewFromString(tooManyRows.toString()),
        throwsA(
          isA<CsvArtworkImportException>().having(
            (error) => error.failure,
            'failure',
            CsvArtworkImportFailure.rowLimitExceeded,
          ),
        ),
      );

      expect(
        () => _service().previewFromBytes(
          Uint8List(CsvArtworkImportService.maxFileBytes + 1),
        ),
        throwsA(
          isA<CsvArtworkImportException>().having(
            (error) => error.failure,
            'failure',
            CsvArtworkImportFailure.fileTooLarge,
          ),
        ),
      );
    });

    test('enforces 2 MB byte limit for string previews', () {
      final oversizedCsv = StringBuffer('Title\n')
        ..write(List.filled(CsvArtworkImportService.maxFileBytes, 'a').join());

      expect(
        () => _service().previewFromString(oversizedCsv.toString()),
        throwsA(
          isA<CsvArtworkImportException>().having(
            (error) => error.failure,
            'failure',
            CsvArtworkImportFailure.fileTooLarge,
          ),
        ),
      );
    });
  });

  group('CSV mapping and validation', () {
    test(
      'maps canonical headers and generates preview fields with sources',
      () {
        final preview = _service().previewFromString(
          'Artwork Title,Creator,Date Created,Materials,Measurements,'
          'Purchase Price,Purchase Date,Seller/Gallery,Room,Insurance Value,'
          'Condition,Notes\n'
          'Harbor Study,J. Solberg,1998,Oil on canvas,40 x 50 cm,'
          '"USD 1,200.50",2021-05-14,North Gallery,Studio,NOK 12000,'
          'Good,Receipt says framing was included.\n',
        );

        final row = preview.rows.single;
        final record = row.record!;

        expect(row.isImportable, isTrue);
        expect(record.recordState, ArtworkRecordState.needsReview);
        expect(record.field(ArtworkFieldKeys.title)?.value, 'Harbor Study');
        expect(record.field(ArtworkFieldKeys.artist)?.value, 'J. Solberg');
        expect(record.field(ArtworkFieldKeys.year)?.value, '1998');
        expect(record.field(ArtworkFieldKeys.medium)?.value, 'Oil on canvas');
        expect(record.field(ArtworkFieldKeys.dimensions)?.value, '40 x 50 cm');
        expect(
          record.field(ArtworkFieldKeys.purchaseDate)?.value,
          '2021-05-14',
        );
        expect(
          record.field(ArtworkFieldKeys.sellerOrGallery)?.value,
          'North Gallery',
        );
        expect(record.field(ArtworkFieldKeys.currentLocation)?.value, 'Studio');
        expect(record.field(ArtworkFieldKeys.conditionNotes)?.value, 'Good');
        expect(
          record.field(ArtworkFieldKeys.purchasePrice)?.moneyAmount,
          '1200.50',
        );
        expect(
          record.field(ArtworkFieldKeys.purchasePrice)?.moneyCurrencyCode,
          'USD',
        );
        expect(
          record.field(ArtworkFieldKeys.insuranceValue)?.moneyAmount,
          '12000',
        );
        expect(
          record.field(ArtworkFieldKeys.insuranceValue)?.moneyCurrencyCode,
          'NOK',
        );
        expect(record.fields.values.map((field) => field.source).toSet(), {
          ArtworkFieldSource.documentExtracted,
          ArtworkFieldSource.unknown,
        });
        expect(
          record.field(ArtworkFieldKeys.notes)?.source,
          ArtworkFieldSource.unknown,
        );
      },
    );

    test(
      'appends unknown and reference columns to notes without attachments',
      () {
        final preview = _service().previewFromString(
          'Title,Inventory Code,Photo,Document URL,Reference Link,Notes\n'
          'Chair,INV-7,chair.jpg,receipt.pdf,https://example.test/ref,'
          'Original owner note\n',
        );

        final notes = preview.rows.single.record!
            .field(ArtworkFieldKeys.notes)!
            .value;

        expect(notes, contains('Original owner note'));
        expect(notes, contains('Imported unmapped fields:'));
        expect(notes, contains('- Inventory Code: INV-7'));
        expect(notes, contains('Unresolved imported references:'));
        expect(notes, contains('- Photo: chair.jpg'));
        expect(notes, contains('- Document URL: receipt.pdf'));
        expect(notes, contains('- Reference Link: https://example.test/ref'));
        expect(preview.rows.single.record!.primaryImageAttachmentId, isNull);
      },
    );

    test('preserves row cells beyond headers as unmapped notes', () {
      final preview = _service().previewFromString(
        'Title,Notes\n'
        'Work,note,extra,https://example.test/reference\n',
      );

      final row = preview.rows.single;
      final notes = row.record!.field(ArtworkFieldKeys.notes)!.value;

      expect(row.isImportable, isTrue);
      expect(
        row.warnings,
        contains(
          'This row has more cells than headings, so the extra details were kept in notes.',
        ),
      );
      expect(row.rawValues['Unmapped column 3'], 'extra');
      expect(
        row.rawValues['Unmapped column 4'],
        'https://example.test/reference',
      );
      expect(notes, contains('note'));
      expect(notes, contains('Imported unmapped fields:'));
      expect(notes, contains('- Unmapped column 3: extra'));
      expect(
        notes,
        contains('- Unmapped column 4: https://example.test/reference'),
      );
    });

    test(
      'rejects rows without title, artist, or notes-like identifying text',
      () {
        final preview = _service().previewFromString(
          'Year,Medium,Dimensions\n'
          '1998,Oil,40 x 50 cm\n',
        );

        expect(preview.rows.single.isImportable, isFalse);
        expect(preview.rows.single.record, isNull);
        expect(
          preview.rows.single.errors.single,
          contains('Add at least a title'),
        );
      },
    );

    test('warns on ambiguous year, money, date, and dimensions', () {
      final preview = _service().previewFromString(
        'Title,Year,Purchase Price,Purchase Date,Dimensions,Insurance Value\n'
        'Ambiguous work,c. 1900,"\$1,000-\$2,000",04/05/2020,about 40 x 50,'
        'around NOK 12000\n',
      );

      final row = preview.rows.single;

      expect(row.isImportable, isTrue);
      expect(
        row.warnings,
        contains('Year looks uncertain, so it was kept exactly as imported.'),
      );
      expect(
        row.warnings,
        contains(
          'Purchase price needs a closer look, so it was kept exactly as imported.',
        ),
      );
      expect(
        row.warnings,
        contains(
          'Purchase date looks uncertain, so it was kept exactly as imported.',
        ),
      );
      expect(
        row.warnings,
        contains(
          'Dimensions need a closer look, so they were kept exactly as imported.',
        ),
      );
      expect(
        row.warnings,
        contains(
          'Insurance value needs a closer look, so it was kept exactly as imported.',
        ),
      );
      expect(
        row.record!.field(ArtworkFieldKeys.purchasePrice)?.value,
        r'$1,000-$2,000',
      );
      expect(
        row.record!.field(ArtworkFieldKeys.purchasePrice)?.moneyAmount,
        isNull,
      );
    });

    test('reports duplicates against existing records and incoming rows', () {
      final existing = _record(
        'existing-001',
        title: 'Blue Interior',
        artist: 'A. Maker',
      );
      final preview = _service().previewFromString(
        'Title,Artist,Year,Dimensions\n'
        'Blue Interior,A. Maker,2020,40 x 50 cm\n'
        'Untitled,,2021,20 x 30 cm\n'
        'Untitled,,2021,20 x 30 cm\n',
        existingRecords: [existing],
      );

      expect(
        preview.rows.first.duplicateCandidates.single.existingArtworkId,
        'existing-001',
      );
      expect(
        preview.rows.first.duplicateCandidates.single.source,
        CsvArtworkDuplicateSource.existingRecord,
      );
      expect(preview.rows[2].duplicateCandidates.single.incomingRowNumber, 3);
      expect(
        preview.rows[2].duplicateCandidates.single.source,
        CsvArtworkDuplicateSource.incomingRow,
      );
    });

    test('honors explicit header mapping overrides', () {
      final preview = _service().previewFromString(
        'Work Name,Creator,Reference Link\n'
        'Blue Interior,A. Maker,https://example.test/ref\n',
        headerMappings: const [
          CsvArtworkColumnMapping.canonical(ArtworkFieldKeys.title),
          CsvArtworkColumnMapping.canonical(ArtworkFieldKeys.artist),
          CsvArtworkColumnMapping.skip(),
        ],
      );

      final row = preview.rows.single;
      expect(row.record!.field(ArtworkFieldKeys.title)?.value, 'Blue Interior');
      expect(row.record!.field(ArtworkFieldKeys.artist)?.value, 'A. Maker');
      expect(row.record!.field(ArtworkFieldKeys.notes), isNull);
      expect(preview.skippedColumns, ['Reference Link']);
    });
  });

  group('preview write boundary', () {
    late Directory tempDir;
    late LocalArtworkRepository repository;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'csv_artwork_import_test_',
      );
      repository = LocalArtworkRepository.forDatabase(
        await LocalArtworkRepository.openAt(p.join(tempDir.path, 'records.db')),
      );
    });

    tearDown(() async {
      await repository.close();
      await tempDir.delete(recursive: true);
    });

    test(
      'does not write preview records before explicit confirmation',
      () async {
        await repository.create(
          _record(
            'existing-001',
            title: 'Persisted Work',
            artist: 'Known Artist',
          ),
        );

        final before = await repository.list();
        final preview = _service().previewFromString(
          'Title,Artist,Notes\nImported Work,Importer,Preview only\n',
          existingRecords: before,
        );
        final after = await repository.list();

        expect(preview.importableRows, hasLength(1));
        expect(after.map((record) => record.id), ['existing-001']);
        expect(
          after.single.field(ArtworkFieldKeys.title)?.value,
          'Persisted Work',
        );
      },
    );

    test('does not write warning preview records before confirmation', () async {
      final preview = _service().previewFromString(
        'Title,Year,Purchase Price\nAmbiguous import,c. 1900,"\$1,000-\$2,000"\n',
        existingRecords: await repository.list(),
      );
      final after = await repository.list();

      expect(preview.importableRows, hasLength(1));
      expect(preview.rows.single.warnings, isNotEmpty);
      expect(after, isEmpty);
    });
  });
}

CsvArtworkImportService _service() {
  var id = 0;
  return CsvArtworkImportService(
    now: () => DateTime.utc(2026, 7, 5, 12),
    idFactory: () => (++id).toString().padLeft(3, '0'),
  );
}

ArtworkRecord _record(
  String id, {
  required String title,
  required String artist,
  String? year,
  String? dimensions,
}) {
  return ArtworkRecord(
    id: id,
    recordState: ArtworkRecordState.verifiedByYou,
    createdAt: DateTime.utc(2026, 7, 4),
    updatedAt: DateTime.utc(2026, 7, 4),
    fields: {
      ArtworkFieldKeys.title: ArtworkFieldValue(
        value: title,
        source: ArtworkFieldSource.userConfirmed,
        note: 'Fixture.',
      ),
      ArtworkFieldKeys.artist: ArtworkFieldValue(
        value: artist,
        source: ArtworkFieldSource.userConfirmed,
        note: 'Fixture.',
      ),
      if (year != null)
        ArtworkFieldKeys.year: ArtworkFieldValue(
          value: year,
          source: ArtworkFieldSource.userConfirmed,
          note: 'Fixture.',
        ),
      if (dimensions != null)
        ArtworkFieldKeys.dimensions: ArtworkFieldValue(
          value: dimensions,
          source: ArtworkFieldSource.userConfirmed,
          note: 'Fixture.',
        ),
    },
  );
}
