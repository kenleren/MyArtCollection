import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:my_art_collection/app/storage/artwork_collection_query.dart';
import 'package:my_art_collection/app/storage/artwork_group.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  late String databasePath;
  late LocalArtworkRepository repository;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('group_test_');
    databasePath = p.join(directory.path, 'records.db');
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(databasePath),
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

  test('uses the pinned Unicode 15.1 NFC and NFKC_Casefold identity', () {
    expect(normalizeArtworkGroupDisplayName(' A\u030A '), 'Å');
    expect(normalizeArtworkGroupDisplayName('Å'), 'Å');
    expect(
      normalizeArtworkGroupName('Å'),
      normalizeArtworkGroupName('A\u030A'),
    );
    expect(normalizeArtworkGroupName('Ｆｏｏ'), 'foo');
    expect(normalizeArtworkGroupName('K'), 'k');
    expect(normalizeArtworkGroupName('Σςσ'), 'σσσ');
    expect(normalizeArtworkGroupName('Straße'), 'strasse');
    expect(normalizeArtworkGroupName('İ'), 'i\u0307');
    expect(normalizeArtworkGroupName('ﬃ'), 'ffi');
    expect(normalizeArtworkGroupName('𝐀'), 'a');
    expect(normalizeArtworkGroupName('a\u00adb'), 'ab');

    final previousLocale = Intl.defaultLocale;
    try {
      Intl.defaultLocale = 'tr';
      final turkish = normalizeArtworkGroupName('Iİ');
      Intl.defaultLocale = 'en_US';
      expect(normalizeArtworkGroupName('Iİ'), turkish);
    } finally {
      Intl.defaultLocale = previousLocale;
    }
  });

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

  test(
    'reorder validates both permutations and handles boundaries and no-op',
    () async {
      for (final id in ['a', 'b', 'c']) {
        await repository.createGroup(id: id, name: id);
      }
      expect(
        await repository.replaceGroupOrder(
          requestedOrder: ['a', 'b', 'c'],
          expectedCurrentOrder: ['a', 'b', 'c'],
        ),
        GroupOrderReplaceResult.unchanged,
      );
      await expectLater(
        repository.replaceGroupOrder(
          requestedOrder: ['b', 'c', 'a'],
          expectedCurrentOrder: ['a', 'a', 'c'],
        ),
        throwsArgumentError,
      );
      await expectLater(
        repository.replaceGroupOrder(
          requestedOrder: ['a', 'b', 'c'],
          expectedCurrentOrder: ['a', 'b', 'missing'],
        ),
        throwsArgumentError,
      );
      expect(
        await repository.replaceGroupOrder(
          requestedOrder: ['b', 'c', 'a'],
          expectedCurrentOrder: ['a', 'b', 'c'],
        ),
        GroupOrderReplaceResult.applied,
      );
      expect((await repository.listGroups()).map((group) => group.id), [
        'b',
        'c',
        'a',
      ]);
      expect(
        await repository.replaceGroupOrder(
          requestedOrder: ['a', 'b', 'c'],
          expectedCurrentOrder: ['b', 'c', 'a'],
        ),
        GroupOrderReplaceResult.applied,
      );
    },
  );

  test('stale reorder can retry from the current dense order', () async {
    for (final id in ['a', 'b', 'c']) {
      await repository.createGroup(id: id, name: id);
    }
    final firstRead = (await repository.listGroups())
        .map((group) => group.id)
        .toList();
    await repository.replaceGroupOrder(
      requestedOrder: ['b', 'a', 'c'],
      expectedCurrentOrder: firstRead,
    );
    expect(
      await repository.replaceGroupOrder(
        requestedOrder: ['c', 'b', 'a'],
        expectedCurrentOrder: firstRead,
      ),
      GroupOrderReplaceResult.stale,
    );
    final retryRead = (await repository.listGroups())
        .map((group) => group.id)
        .toList();
    expect(
      await repository.replaceGroupOrder(
        requestedOrder: ['c', 'b', 'a'],
        expectedCurrentOrder: retryRead,
      ),
      GroupOrderReplaceResult.applied,
    );
  });

  test('reorder transaction failure does not leave a partial order', () async {
    for (final id in ['a', 'b', 'c']) {
      await repository.createGroup(id: id, name: id);
    }
    final injected = await databaseFactory.openDatabase(databasePath);
    addTearDown(injected.close);
    await injected.execute('''
      CREATE TRIGGER fail_group_order
      BEFORE UPDATE ON artwork_groups
      WHEN NEW.sort_order >= 3
      BEGIN SELECT RAISE(ABORT, 'injected group order failure'); END;
    ''');
    await expectLater(
      repository.replaceGroupOrder(
        requestedOrder: ['c', 'b', 'a'],
        expectedCurrentOrder: ['a', 'b', 'c'],
      ),
      throwsA(isA<DatabaseException>()),
    );
    await injected.execute('DROP TRIGGER fail_group_order');
    expect((await repository.listGroups()).map((group) => group.id), [
      'a',
      'b',
      'c',
    ]);
  });
}
