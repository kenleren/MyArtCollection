import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/storage/artwork_collection_query.dart';
import 'package:my_art_collection/app/storage/artwork_group.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  late LocalArtworkRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('group_test_');
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(p.join(directory.path, 'records.db')),
    );
    for (final id in ['artwork-a', 'artwork-b']) {
      await repository.create(
        ArtworkRecord(
          id: id,
          recordState: ArtworkRecordState.draft,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          fields: const {},
        ),
      );
    }
  });
  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  test(
    'normalizes names, preserves dense order, and rejects collisions',
    () async {
      final first = await repository.createGroup(id: 'g1', name: ' Studio ');
      await repository.createGroup(id: 'g2', name: 'Café');
      expect(first.name, 'Studio');
      expect(first.normalizedName, 'studio');
      await expectLater(
        repository.createGroup(id: 'g3', name: 'Cafe\u0301'),
        throwsA(isA<ArtworkGroupNameException>()),
      );
      await repository.createGroup(id: 'g3', name: 'STRASSE');
      await expectLater(
        repository.createGroup(id: 'g4', name: 'Straße'),
        throwsA(isA<ArtworkGroupNameException>()),
      );
      expect((await repository.listGroups()).map((group) => group.sortOrder), [
        0,
        1,
        2,
      ]);
    },
  );

  test(
    'memberships OR together while favorite and location remain independent constraints',
    () async {
      final studio = await repository.createGroup(id: 'studio', name: 'Studio');
      final loan = await repository.createGroup(id: 'loan', name: 'Loan');
      await repository.replaceArtworkGroupMemberships(
        artworkId: 'artwork-a',
        groupIds: {studio.id},
      );
      await repository.replaceArtworkGroupMemberships(
        artworkId: 'artwork-b',
        groupIds: {loan.id},
      );
      await repository.setFavorite(artworkId: 'artwork-b', isFavorite: true);
      final either = await repository.queryCollection(
        query: ArtworkCollectionQuery(selectedGroupIds: {studio.id, loan.id}),
      );
      expect(
        either.entries.map((entry) => entry.record.id),
        containsAll(['artwork-a', 'artwork-b']),
      );
      final favorite = await repository.queryCollection(
        query: ArtworkCollectionQuery(
          selectedGroupIds: {studio.id, loan.id},
          favoritesOnly: true,
        ),
      );
      expect(favorite.entries.single.record.id, 'artwork-b');
      expect(await repository.isFavorite('artwork-a'), isFalse);
    },
  );

  test('delete only removes its memberships and compacts order', () async {
    final a = await repository.createGroup(id: 'a', name: 'A');
    final b = await repository.createGroup(id: 'b', name: 'B');
    await repository.replaceArtworkGroupMemberships(
      artworkId: 'artwork-a',
      groupIds: {a.id, b.id},
    );
    await repository.setFavorite(artworkId: 'artwork-a', isFavorite: true);
    await repository.deleteGroup(a.id);
    expect(await repository.groupIdsForArtwork('artwork-a'), {b.id});
    expect(await repository.isFavorite('artwork-a'), isTrue);
    expect((await repository.listGroups()).single.sortOrder, 0);
  });
}
