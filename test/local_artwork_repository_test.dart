import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/storage/artwork_collection_query.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/attachment_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDir;
  late String databasePath;
  late LocalArtworkRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('my_art_collection_test_');
    databasePath = p.join(tempDir.path, 'records.db');
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(databasePath),
    );
  });

  tearDown(() async {
    await repository.close();
    await tempDir.delete(recursive: true);
  });

  Future<ArtworkRecord?> reloadAndGet(String id) async {
    await repository.close();
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(databasePath),
    );
    return repository.get(id);
  }

  test('creates and reloads artwork records with source labels', () async {
    final createdAt = DateTime.utc(2026, 7, 4, 8);
    final updatedAt = DateTime.utc(2026, 7, 4, 8, 5);

    await repository.create(
      ArtworkRecord(
        id: 'artwork-001',
        recordState: ArtworkRecordState.needsReview,
        createdAt: createdAt,
        updatedAt: updatedAt,
        primaryImageAttachmentId: 'attachment-primary',
        fields: {
          ArtworkFieldKeys.title: const ArtworkFieldValue(
            value: 'Blue Interior Study',
            source: ArtworkFieldSource.aiSuggested,
            note: 'Possible title from image notes. Please confirm.',
          ),
          ArtworkFieldKeys.artist: ArtworkFieldValue(
            value: 'J. Solberg',
            source: ArtworkFieldSource.userConfirmed,
            note: 'User confirmed.',
            lastConfirmedAt: DateTime.utc(2026, 7, 4, 8, 4),
          ),
          ArtworkFieldKeys.insuranceValue: const ArtworkFieldValue(
            value: 'USD 2,400',
            source: ArtworkFieldSource.userConfirmed,
            note: 'User entered a structured insurance value.',
            moneyAmount: '2400',
            moneyCurrencyCode: 'USD',
          ),
        },
      ),
    );

    final reloaded = await reloadAndGet('artwork-001');

    expect(reloaded, isNotNull);
    expect(reloaded!.recordState, ArtworkRecordState.needsReview);
    expect(reloaded.lifecycleStatus, ArtworkLifecycleStatus.active);
    expect(reloaded.primaryImageAttachmentId, 'attachment-primary');
    expect(
      reloaded.field(ArtworkFieldKeys.title)?.source,
      ArtworkFieldSource.aiSuggested,
    );
    expect(
      reloaded.field(ArtworkFieldKeys.title)?.source.label,
      'AI-suggested',
    );
    expect(
      reloaded.field(ArtworkFieldKeys.artist)?.source,
      ArtworkFieldSource.userConfirmed,
    );
    expect(
      reloaded.field(ArtworkFieldKeys.artist)?.source.label,
      'user-confirmed',
    );
    expect(
      reloaded.field(ArtworkFieldKeys.artist)?.lastConfirmedAt,
      DateTime.utc(2026, 7, 4, 8, 4).toLocal(),
    );
    expect(
      reloaded.field(ArtworkFieldKeys.insuranceValue)?.moneyAmount,
      '2400',
    );
    expect(
      reloaded.field(ArtworkFieldKeys.insuranceValue)?.moneyCurrencyCode,
      'USD',
    );

    final rawDatabase = await databaseFactoryFfi.openDatabase(databasePath);
    addTearDown(rawDatabase.close);

    final sourceRows = await rawDatabase.query(
      'artwork_fields',
      columns: [
        'field_key',
        'source_state',
        'money_amount',
        'money_currency_code',
      ],
      where: 'artwork_id = ?',
      whereArgs: ['artwork-001'],
      orderBy: 'field_key ASC',
    );

    expect(sourceRows, [
      {
        'field_key': ArtworkFieldKeys.artist,
        'source_state': 'user-confirmed',
        'money_amount': null,
        'money_currency_code': null,
      },
      {
        'field_key': ArtworkFieldKeys.insuranceValue,
        'source_state': 'user-confirmed',
        'money_amount': '2400',
        'money_currency_code': 'USD',
      },
      {
        'field_key': ArtworkFieldKeys.title,
        'source_state': 'AI-suggested',
        'money_amount': null,
        'money_currency_code': null,
      },
    ]);
  });

  test('updates, lists, and deletes artwork records', () async {
    final original = _record('artwork-001', title: 'Untitled harbor');
    await repository.create(original);

    final updated = original.copyWith(
      recordState: ArtworkRecordState.verifiedByYou,
      updatedAt: DateTime.utc(2026, 7, 4, 9),
      fields: {
        ...original.fields,
        ArtworkFieldKeys.title: ArtworkFieldValue(
          value: 'Harbor at dusk',
          source: ArtworkFieldSource.userConfirmed,
          note: 'User confirmed from draft review.',
          lastConfirmedAt: DateTime.utc(2026, 7, 4, 9),
        ),
      },
    );

    await repository.upsert(updated);
    await repository.close();
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(databasePath),
    );

    final listed = await repository.list();
    expect(listed, hasLength(1));
    expect(listed.single.recordState, ArtworkRecordState.verifiedByYou);
    expect(listed.single.lifecycleStatus, ArtworkLifecycleStatus.active);
    expect(
      listed.single.field(ArtworkFieldKeys.title)?.value,
      'Harbor at dusk',
    );
    expect(
      listed.single.field(ArtworkFieldKeys.title)?.source,
      ArtworkFieldSource.userConfirmed,
    );

    await repository.delete('artwork-001');

    expect(await repository.get('artwork-001'), isNull);
    expect(await repository.list(), isEmpty);
  });

  test('persists an edition envelope through a version 7 reopen', () async {
    final confirmedAt = DateTime.utc(2026, 7, 11, 10, 30);
    await repository.create(
      ArtworkRecord(
        id: 'edition-v7',
        recordState: ArtworkRecordState.needsReview,
        createdAt: confirmedAt,
        updatedAt: confirmedAt,
        fields: {
          ArtworkFieldKeys.edition: ArtworkFieldValue(
            value: '12/75',
            source: ArtworkFieldSource.userConfirmed,
            note: 'Saved as part of your confirmed record.',
            lastConfirmedAt: confirmedAt,
          ),
        },
      ),
    );

    final reloaded = await reloadAndGet('edition-v7');

    expect(reloaded?.field(ArtworkFieldKeys.edition)?.value, '12/75');
    expect(
      reloaded?.field(ArtworkFieldKeys.edition)?.source,
      ArtworkFieldSource.userConfirmed,
    );
    expect(
      reloaded?.field(ArtworkFieldKeys.edition)?.note,
      'Saved as part of your confirmed record.',
    );
    expect(
      reloaded?.field(ArtworkFieldKeys.edition)?.lastConfirmedAt,
      confirmedAt.toLocal(),
    );
  });

  test('create is insert-only and leaves existing records unchanged', () async {
    await repository.create(_record('artwork-001', title: 'Original title'));

    await expectLater(
      repository.create(_record('artwork-001', title: 'Replacement title')),
      throwsA(isA<LocalArtworkInsertConflictException>()),
    );

    final reloaded = await repository.get('artwork-001');
    expect(reloaded!.field(ArtworkFieldKeys.title)?.value, 'Original title');
  });

  test('createAll inserts a batch successfully', () async {
    await repository.createAll([
      _record('artwork-001', title: 'First imported work'),
      _record('artwork-002', title: 'Second imported work'),
    ]);

    final records = await repository.list();

    expect(records, hasLength(2));
    expect(
      records.map((record) => record.field(ArtworkFieldKeys.title)?.value),
      unorderedEquals(['First imported work', 'Second imported work']),
    );
  });

  test('createAll rejects repeated batch ids without writing', () async {
    await expectLater(
      repository.createAll([
        _record('artwork-001', title: 'First imported work'),
        _record('artwork-001', title: 'Repeated imported work'),
      ]),
      throwsA(isA<LocalArtworkInsertConflictException>()),
    );

    expect(await repository.list(), isEmpty);
  });

  test(
    'createAll rejects existing id collisions without changing records',
    () async {
      await repository.create(_record('artwork-001', title: 'Original title'));

      await expectLater(
        repository.createAll([
          _record('artwork-002', title: 'New imported work'),
          _record('artwork-001', title: 'Colliding imported work'),
        ]),
        throwsA(isA<LocalArtworkInsertConflictException>()),
      );

      final records = await repository.list();

      expect(records, hasLength(1));
      expect(records.single.id, 'artwork-001');
      expect(
        records.single.field(ArtworkFieldKeys.title)?.value,
        'Original title',
      );
    },
  );

  test('createAll rolls back when a later insert fails', () async {
    await repository.close();
    final rawDatabase = await databaseFactoryFfi.openDatabase(databasePath);
    await rawDatabase.execute('''
      CREATE TRIGGER fail_imported_artwork
      BEFORE INSERT ON artworks
      WHEN NEW.artwork_id = 'artwork-fails'
      BEGIN
        SELECT RAISE(ABORT, 'injected batch failure');
      END
    ''');
    await rawDatabase.close();
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(databasePath),
    );

    await expectLater(
      repository.createAll([
        _record('artwork-001', title: 'First imported work'),
        _record('artwork-fails', title: 'Failing imported work'),
      ]),
      throwsA(isA<Exception>()),
    );

    expect(await repository.list(), isEmpty);
  });

  test(
    'round-trips canonical import fields and existing money metadata',
    () async {
      final createdAt = DateTime.utc(2026, 7, 4, 8);
      final updatedAt = DateTime.utc(2026, 7, 4, 8, 15);

      await repository.create(
        ArtworkRecord(
          id: 'imported-artwork-001',
          recordState: ArtworkRecordState.needsReview,
          createdAt: createdAt,
          updatedAt: updatedAt,
          fields: {
            ArtworkFieldKeys.title: const ArtworkFieldValue(
              value: 'Imported receipt artwork',
              source: ArtworkFieldSource.documentExtracted,
              note: 'Imported from document title text.',
            ),
            ArtworkFieldKeys.artist: const ArtworkFieldValue(
              value: 'Unknown',
              source: ArtworkFieldSource.unknown,
              note: 'Imported data did not identify the artist.',
            ),
            ArtworkFieldKeys.year: const ArtworkFieldValue(
              value: '1998',
              source: ArtworkFieldSource.documentExtracted,
              note: 'Imported from dated gallery paperwork.',
            ),
            ArtworkFieldKeys.purchaseDate: const ArtworkFieldValue(
              value: '2021-05-14',
              source: ArtworkFieldSource.documentExtracted,
              note: 'Imported from receipt date.',
            ),
            ArtworkFieldKeys.sellerOrGallery: const ArtworkFieldValue(
              value: 'North Gallery',
              source: ArtworkFieldSource.documentExtracted,
              note: 'Imported from receipt seller line.',
            ),
            ArtworkFieldKeys.notes: const ArtworkFieldValue(
              value: 'Receipt says framing was included.',
              source: ArtworkFieldSource.unknown,
              note: 'Imported notes need review before confirmation.',
            ),
            ArtworkFieldKeys.purchasePrice: const ArtworkFieldValue(
              value: 'USD 1,200.50',
              source: ArtworkFieldSource.documentExtracted,
              note: 'Imported receipt total.',
              moneyAmount: '1200.50',
              moneyCurrencyCode: 'USD',
            ),
            ArtworkFieldKeys.insuranceValue: const ArtworkFieldValue(
              value: 'NOK 12,000',
              source: ArtworkFieldSource.unknown,
              note: 'Imported archive value needs review.',
              moneyAmount: '12000',
              moneyCurrencyCode: 'NOK',
            ),
          },
        ),
      );

      final reloaded = await reloadAndGet('imported-artwork-001');

      expect(reloaded, isNotNull);
      expect(reloaded!.field(ArtworkFieldKeys.year)?.value, '1998');
      expect(
        reloaded.field(ArtworkFieldKeys.year)?.source,
        ArtworkFieldSource.documentExtracted,
      );
      expect(
        reloaded.field(ArtworkFieldKeys.purchaseDate)?.value,
        '2021-05-14',
      );
      expect(
        reloaded.field(ArtworkFieldKeys.purchaseDate)?.source,
        ArtworkFieldSource.documentExtracted,
      );
      expect(
        reloaded.field(ArtworkFieldKeys.sellerOrGallery)?.value,
        'North Gallery',
      );
      expect(
        reloaded.field(ArtworkFieldKeys.sellerOrGallery)?.source,
        ArtworkFieldSource.documentExtracted,
      );
      expect(
        reloaded.field(ArtworkFieldKeys.notes)?.value,
        'Receipt says framing was included.',
      );
      expect(
        reloaded.field(ArtworkFieldKeys.notes)?.source,
        ArtworkFieldSource.unknown,
      );
      expect(
        reloaded.field(ArtworkFieldKeys.purchasePrice)?.moneyAmount,
        '1200.50',
      );
      expect(
        reloaded.field(ArtworkFieldKeys.purchasePrice)?.moneyCurrencyCode,
        'USD',
      );
      expect(
        reloaded.field(ArtworkFieldKeys.insuranceValue)?.moneyAmount,
        '12000',
      );
      expect(
        reloaded.field(ArtworkFieldKeys.insuranceValue)?.moneyCurrencyCode,
        'NOK',
      );
    },
  );

  test('persists lifecycle status changes across repository reloads', () async {
    final original = _record('artwork-lifecycle', title: 'Lifecycle artwork');
    await repository.create(original);

    for (final status in [
      ArtworkLifecycleStatus.sold,
      ArtworkLifecycleStatus.lost,
      ArtworkLifecycleStatus.stolen,
      ArtworkLifecycleStatus.removed,
      ArtworkLifecycleStatus.active,
    ]) {
      final current = await repository.get('artwork-lifecycle');
      await repository.upsert(
        current!.copyWith(
          lifecycleStatus: status,
          updatedAt: DateTime.utc(2026, 7, 4, 10),
        ),
      );

      final reloaded = await reloadAndGet('artwork-lifecycle');
      expect(reloaded, isNotNull);
      expect(reloaded!.lifecycleStatus, status);
      expect(
        reloaded.field(ArtworkFieldKeys.title)?.value,
        'Lifecycle artwork',
      );
    }
  });

  test('upgrades v1 databases without losing artwork records', () async {
    await repository.close();
    await databaseFactoryFfi.deleteDatabase(databasePath);

    final legacyDatabase = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(version: 1, onCreate: _createV1Schema),
    );

    await legacyDatabase.insert('artworks', {
      'artwork_id': 'legacy-artwork-001',
      'record_state': 'needsReview',
      'primary_image_attachment_id': null,
      'created_at': DateTime.utc(2026, 7, 4, 8).toIso8601String(),
      'updated_at': DateTime.utc(2026, 7, 4, 8, 5).toIso8601String(),
    });
    await legacyDatabase.insert('artwork_fields', {
      'artwork_id': 'legacy-artwork-001',
      'field_key': ArtworkFieldKeys.title,
      'value': 'Legacy Interior Study',
      'source_state': 'AI-suggested',
      'source_note': 'Seeded by the v1 schema.',
      'last_confirmed_at': null,
    });
    await legacyDatabase.close();

    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(databasePath),
    );

    final reloaded = await repository.get('legacy-artwork-001');
    expect(reloaded, isNotNull);
    expect(reloaded!.recordState, ArtworkRecordState.needsReview);
    expect(reloaded.lifecycleStatus, ArtworkLifecycleStatus.active);
    expect(
      reloaded.field(ArtworkFieldKeys.title)?.value,
      'Legacy Interior Study',
    );
    expect(
      reloaded.field(ArtworkFieldKeys.title)?.source,
      ArtworkFieldSource.aiSuggested,
    );

    final rawDatabase = await databaseFactoryFfi.openDatabase(databasePath);
    addTearDown(rawDatabase.close);

    final attachmentTables = await rawDatabase.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      ['attachments'],
    );
    expect(attachmentTables, hasLength(1));

    final artworkRows = await rawDatabase.query(
      'artworks',
      columns: ['lifecycle_status'],
      where: 'artwork_id = ?',
      whereArgs: ['legacy-artwork-001'],
    );
    expect(artworkRows.single['lifecycle_status'], 'active');
  });

  test('upgrades v3 databases with active lifecycle defaults', () async {
    await repository.close();
    await databaseFactoryFfi.deleteDatabase(databasePath);

    final legacyDatabase = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(version: 3, onCreate: _createV3Schema),
    );

    await legacyDatabase.insert('artworks', {
      'artwork_id': 'legacy-v3-artwork',
      'record_state': 'verifiedByYou',
      'primary_image_attachment_id': null,
      'created_at': DateTime.utc(2026, 7, 4, 8).toIso8601String(),
      'updated_at': DateTime.utc(2026, 7, 4, 8, 5).toIso8601String(),
    });
    await legacyDatabase.insert('artwork_fields', {
      'artwork_id': 'legacy-v3-artwork',
      'field_key': ArtworkFieldKeys.title,
      'value': 'Legacy V3 Artwork',
      'source_state': 'user-confirmed',
      'source_note': 'Seeded by the v3 schema.',
      'last_confirmed_at': DateTime.utc(2026, 7, 4, 8).toIso8601String(),
    });
    await legacyDatabase.close();

    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(databasePath),
    );

    final reloaded = await repository.get('legacy-v3-artwork');
    expect(reloaded, isNotNull);
    expect(reloaded!.recordState, ArtworkRecordState.verifiedByYou);
    expect(reloaded.lifecycleStatus, ArtworkLifecycleStatus.active);
    expect(reloaded.field(ArtworkFieldKeys.title)?.value, 'Legacy V3 Artwork');
  });

  test(
    'upgrades v4 databases without rewriting legacy free-form money text',
    () async {
      await repository.close();
      await databaseFactoryFfi.deleteDatabase(databasePath);

      final legacyDatabase = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(version: 4, onCreate: _createV4Schema),
      );

      await legacyDatabase.insert('artworks', {
        'artwork_id': 'legacy-v4-artwork',
        'record_state': 'verifiedByYou',
        'lifecycle_status': 'active',
        'primary_image_attachment_id': null,
        'created_at': DateTime.utc(2026, 7, 4, 8).toIso8601String(),
        'updated_at': DateTime.utc(2026, 7, 4, 8, 5).toIso8601String(),
      });
      await legacyDatabase.insert('artwork_fields', {
        'artwork_id': 'legacy-v4-artwork',
        'field_key': ArtworkFieldKeys.insuranceValue,
        'value': 'about twelve thousand, appraisal pending',
        'source_state': 'user-confirmed',
        'source_note': 'Legacy text should stay untouched.',
        'last_confirmed_at': DateTime.utc(2026, 7, 4, 8).toIso8601String(),
      });
      await legacyDatabase.close();

      repository = LocalArtworkRepository.forDatabase(
        await LocalArtworkRepository.openAt(databasePath),
      );

      final reloaded = await repository.get('legacy-v4-artwork');
      expect(reloaded, isNotNull);
      expect(
        reloaded!.field(ArtworkFieldKeys.insuranceValue)?.value,
        'about twelve thousand, appraisal pending',
      );
      expect(
        reloaded.field(ArtworkFieldKeys.insuranceValue)?.moneyAmount,
        isNull,
      );
      expect(
        reloaded.field(ArtworkFieldKeys.insuranceValue)?.moneyCurrencyCode,
        isNull,
      );

      final rawDatabase = await databaseFactoryFfi.openDatabase(databasePath);
      addTearDown(rawDatabase.close);
      final moneyColumns = await rawDatabase.query(
        'artwork_fields',
        columns: ['money_amount', 'money_currency_code'],
        where: 'artwork_id = ? AND field_key = ?',
        whereArgs: ['legacy-v4-artwork', ArtworkFieldKeys.insuranceValue],
      );
      expect(moneyColumns.single['money_amount'], isNull);
      expect(moneyColumns.single['money_currency_code'], isNull);
    },
  );

  test(
    'upgrades v5 attachment rows with role backfill from primary image pointer',
    () async {
      await repository.close();
      await databaseFactoryFfi.deleteDatabase(databasePath);

      final legacyDatabase = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(version: 5, onCreate: _createV5Schema),
      );

      await legacyDatabase.insert('artworks', {
        'artwork_id': 'legacy-v5-artwork',
        'record_state': 'verifiedByYou',
        'lifecycle_status': 'active',
        'primary_image_attachment_id': 'legacy-primary-photo',
        'created_at': DateTime.utc(2026, 7, 4, 8).toIso8601String(),
        'updated_at': DateTime.utc(2026, 7, 4, 8, 5).toIso8601String(),
      });
      await legacyDatabase.insert(
        'attachments',
        _legacyAttachmentRow(
          id: 'legacy-primary-photo',
          artworkId: 'legacy-v5-artwork',
          type: 'photo',
          fileName: 'primary.jpg',
          mimeType: 'image/jpeg',
          importedAt: DateTime.utc(2026, 7, 4, 8),
        ),
      );
      await legacyDatabase.insert(
        'attachments',
        _legacyAttachmentRow(
          id: 'legacy-supporting-photo',
          artworkId: 'legacy-v5-artwork',
          type: 'photo',
          fileName: 'condition.png',
          mimeType: 'image/png',
          importedAt: DateTime.utc(2026, 7, 4, 8, 1),
        ),
      );
      await legacyDatabase.insert(
        'attachments',
        _legacyAttachmentRow(
          id: 'legacy-receipt',
          artworkId: 'legacy-v5-artwork',
          type: 'receipt',
          fileName: 'receipt.pdf',
          mimeType: 'application/pdf',
          importedAt: DateTime.utc(2026, 7, 4, 8, 2),
        ),
      );
      await legacyDatabase.close();

      repository = LocalArtworkRepository.forDatabase(
        await LocalArtworkRepository.openAt(databasePath),
      );

      final reloaded = await repository.get('legacy-v5-artwork');
      expect(reloaded!.primaryImageAttachmentId, 'legacy-primary-photo');

      final attachments = await repository.attachmentsForArtwork(
        'legacy-v5-artwork',
      );
      expect(
        attachments
            .singleWhere(
              (attachment) => attachment.id == 'legacy-primary-photo',
            )
            .role,
        AttachmentRole.primaryArtworkPhoto,
      );
      expect(
        attachments
            .singleWhere(
              (attachment) => attachment.id == 'legacy-supporting-photo',
            )
            .role,
        AttachmentRole.supportingPhoto,
      );
      expect(
        attachments
            .singleWhere((attachment) => attachment.id == 'legacy-receipt')
            .role,
        AttachmentRole.supportingDocument,
      );

      final rawDatabase = await databaseFactoryFfi.openDatabase(databasePath);
      addTearDown(rawDatabase.close);
      final roleColumns = await rawDatabase.rawQuery(
        'PRAGMA table_info(attachments)',
      );
      expect(
        roleColumns.map((column) => column['name']),
        contains('attachment_role'),
      );
    },
  );

  test(
    'upgrades v6 attachment rows with additive derivative provenance columns',
    () async {
      await repository.close();
      await databaseFactoryFfi.deleteDatabase(databasePath);

      final legacyDatabase = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(version: 6, onCreate: _createV6Schema),
      );

      await legacyDatabase.insert('artworks', {
        'artwork_id': 'legacy-v6-artwork',
        'record_state': 'verifiedByYou',
        'lifecycle_status': 'active',
        'primary_image_attachment_id': 'legacy-primary-photo',
        'created_at': DateTime.utc(2026, 7, 4, 8).toIso8601String(),
        'updated_at': DateTime.utc(2026, 7, 4, 8, 5).toIso8601String(),
      });
      await legacyDatabase.insert(
        'attachments',
        _legacyAttachmentRow(
          id: 'legacy-primary-photo',
          artworkId: 'legacy-v6-artwork',
          type: 'photo',
          fileName: 'primary.jpg',
          mimeType: 'image/jpeg',
          importedAt: DateTime.utc(2026, 7, 4, 8),
          attachmentRole: 'primary_artwork_photo',
        ),
      );
      await legacyDatabase.insert(
        'attachments',
        _legacyAttachmentRow(
          id: 'legacy-supporting-photo',
          artworkId: 'legacy-v6-artwork',
          type: 'photo',
          fileName: 'detail.jpg',
          mimeType: 'image/jpeg',
          importedAt: DateTime.utc(2026, 7, 4, 8, 1),
          attachmentRole: 'supporting_photo',
        ),
      );
      await legacyDatabase.close();

      repository = LocalArtworkRepository.forDatabase(
        await LocalArtworkRepository.openAt(databasePath),
      );

      final attachments = await repository.attachmentsForArtwork(
        'legacy-v6-artwork',
      );
      expect(attachments, hasLength(2));
      expect(
        attachments
            .singleWhere(
              (attachment) => attachment.id == 'legacy-primary-photo',
            )
            .derivedFromAttachmentId,
        isNull,
      );
      expect(
        attachments
            .singleWhere(
              (attachment) => attachment.id == 'legacy-supporting-photo',
            )
            .transformSummary,
        isNull,
      );

      final rawDatabase = await databaseFactoryFfi.openDatabase(databasePath);
      addTearDown(rawDatabase.close);
      final columnInfo = await rawDatabase.rawQuery(
        'PRAGMA table_info(attachments)',
      );
      expect(
        columnInfo.map((column) => column['name']),
        containsAll(['derived_from_attachment_id', 'transform_summary']),
      );
    },
  );

  test('upgrades v7 attachment rows with active lifecycle defaults', () async {
    await repository.close();
    await databaseFactoryFfi.deleteDatabase(databasePath);

    final legacyDatabase = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(version: 7, onCreate: _createV7Schema),
    );
    await legacyDatabase.insert('artworks', {
      'artwork_id': 'legacy-v7-artwork',
      'record_state': 'verifiedByYou',
      'lifecycle_status': 'active',
      'primary_image_attachment_id': null,
      'created_at': DateTime.utc(2026, 7, 4, 8).toIso8601String(),
      'updated_at': DateTime.utc(2026, 7, 4, 8, 5).toIso8601String(),
    });
    await legacyDatabase.insert(
      'attachments',
      _legacyAttachmentRow(
        id: 'legacy-v7-receipt',
        artworkId: 'legacy-v7-artwork',
        type: 'receipt',
        fileName: 'receipt.pdf',
        mimeType: 'application/pdf',
        importedAt: DateTime.utc(2026, 7, 4, 8),
        attachmentRole: 'supporting_document',
      ),
    );
    await legacyDatabase.close();

    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(databasePath),
    );

    final attachment = await repository.getAttachment('legacy-v7-receipt');
    expect(attachment!.lifecycleStatus, AttachmentLifecycleStatus.active);
    expect(attachment.lifecycleUpdatedAt, isNull);
    expect(attachment.supersededByAttachmentId, isNull);

    final rawDatabase = await databaseFactoryFfi.openDatabase(databasePath);
    addTearDown(rawDatabase.close);
    final columnInfo = await rawDatabase.rawQuery(
      'PRAGMA table_info(attachments)',
    );
    expect(
      columnInfo.map((column) => column['name']),
      containsAll([
        'lifecycle_status',
        'lifecycle_updated_at',
        'superseded_by_attachment_id',
      ]),
    );
  });

  test('rejects derivative attachments with missing sources', () async {
    final derivative = _attachment(
      id: 'attachment-derivative',
      artworkId: 'artwork-001',
      derivedFromAttachmentId: 'attachment-missing',
      transformSummary: 'crop=4:3',
      importedAt: DateTime.utc(2026, 7, 4, 10),
    );

    await expectLater(
      repository.addAttachment(derivative),
      throwsA(
        isA<AttachmentLineageException>().having(
          (error) => error.failure,
          'failure',
          AttachmentLineageFailure.missingSource,
        ),
      ),
    );
  });

  test('rejects derivative attachments that point across artworks', () async {
    await repository.create(_record('artwork-002', title: 'Secondary artwork'));
    await repository.addAttachment(
      _attachment(
        id: 'attachment-source',
        artworkId: 'artwork-002',
        importedAt: DateTime.utc(2026, 7, 4, 9),
      ),
    );

    final derivative = _attachment(
      id: 'attachment-derivative',
      artworkId: 'artwork-001',
      derivedFromAttachmentId: 'attachment-source',
      transformSummary: 'rotate=90deg',
      importedAt: DateTime.utc(2026, 7, 4, 10),
    );

    await expectLater(
      repository.addAttachment(derivative),
      throwsA(
        isA<AttachmentLineageException>().having(
          (error) => error.failure,
          'failure',
          AttachmentLineageFailure.crossArtworkSource,
        ),
      ),
    );
  });

  test('collection query composes search and operational filters', () async {
    await repository.createAll([
      _queryRecord(
        'title-match',
        title: '  Harbor NEEDLE  ',
        artist: 'Elsewhere',
        notes: 'Quiet note',
        location: 'Main Hall',
        state: ArtworkRecordState.missingDocuments,
      ),
      _queryRecord(
        'artist-match',
        title: 'Portrait',
        artist: 'Needle Studio',
        notes: 'Quiet note',
        location: 'Main Hall',
        state: ArtworkRecordState.missingDocuments,
      ),
      _queryRecord(
        'notes-match',
        title: 'Landscape',
        artist: 'Elsewhere',
        notes: 'Contains needle in collector notes',
        location: 'Main Hall',
        state: ArtworkRecordState.missingDocuments,
      ),
      _queryRecord(
        'wrong-location',
        title: 'Needle work',
        artist: 'Elsewhere',
        notes: '',
        location: 'Storage',
        state: ArtworkRecordState.missingDocuments,
      ),
      _queryRecord(
        'historical',
        title: 'Needle archive',
        artist: 'Elsewhere',
        notes: '',
        location: 'Main Hall',
        state: ArtworkRecordState.missingDocuments,
        lifecycle: ArtworkLifecycleStatus.sold,
      ),
    ]);

    final snapshot = await repository.queryCollection(
      query: const ArtworkCollectionQuery(
        searchTerm: '  nEeDlE ',
        locations: {'main hall'},
        recordStates: {ArtworkRecordState.missingDocuments},
        lifecycleStatuses: {ArtworkLifecycleStatus.active},
        missingSupportingRecords: true,
        sort: ArtworkCollectionSort.title,
      ),
    );

    expect(snapshot.entries.map((entry) => entry.record.id), [
      'title-match',
      'notes-match',
      'artist-match',
    ]);
    expect(snapshot.totalRecordCount, 5);
    expect(snapshot.activeRecordCount, 4);
    expect(snapshot.availableLocations, ['Main Hall', 'Storage']);

    final historical = await repository.queryCollection(
      query: const ArtworkCollectionQuery(
        lifecycleStatuses: {ArtworkLifecycleStatus.sold},
      ),
    );
    expect(historical.entries.single.record.id, 'historical');
  });

  test('missing supporting records uses the exact shared predicate', () async {
    await repository.createAll([
      _queryRecord(
        'matches',
        title: 'Matches',
        state: ArtworkRecordState.missingDocuments,
      ),
      _queryRecord(
        'absence-alone',
        title: 'Absence alone',
        state: ArtworkRecordState.verifiedByYou,
      ),
      _queryRecord(
        'primary-only',
        title: 'Primary only',
        state: ArtworkRecordState.missingDocuments,
      ),
      _queryRecord(
        'supporting-photo',
        title: 'Supporting photo',
        state: ArtworkRecordState.missingDocuments,
      ),
      _queryRecord(
        'supporting-document',
        title: 'Supporting document',
        state: ArtworkRecordState.missingDocuments,
      ),
      for (final lifecycle in ArtworkLifecycleStatus.values.where(
        (status) => status != ArtworkLifecycleStatus.active,
      ))
        _queryRecord(
          'non-active-${lifecycle.storageValue}',
          title: lifecycle.label,
          state: ArtworkRecordState.missingDocuments,
          lifecycle: lifecycle,
        ),
    ]);
    await repository.addAttachment(
      _queryAttachment(
        id: 'primary',
        artworkId: 'primary-only',
        role: AttachmentRole.primaryArtworkPhoto,
      ),
    );
    await repository.addAttachment(
      _queryAttachment(
        id: 'supporting-photo-attachment',
        artworkId: 'supporting-photo',
        role: AttachmentRole.supportingPhoto,
      ),
    );
    await repository.addAttachment(
      _queryAttachment(
        id: 'supporting-document-attachment',
        artworkId: 'supporting-document',
        role: AttachmentRole.supportingDocument,
        type: AttachmentType.receipt,
      ),
    );

    await repository.close();
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(databasePath),
    );
    final snapshot = await repository.queryCollection(
      query: const ArtworkCollectionQuery(missingSupportingRecords: true),
    );

    expect(snapshot.entries.map((entry) => entry.record.id), [
      'matches',
      'primary-only',
    ]);
    for (final entry in snapshot.entries) {
      expect(
        entry.isMissingSupportingRecords,
        hasMissingSupportingRecords(
          entry.record,
          supportingAttachmentCount: entry.supportingAttachmentCount,
        ),
      );
    }
  });

  test(
    'acquisition sort validates partial dates and leaves storage unchanged',
    () async {
      const dates = {
        'full-b': '2024-02-29',
        'full-a': '2024-02-29',
        'month': '2024-02',
        'year': '2024',
        'older': '2023-12-31',
        'invalid-day': '2023-02-29',
        'invalid-month': '2024-13',
        'free-form': 'Spring 2022',
        'blank': '   ',
      };
      await repository.createAll([
        for (final entry in dates.entries)
          _queryRecord(
            entry.key,
            title: entry.key.startsWith('full') ? 'Same title' : entry.key,
            acquisitionDate: entry.value,
          ),
      ]);
      await repository.close();
      repository = LocalArtworkRepository.forDatabase(
        await LocalArtworkRepository.openAt(databasePath),
      );

      final snapshot = await repository.queryCollection(
        query: const ArtworkCollectionQuery(
          sort: ArtworkCollectionSort.acquisitionDate,
        ),
      );
      expect(snapshot.entries.map((entry) => entry.record.id), [
        'full-a',
        'full-b',
        'month',
        'year',
        'older',
        'blank',
        'free-form',
        'invalid-day',
        'invalid-month',
      ]);
      expect({
        for (final entry in snapshot.entries)
          entry.record.id: entry.record
              .field(ArtworkFieldKeys.purchaseDate)
              ?.value,
      }, dates);
    },
  );

  test('text and recent sorts are stable with blanks and ties', () async {
    await repository.createAll([
      _queryRecord(
        'b',
        title: 'alpha',
        artist: 'Same',
        updatedAt: DateTime.utc(2026, 7, 4, 13),
      ),
      _queryRecord(
        'a',
        title: 'Alpha',
        artist: 'same',
        updatedAt: DateTime.utc(2026, 7, 4, 13),
      ),
      _queryRecord('blank-title', title: '  ', artist: 'Aardvark'),
      _queryRecord('blank-artist', title: 'Beta', artist: '  '),
    ]);

    Future<List<String>> idsFor(ArtworkCollectionSort sort) async {
      final snapshot = await repository.queryCollection(
        query: ArtworkCollectionQuery(sort: sort),
      );
      return snapshot.entries.map((entry) => entry.record.id).toList();
    }

    expect(await idsFor(ArtworkCollectionSort.title), [
      'a',
      'b',
      'blank-artist',
      'blank-title',
    ]);
    expect(await idsFor(ArtworkCollectionSort.artist), [
      'blank-title',
      'a',
      'b',
      'blank-artist',
    ]);
    expect((await idsFor(ArtworkCollectionSort.recentlyUpdated)).take(2), [
      'a',
      'b',
    ]);
  });

  for (final size in [50, 200]) {
    test('bulk snapshot hydrates a persisted $size-record dataset', () async {
      await repository.createAll([
        for (var index = 0; index < size; index += 1)
          _queryRecord(
            'record-${index.toString().padLeft(3, '0')}',
            title: 'Work ${index.toString().padLeft(3, '0')}',
            artist: index.isEven ? 'Even Artist' : 'Odd Artist',
            notes: index.isEven ? 'group-even' : 'group-odd',
            location: index % 3 == 0 ? 'Studio' : 'Archive',
            state: index.isEven
                ? ArtworkRecordState.missingDocuments
                : ArtworkRecordState.verifiedByYou,
          ),
      ]);
      for (var index = 0; index < size; index += 10) {
        await repository.addAttachment(
          _queryAttachment(
            id: 'support-$index',
            artworkId: 'record-${index.toString().padLeft(3, '0')}',
            role: AttachmentRole.supportingDocument,
            type: AttachmentType.receipt,
          ),
        );
      }

      await repository.close();
      final reads = <ArtworkCollectionSnapshotRead>[];
      repository = LocalArtworkRepository.forDatabase(
        await LocalArtworkRepository.openAt(databasePath),
        collectionSnapshotObserver: ArtworkCollectionSnapshotObserver(
          onRead: reads.add,
        ),
      );
      final snapshot = await repository.queryCollection(
        query: const ArtworkCollectionQuery(
          searchTerm: 'GROUP-EVEN',
          locations: {'studio'},
          recordStates: {ArtworkRecordState.missingDocuments},
          lifecycleStatuses: {ArtworkLifecycleStatus.active},
          missingSupportingRecords: true,
          sort: ArtworkCollectionSort.title,
        ),
      );

      final expectedIds = [
        for (var index = 0; index < size; index += 1)
          if (index.isEven && index % 3 == 0 && index % 10 != 0)
            'record-${index.toString().padLeft(3, '0')}',
      ];
      expect(snapshot.totalRecordCount, size);
      expect(snapshot.entries.map((entry) => entry.record.id), expectedIds);
      expect(
        snapshot.entries.every(
          (entry) =>
              entry.record.fields.length == 4 &&
              entry.supportingAttachmentCount == 0,
        ),
        isTrue,
      );
      expect(reads, ArtworkCollectionSnapshotRead.values);
    });
  }
}

ArtworkRecord _queryRecord(
  String id, {
  required String title,
  String artist = 'Artist',
  String notes = '',
  String location = 'Studio',
  String? acquisitionDate,
  ArtworkRecordState state = ArtworkRecordState.verifiedByYou,
  ArtworkLifecycleStatus lifecycle = ArtworkLifecycleStatus.active,
  DateTime? updatedAt,
}) {
  final now = updatedAt ?? DateTime.utc(2026, 7, 4, 12);
  return ArtworkRecord(
    id: id,
    recordState: state,
    lifecycleStatus: lifecycle,
    createdAt: now,
    updatedAt: now,
    fields: {
      for (final entry in {
        ArtworkFieldKeys.title: title,
        ArtworkFieldKeys.artist: artist,
        ArtworkFieldKeys.notes: notes,
        ArtworkFieldKeys.currentLocation: location,
        ArtworkFieldKeys.purchaseDate: ?acquisitionDate,
      }.entries)
        entry.key: ArtworkFieldValue(
          value: entry.value,
          source: ArtworkFieldSource.userConfirmed,
          note: 'User-entered query fixture.',
        ),
    },
  );
}

AttachmentRecord _queryAttachment({
  required String id,
  required String artworkId,
  required AttachmentRole role,
  AttachmentType type = AttachmentType.photo,
}) {
  return AttachmentRecord(
    id: id,
    artworkId: artworkId,
    type: type,
    role: role,
    fileName: '$id.bin',
    mimeType: type == AttachmentType.photo ? 'image/jpeg' : 'application/pdf',
    fileSizeBytes: 4,
    importedAt: DateTime.utc(2026, 7, 4, 12),
    source: ArtworkFieldSource.userConfirmed,
    relativePath: 'artworks/$artworkId/attachments/$id/payload',
    checksum: 'checksum-$id',
  );
}

ArtworkRecord _record(String id, {required String title}) {
  final now = DateTime.utc(2026, 7, 4, 8);

  return ArtworkRecord(
    id: id,
    recordState: ArtworkRecordState.draft,
    createdAt: now,
    updatedAt: now,
    fields: {
      ArtworkFieldKeys.title: ArtworkFieldValue(
        value: title,
        source: ArtworkFieldSource.aiSuggested,
        note: 'Possible title from image notes. Please confirm.',
      ),
      ArtworkFieldKeys.artist: const ArtworkFieldValue(
        value: 'Unknown',
        source: ArtworkFieldSource.unknown,
        note: 'Leave unknown or enter artist after review.',
      ),
    },
  );
}

AttachmentRecord _attachment({
  required String id,
  required String artworkId,
  required DateTime importedAt,
  String? derivedFromAttachmentId,
  String? transformSummary,
}) {
  return AttachmentRecord(
    id: id,
    artworkId: artworkId,
    type: AttachmentType.photo,
    fileName: '$id.jpg',
    mimeType: 'image/jpeg',
    fileSizeBytes: 3,
    importedAt: importedAt,
    source: ArtworkFieldSource.userConfirmed,
    relativePath: 'artworks/$artworkId/attachments/$id/payload.jpg',
    checksum: 'checksum-$id',
    derivedFromAttachmentId: derivedFromAttachmentId,
    transformSummary: transformSummary,
  );
}

Future<void> _createV1Schema(Database db, int version) async {
  await db.execute('''
    CREATE TABLE artworks (
      artwork_id TEXT PRIMARY KEY,
      record_state TEXT NOT NULL,
      primary_image_attachment_id TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE artwork_fields (
      artwork_id TEXT NOT NULL,
      field_key TEXT NOT NULL,
      value TEXT NOT NULL,
      source_state TEXT NOT NULL,
      source_note TEXT NOT NULL,
      last_confirmed_at TEXT,
      PRIMARY KEY (artwork_id, field_key),
      FOREIGN KEY (artwork_id)
        REFERENCES artworks (artwork_id)
        ON DELETE CASCADE
    )
  ''');

  await db.execute(
    'CREATE INDEX artwork_fields_artwork_idx ON artwork_fields (artwork_id)',
  );
}

Future<void> _createV3Schema(Database db, int version) async {
  await _createV1Schema(db, version);

  await db.execute('''
    CREATE TABLE attachments (
      attachment_id TEXT PRIMARY KEY,
      artwork_id TEXT NOT NULL,
      attachment_type TEXT NOT NULL,
      file_name TEXT NOT NULL,
      mime_type TEXT NOT NULL,
      file_size_bytes INTEGER NOT NULL,
      imported_at TEXT NOT NULL,
      captured_at TEXT,
      source_state TEXT NOT NULL,
      relative_path TEXT NOT NULL,
      checksum TEXT NOT NULL,
      extraction_summary TEXT,
      notes TEXT,
      FOREIGN KEY (artwork_id)
        REFERENCES artworks (artwork_id)
        ON DELETE CASCADE
    )
  ''');

  await db.execute(
    'CREATE INDEX attachments_artwork_idx ON attachments (artwork_id)',
  );

  await db.execute('''
    CREATE TABLE ai_draft_jobs (
      draft_job_id TEXT PRIMARY KEY,
      artwork_id TEXT NOT NULL,
      primary_image_attachment_id TEXT,
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      completed_at TEXT,
      device_model TEXT,
      prompt_version TEXT,
      visual_summary TEXT,
      signature_notes TEXT,
      subject_matter TEXT,
      medium_hint TEXT,
      style_period_hint TEXT,
      condition_notes TEXT,
      search_terms_json TEXT NOT NULL,
      error_message TEXT,
      FOREIGN KEY (artwork_id)
        REFERENCES artworks (artwork_id)
        ON DELETE CASCADE
    )
  ''');

  await db.execute(
    'CREATE INDEX ai_draft_jobs_artwork_idx ON ai_draft_jobs (artwork_id)',
  );

  await db.execute('''
    CREATE TABLE research_jobs (
      research_job_id TEXT PRIMARY KEY,
      artwork_id TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      completed_at TEXT,
      consent_summary TEXT NOT NULL,
      query_summary TEXT,
      provider TEXT,
      error_message TEXT,
      FOREIGN KEY (artwork_id)
        REFERENCES artworks (artwork_id)
        ON DELETE CASCADE
    )
  ''');

  await db.execute(
    'CREATE INDEX research_jobs_artwork_idx ON research_jobs (artwork_id)',
  );

  await db.execute('''
    CREATE TABLE research_source_hits (
      source_hit_id TEXT PRIMARY KEY,
      research_job_id TEXT NOT NULL,
      source_name TEXT NOT NULL,
      source_type TEXT NOT NULL,
      confidence TEXT NOT NULL,
      source_url TEXT,
      object_id TEXT,
      title TEXT,
      artist TEXT,
      date_text TEXT,
      medium TEXT,
      dimensions TEXT,
      image_url TEXT,
      match_reason TEXT,
      raw_snippet TEXT,
      FOREIGN KEY (research_job_id)
        REFERENCES research_jobs (research_job_id)
        ON DELETE CASCADE
    )
  ''');

  await db.execute('''
    CREATE TABLE candidate_attributions (
      candidate_id TEXT PRIMARY KEY,
      research_job_id TEXT NOT NULL,
      source_hit_id TEXT,
      title TEXT,
      artist TEXT,
      year TEXT,
      medium TEXT,
      confidence TEXT NOT NULL,
      match_reason TEXT NOT NULL,
      field_sources_json TEXT NOT NULL,
      FOREIGN KEY (research_job_id)
        REFERENCES research_jobs (research_job_id)
        ON DELETE CASCADE
    )
  ''');

  await db.execute('''
    CREATE TABLE comparable_value_signals (
      signal_id TEXT PRIMARY KEY,
      research_job_id TEXT NOT NULL,
      source_hit_id TEXT,
      kind TEXT NOT NULL,
      label TEXT NOT NULL,
      source_name TEXT NOT NULL,
      source_url TEXT,
      amount_low TEXT,
      amount_high TEXT,
      currency TEXT,
      signal_date TEXT,
      caveat TEXT NOT NULL,
      FOREIGN KEY (research_job_id)
        REFERENCES research_jobs (research_job_id)
        ON DELETE CASCADE
    )
    ''');
}

Future<void> _createV4Schema(Database db, int version) async {
  await _createV3Schema(db, version);
  await db.execute(
    "ALTER TABLE artworks ADD COLUMN lifecycle_status TEXT NOT NULL DEFAULT 'active'",
  );
}

Future<void> _createV5Schema(Database db, int version) async {
  await _createV4Schema(db, version);
  await db.execute('ALTER TABLE artwork_fields ADD COLUMN money_amount TEXT');
  await db.execute(
    'ALTER TABLE artwork_fields ADD COLUMN money_currency_code TEXT',
  );
}

Future<void> _createV6Schema(Database db, int version) async {
  await _createV5Schema(db, version);
  await db.execute(
    "ALTER TABLE attachments ADD COLUMN attachment_role TEXT NOT NULL DEFAULT 'supporting_document'",
  );
}

Future<void> _createV7Schema(Database db, int version) async {
  await _createV6Schema(db, version);
  await db.execute(
    'ALTER TABLE attachments ADD COLUMN derived_from_attachment_id TEXT',
  );
  await db.execute('ALTER TABLE attachments ADD COLUMN transform_summary TEXT');
}

Map<String, Object?> _legacyAttachmentRow({
  required String id,
  required String artworkId,
  required String type,
  required String fileName,
  required String mimeType,
  required DateTime importedAt,
  String? attachmentRole,
}) {
  final row = <String, Object?>{
    'attachment_id': id,
    'artwork_id': artworkId,
    'attachment_type': type,
    'file_name': fileName,
    'mime_type': mimeType,
    'file_size_bytes': 4,
    'imported_at': importedAt.toIso8601String(),
    'captured_at': null,
    'source_state': 'user-confirmed',
    'relative_path': 'artworks/$artworkId/attachments/$id/payload',
    'checksum': '$id-checksum',
    'extraction_summary': null,
    'notes': null,
  };

  if (attachmentRole != null) {
    row['attachment_role'] = attachmentRole;
  }

  return row;
}
