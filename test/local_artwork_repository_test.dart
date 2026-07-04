import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
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
        },
      ),
    );

    final reloaded = await reloadAndGet('artwork-001');

    expect(reloaded, isNotNull);
    expect(reloaded!.recordState, ArtworkRecordState.needsReview);
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

    final rawDatabase = await databaseFactoryFfi.openDatabase(databasePath);
    addTearDown(rawDatabase.close);

    final sourceRows = await rawDatabase.query(
      'artwork_fields',
      columns: ['field_key', 'source_state'],
      where: 'artwork_id = ?',
      whereArgs: ['artwork-001'],
      orderBy: 'field_key ASC',
    );

    expect(sourceRows, [
      {'field_key': ArtworkFieldKeys.artist, 'source_state': 'user-confirmed'},
      {'field_key': ArtworkFieldKeys.title, 'source_state': 'AI-suggested'},
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
  });
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
