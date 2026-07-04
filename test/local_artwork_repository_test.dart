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
      reloaded.field(ArtworkFieldKeys.artist)?.source,
      ArtworkFieldSource.userConfirmed,
    );
    expect(
      reloaded.field(ArtworkFieldKeys.artist)?.lastConfirmedAt,
      DateTime.utc(2026, 7, 4, 8, 4).toLocal(),
    );
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
