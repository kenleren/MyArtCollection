import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

Map<String, Object?> _legacyAttachmentRow({
  required String id,
  required String artworkId,
  required String type,
  required String fileName,
  required String mimeType,
  required DateTime importedAt,
}) {
  return {
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
}
