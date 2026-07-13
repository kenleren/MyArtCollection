import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/external_reference.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDirectory;
  late String databasePath;
  late Database database;
  late LocalArtworkRepository repository;

  setUp(() async {
    tempDirectory = await Directory.systemTemp.createTemp(
      'external-repository-',
    );
    databasePath = p.join(tempDirectory.path, 'test.db');
    database = await LocalArtworkRepository.openAt(databasePath);
    repository = LocalArtworkRepository.forDatabase(database);
    await repository.create(_artwork('artwork-1'));
    await repository.create(_artwork('artwork-2'));
  });

  tearDown(() async {
    await repository.close();
    await tempDirectory.delete(recursive: true);
  });

  Future<ExternalReferenceRecord> addReference(
    String id, {
    required DateTime time,
  }) => repository.addManualExternalReference(
    referenceId: id,
    artworkId: 'artwork-1',
    type: ExternalReferenceType.galleryOrArtist,
    label: id,
    url: 'https://example.com/$id',
    transactionTime: time,
  );

  Future<void> reorderReferences(
    List<ExternalReferenceRecord> current,
    List<String> ids,
    DateTime time,
  ) => repository.reorderExternalReferences(
    artworkId: 'artwork-1',
    orderedReferenceIds: ids,
    expectedUpdatedAtById: {for (final row in current) row.id: row.updatedAt},
    transactionTime: time,
  );

  Future<void> deleteReference(
    ExternalReferenceRecord row,
    DateTime time,
  ) async {
    expect(
      await repository.deleteExternalReference(
        artworkId: 'artwork-1',
        referenceId: row.id,
        expectedUpdatedAt: row.updatedAt,
        transactionTime: time,
      ),
      ExternalReferenceDeleteResult.deleted,
    );
  }

  Future<List<Map<String, Object?>>> snapshot() async {
    final rows = await database.query(
      'external_references',
      orderBy: 'artwork_id, sort_order, reference_id',
    );
    return rows.map(Map<String, Object?>.of).toList(growable: false);
  }

  test(
    'schema enables foreign keys and enforces constraints and immutability',
    () async {
      final foreignKeys = await database.rawQuery('PRAGMA foreign_keys');
      expect(foreignKeys.single.values.single, 1);

      final row = _rawRow();
      for (final invalid in [
        {...row, 'reference_id': 'invalid id'},
        {...row, 'reference_type': 'artist'},
        {...row, 'origin': 'provider'},
        {...row, 'review_state': 'suggested'},
        {...row, 'sort_order': -1},
        {...row, 'created_at': '2026-07-13T00:00:00Z'},
      ]) {
        await expectLater(
          database.insert('external_references', invalid),
          throwsA(anything),
        );
      }

      await database.insert('external_references', row);
      await expectLater(
        database.update(
          'external_references',
          {'origin': 'ai_suggestion'},
          where: 'reference_id = ?',
          whereArgs: ['reference-raw'],
        ),
        throwsA(anything),
      );
      await expectLater(
        database.insert('external_references', {
          ..._rawRow(referenceId: 'reference-duplicate-url'),
          'sort_order': 1,
        }),
        throwsA(anything),
      );
      await expectLater(
        database.insert('external_references', {
          ..._rawRow(
            referenceId: 'reference-duplicate-order',
            url: 'https://example.com/other',
          ),
        }),
        throwsA(anything),
      );

      await database.insert('external_references', {
        ..._rawRow(
          referenceId: 'invalid-calendar',
          url: 'https://example.com/calendar',
        ),
        'artwork_id': 'artwork-2',
        'created_at': '2026-02-30T00:00:00.000Z',
      });
      await expectLater(
        repository.externalReferencesForArtwork('artwork-2'),
        throwsA(isA<ExternalReferenceValidationException>()),
      );
    },
  );

  test(
    'manual and suggestion lifecycle preserves provenance and strict no-ops',
    () async {
      final manual = await addReference('manual', time: _time(0));
      expect(manual.origin, ExternalReferenceOrigin.manual);
      expect(manual.reviewState, ExternalReferenceReviewState.confirmed);
      expect(manual.lastConfirmedAt, _time(0));

      final suggestion = await repository.saveExternalReferenceSuggestion(
        referenceId: 'suggestion',
        artworkId: 'artwork-1',
        type: ExternalReferenceType.museumOrInstitution,
        label: ' Museum ',
        url: 'HTTPS://MUSEUM.EXAMPLE:443/object',
        transactionTime: _time(1),
      );
      expect(suggestion.label, 'Museum');
      expect(suggestion.url, 'https://museum.example/object');
      expect(suggestion.origin, ExternalReferenceOrigin.aiSuggestion);
      expect(suggestion.reviewState, ExternalReferenceReviewState.suggested);
      expect(suggestion.lastConfirmedAt, isNull);

      final confirmed = await repository.confirmExternalReference(
        referenceId: suggestion.id,
        expectedUpdatedAt: suggestion.updatedAt,
        transactionTime: _time(2),
      );
      expect(confirmed.origin, ExternalReferenceOrigin.aiSuggestion);
      expect(confirmed.reviewState, ExternalReferenceReviewState.confirmed);
      expect(confirmed.lastConfirmedAt, _time(2));

      final confirmNoOp = await repository.confirmExternalReference(
        referenceId: confirmed.id,
        expectedUpdatedAt: confirmed.updatedAt,
        transactionTime: _time(3),
      );
      expect(confirmNoOp.updatedAt, _time(2));

      final editNoOp = await repository.editExternalReference(
        referenceId: confirmed.id,
        type: confirmed.type,
        label: confirmed.label,
        url: confirmed.url,
        expectedUpdatedAt: confirmed.updatedAt,
        transactionTime: _time(4),
      );
      expect(editNoOp.updatedAt, _time(2));

      final edited = await repository.editExternalReference(
        referenceId: confirmed.id,
        type: ExternalReferenceType.publicationOrCatalogue,
        label: null,
        url: 'https://museum.example/catalogue',
        expectedUpdatedAt: confirmed.updatedAt,
        transactionTime: _time(5),
      );
      expect(edited.origin, ExternalReferenceOrigin.aiSuggestion);
      expect(edited.reviewState, ExternalReferenceReviewState.confirmed);
      expect(edited.label, isNull);
      expect(edited.lastConfirmedAt, _time(5));
      expect(edited.updatedAt, _time(5));

      final manualEdited = await repository.editExternalReference(
        referenceId: manual.id,
        type: manual.type,
        label: 'Changed',
        url: manual.url,
        expectedUpdatedAt: manual.updatedAt,
        transactionTime: _time(6),
      );
      expect(manualEdited.origin, ExternalReferenceOrigin.manual);
      expect(manualEdited.reviewState, ExternalReferenceReviewState.confirmed);
      expect(manualEdited.lastConfirmedAt, _time(6));
    },
  );

  test(
    'material suggestion edit confirms while duplicate and stale edits write nothing',
    () async {
      final first = await addReference('first', time: _time(0));
      final suggested = await repository.saveExternalReferenceSuggestion(
        referenceId: 'suggested',
        artworkId: 'artwork-1',
        type: ExternalReferenceType.other,
        label: null,
        url: 'https://example.com/suggested',
        transactionTime: _time(1),
      );
      final beforeDuplicate = await snapshot();

      await expectLater(
        repository.addManualExternalReference(
          referenceId: 'duplicate',
          artworkId: 'artwork-1',
          type: ExternalReferenceType.other,
          label: null,
          url: first.url,
          transactionTime: _time(2),
        ),
        throwsA(
          isA<ExternalReferenceRepositoryException>().having(
            (error) => error.failure,
            'failure',
            ExternalReferenceRepositoryFailure.duplicate,
          ),
        ),
      );
      expect(await snapshot(), beforeDuplicate);

      final edited = await repository.editExternalReference(
        referenceId: suggested.id,
        type: suggested.type,
        label: 'Collector reviewed',
        url: suggested.url,
        expectedUpdatedAt: suggested.updatedAt,
        transactionTime: _time(3),
      );
      expect(edited.reviewState, ExternalReferenceReviewState.confirmed);
      expect(edited.origin, ExternalReferenceOrigin.aiSuggestion);

      final beforeStale = await snapshot();
      await expectLater(
        repository.editExternalReference(
          referenceId: edited.id,
          type: edited.type,
          label: 'Stale overwrite',
          url: edited.url,
          expectedUpdatedAt: suggested.updatedAt,
          transactionTime: _time(4),
        ),
        throwsA(
          isA<ExternalReferenceRepositoryException>().having(
            (error) => error.failure,
            'failure',
            ExternalReferenceRepositoryFailure.stale,
          ),
        ),
      );
      expect(await snapshot(), beforeStale);
    },
  );

  test(
    'reorder covers no-op, adjacent, rotation, reverse, fixed rows and stale inputs',
    () async {
      final rows = <ExternalReferenceRecord>[];
      for (var index = 0; index < 4; index++) {
        rows.add(await addReference('r$index', time: _time(index)));
      }

      final identityBefore = await snapshot();
      await reorderReferences(rows, ['r0', 'r1', 'r2', 'r3'], _time(10));
      expect(await snapshot(), identityBefore);

      await reorderReferences(rows, ['r1', 'r0', 'r2', 'r3'], _time(11));
      var current = await repository.externalReferencesForArtwork('artwork-1');
      expect(current.map((row) => row.id), ['r1', 'r0', 'r2', 'r3']);
      expect(current[0].updatedAt, _time(11));
      expect(current[1].updatedAt, _time(11));
      expect(current[2].updatedAt, _time(2));
      expect(current[3].updatedAt, _time(3));

      await reorderReferences(current, ['r0', 'r2', 'r3', 'r1'], _time(12));
      current = await repository.externalReferencesForArtwork('artwork-1');
      expect(current.map((row) => row.id), ['r0', 'r2', 'r3', 'r1']);

      await reorderReferences(current, ['r1', 'r3', 'r2', 'r0'], _time(13));
      current = await repository.externalReferencesForArtwork('artwork-1');
      expect(current.map((row) => row.id), ['r1', 'r3', 'r2', 'r0']);
      expect(current.map((row) => row.sortOrder), [0, 1, 2, 3]);

      final staleBefore = await snapshot();
      await expectLater(
        repository.reorderExternalReferences(
          artworkId: 'artwork-1',
          orderedReferenceIds: ['r3', 'r1', 'r2', 'r0'],
          expectedUpdatedAtById: {for (final row in current) row.id: _time(0)},
          transactionTime: _time(14),
        ),
        throwsA(isA<ExternalReferenceRepositoryException>()),
      );
      expect(await snapshot(), staleBefore);
    },
  );

  test(
    'reorder rejects missing, extra, duplicate, cross-artwork and gapped state',
    () async {
      final first = await addReference('first', time: _time(0));
      final second = await addReference('second', time: _time(1));
      await repository.addManualExternalReference(
        referenceId: 'other-artwork',
        artworkId: 'artwork-2',
        type: ExternalReferenceType.other,
        label: null,
        url: 'https://example.com/other-artwork',
        transactionTime: _time(2),
      );
      final expected = {first.id: first.updatedAt, second.id: second.updatedAt};
      for (final ids in [
        ['first'],
        ['first', 'second', 'extra'],
        ['first', 'first'],
        ['first', 'other-artwork'],
      ]) {
        final before = await snapshot();
        await expectLater(
          repository.reorderExternalReferences(
            artworkId: 'artwork-1',
            orderedReferenceIds: ids,
            expectedUpdatedAtById: expected,
            transactionTime: _time(3),
          ),
          throwsA(isA<ExternalReferenceRepositoryException>()),
        );
        expect(await snapshot(), before);
      }

      await database.update(
        'external_references',
        {'sort_order': 4},
        where: 'reference_id = ?',
        whereArgs: ['second'],
      );
      final gapped = await snapshot();
      await expectLater(
        repository.reorderExternalReferences(
          artworkId: 'artwork-1',
          orderedReferenceIds: ['first', 'second'],
          expectedUpdatedAtById: expected,
          transactionTime: _time(4),
        ),
        throwsA(
          isA<ExternalReferenceRepositoryException>().having(
            (error) => error.failure,
            'failure',
            ExternalReferenceRepositoryFailure.invariant,
          ),
        ),
      );
      expect(await snapshot(), gapped);
    },
  );

  test('capacity guard uses BigInt and fails before integer overflow', () {
    expect(
      () => ExternalReferenceOrderCapacity.validate(9223372036854775807, [1]),
      throwsA(
        isA<ExternalReferenceRepositoryException>().having(
          (error) => error.failure,
          'failure',
          ExternalReferenceRepositoryFailure.capacity,
        ),
      ),
    );
    expect(
      () => ExternalReferenceOrderCapacity.validate(9223372036854775806, [1]),
      returnsNormally,
    );
  });

  test(
    'delete first, middle, last, only and missing keeps dense order',
    () async {
      for (var index = 0; index < 4; index++) {
        await addReference('d$index', time: _time(index));
      }
      var current = await repository.externalReferencesForArtwork('artwork-1');

      await deleteReference(current[0], _time(10));
      current = await repository.externalReferencesForArtwork('artwork-1');
      expect(current.map((row) => row.id), ['d1', 'd2', 'd3']);
      expect(current.map((row) => row.sortOrder), [0, 1, 2]);

      await deleteReference(current[1], _time(11));
      current = await repository.externalReferencesForArtwork('artwork-1');
      expect(current.map((row) => row.id), ['d1', 'd3']);

      await deleteReference(current.last, _time(12));
      current = await repository.externalReferencesForArtwork('artwork-1');
      expect(current.map((row) => row.id), ['d1']);

      await deleteReference(current.single, _time(13));
      expect(
        await repository.externalReferencesForArtwork('artwork-1'),
        isEmpty,
      );
      expect(
        await repository.deleteExternalReference(
          artworkId: 'artwork-1',
          referenceId: 'missing',
          expectedUpdatedAt: _time(0),
          transactionTime: _time(14),
        ),
        ExternalReferenceDeleteResult.notFound,
      );
    },
  );

  test(
    'injected phase-two reorder and delete failures roll back fully',
    () async {
      for (var index = 0; index < 3; index++) {
        await addReference('rollback-$index', time: _time(index));
      }
      var current = await repository.externalReferencesForArtwork('artwork-1');
      final reorderBefore = await snapshot();
      final reorderRepository = LocalArtworkRepository.forDatabase(
        database,
        externalReferenceTransactionObserver: _ThrowingObserver(
          ExternalReferenceTransactionCheckpoint.reorderStaged,
        ),
      );
      await expectLater(
        reorderRepository.reorderExternalReferences(
          artworkId: 'artwork-1',
          orderedReferenceIds: current.reversed.map((row) => row.id).toList(),
          expectedUpdatedAtById: {
            for (final row in current) row.id: row.updatedAt,
          },
          transactionTime: _time(10),
        ),
        throwsA(isA<StateError>()),
      );
      expect(await snapshot(), reorderBefore);

      current = await repository.externalReferencesForArtwork('artwork-1');
      final deleteBefore = await snapshot();
      final deleteRepository = LocalArtworkRepository.forDatabase(
        database,
        externalReferenceTransactionObserver: _ThrowingObserver(
          ExternalReferenceTransactionCheckpoint.deleteSurvivorsStaged,
        ),
      );
      await expectLater(
        deleteRepository.deleteExternalReference(
          artworkId: 'artwork-1',
          referenceId: current.first.id,
          expectedUpdatedAt: current.first.updatedAt,
          transactionTime: _time(11),
        ),
        throwsA(isA<StateError>()),
      );
      expect(await snapshot(), deleteBefore);
    },
  );

  test(
    'artwork deletion cascades references while lifecycle retention does not',
    () async {
      await addReference('cascade', time: _time(0));
      final artwork = await repository.get('artwork-1');
      await repository.upsert(
        artwork!.copyWith(lifecycleStatus: ArtworkLifecycleStatus.sold),
      );
      expect(
        await repository.externalReferencesForArtwork('artwork-1'),
        hasLength(1),
      );

      await repository.delete('artwork-1');
      expect(
        await repository.externalReferencesForArtwork('artwork-1'),
        isEmpty,
      );
    },
  );

  test(
    'v8 migration is additive and a late migration failure rolls back',
    () async {
      await repository.close();
      await databaseFactoryFfi.deleteDatabase(databasePath);

      final legacy = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: 8,
          onCreate: (db, version) async {
            await db.execute(
              'CREATE TABLE artworks (artwork_id TEXT PRIMARY KEY)',
            );
          },
        ),
      );
      await legacy.close();
      database = await LocalArtworkRepository.openAt(databasePath);
      repository = LocalArtworkRepository.forDatabase(database);
      final tables = await database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'external_references'",
      );
      expect(tables, hasLength(1));

      await repository.close();
      await databaseFactoryFfi.deleteDatabase(databasePath);
      final failingLegacy = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(
          version: 8,
          onCreate: (db, version) async {
            await db.execute(
              'CREATE TABLE artworks (artwork_id TEXT PRIMARY KEY)',
            );
            await db.execute('CREATE TABLE dummy (value INTEGER)');
            await db.execute('''
            CREATE TRIGGER external_references_immutable_fields
            BEFORE UPDATE ON dummy BEGIN SELECT 1; END
          ''');
          },
        ),
      );
      await failingLegacy.close();
      await expectLater(
        LocalArtworkRepository.openAt(databasePath),
        throwsA(anything),
      );

      database = await databaseFactoryFfi.openDatabase(databasePath);
      repository = LocalArtworkRepository.forDatabase(database);
      final rolledBack = await database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'external_references'",
      );
      expect(rolledBack, isEmpty);
      expect(await database.getVersion(), 8);
    },
  );
}

class _ThrowingObserver implements ExternalReferenceTransactionObserver {
  const _ThrowingObserver(this.checkpoint);
  final ExternalReferenceTransactionCheckpoint checkpoint;

  @override
  Future<void> onCheckpoint(
    ExternalReferenceTransactionCheckpoint checkpoint,
  ) async {
    if (checkpoint == this.checkpoint) throw StateError('injected failure');
  }
}

ArtworkRecord _artwork(String id) => ArtworkRecord(
  id: id,
  recordState: ArtworkRecordState.verifiedByYou,
  createdAt: _time(0),
  updatedAt: _time(0),
  fields: const {},
);

DateTime _time(int minute) => DateTime.utc(2026, 7, 13, 8, minute);

Map<String, Object?> _rawRow({
  String referenceId = 'reference-raw',
  String url = 'https://example.com/raw',
}) => {
  'reference_id': referenceId,
  'artwork_id': 'artwork-1',
  'reference_type': 'other',
  'label': null,
  'url': url,
  'origin': 'manual',
  'review_state': 'confirmed',
  'last_confirmed_at': '2026-07-13T08:00:00.000Z',
  'created_at': '2026-07-13T08:00:00.000Z',
  'updated_at': '2026-07-13T08:00:00.000Z',
  'sort_order': 0,
};
