import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:my_art_collection/app/app.dart';
import 'package:my_art_collection/app/app_dependencies.dart';
import 'package:my_art_collection/app/app_routes.dart';
import 'package:my_art_collection/app/intake/artwork_image_picker.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/attachment_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:my_art_collection/app/storage/local_attachment_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('intro screen shows brand once and value heading once', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MyArtCollectionApp(initialRoute: AppRoutes.splash),
    );
    await pumpReady(tester);

    expect(find.text('MyArtCollection'), findsOneWidget);
    expect(find.text('Private artwork records'), findsOneWidget);
    expect(find.text('AI drafts. You confirm.'), findsOneWidget);
  });

  testWidgets('collection shell renders and can open add artwork', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MyArtCollectionApp(initialRoute: AppRoutes.collection),
    );
    await pumpReady(tester);

    expect(find.text('Collection'), findsWidgets);
    expect(find.text('Incomplete'), findsOneWidget);
    expect(find.text('Reports'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('No artworks yet'), findsOneWidget);
    expect(find.text('Blue Interior Study'), findsNothing);

    await tapVisible(tester, find.widgetWithText(FilledButton, 'Add artwork'));

    expect(find.text('Add artwork'), findsWidgets);
    expect(find.text('Take photo'), findsOneWidget);
    expect(find.text('Import photo'), findsOneWidget);
  });

  testWidgets('first artwork prototype reaches report and export preview', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MyArtCollectionApp(initialRoute: AppRoutes.collection),
    );
    await pumpReady(tester);

    await tapVisible(tester, find.widgetWithText(FilledButton, 'Add artwork'));
    await tapVisible(tester, find.text('Import photo'));
    expect(find.text('Photo imported'), findsOneWidget);
    expect(find.text('Upload-failure state'), findsOneWidget);

    await tapVisible(tester, find.text('Review AI draft'));
    expect(find.text('AI draft review'), findsWidgets);
    expect(find.text('AI-suggested'), findsWidgets);
    expect(find.text('User confirmed'), findsOneWidget);
    expect(find.text('Document-extracted'), findsOneWidget);
    expect(find.text('Unknown'), findsOneWidget);

    await tapVisible(tester, find.text('Confirm suggested fields'));
    expect(find.text('Verified by you'), findsWidgets);
    expect(find.text('Blue Interior Study'), findsWidgets);
    expect(find.text('Record state: Verified by you'), findsOneWidget);

    await tapVisible(tester, find.text('Attach receipt placeholder'));
    expect(find.text('Documents'), findsWidgets);
    expect(find.text('gallery-receipt-2025.pdf'), findsOneWidget);
    expect(find.text('Attach document placeholder'), findsOneWidget);
    expect(find.text('Missing-file state'), findsOneWidget);

    await tapVisible(
      tester,
      find.widgetWithText(OutlinedButton, 'Report preview').last,
    );
    expect(find.text('Generate an insurance-ready PDF'), findsWidgets);
    expect(
      find.text('User-provided insurance value: USD 2,400.'),
      findsOneWidget,
    );

    await tapVisible(tester, find.text('Export archive preview'));
    expect(find.text('Export record package'), findsWidgets);
    expect(find.text('ZIP archive preview'), findsOneWidget);
    expect(find.text('User-provided insurance values only.'), findsOneWidget);
  });

  testWidgets('live import flow shows failed recovery state', (
    WidgetTester tester,
  ) async {
    final testDependencies = await tester.runAsync(
      () async => _LiveDependencyFixture.create(),
    );
    final fixture = testDependencies!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.dispose);
    });

    await tester.pumpWidget(
      MyArtCollectionApp(
        initialRoute: AppRoutes.import,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpReady(tester);

    await tapVisible(tester, find.text('Recover interrupted import'));

    expect(find.text('Import needs attention'), findsOneWidget);
    expect(
      find.textContaining('No interrupted import was available.'),
      findsOneWidget,
    );
    expect(find.text('Choose from system picker'), findsOneWidget);
  });

  testWidgets('collection lists local record after repository reload', (
    WidgetTester tester,
  ) async {
    final testDependencies = await tester.runAsync(
      () async => _LiveDependencyFixture.create(),
    );
    final fixture = testDependencies!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.dispose);
    });

    await tester.runAsync(() async {
      await fixture.repository.upsert(
        _artworkRecord(
          id: 'local-001',
          title: 'Reloaded Local Artwork',
          state: ArtworkRecordState.needsReview,
        ),
      );
      await fixture.reopenRepository();
    });

    await tester.pumpWidget(
      MyArtCollectionApp(
        initialRoute: AppRoutes.collection,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Reloaded Local Artwork'), findsOneWidget);
    expect(find.text('Needs review'), findsOneWidget);
    expect(find.text('No artworks yet'), findsNothing);
    expect(find.textContaining('incomplete queue items'), findsOneWidget);
  });

  testWidgets('incomplete queue derives from local fields and documents', (
    WidgetTester tester,
  ) async {
    final testDependencies = await tester.runAsync(
      () async => _LiveDependencyFixture.create(),
    );
    final fixture = testDependencies!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.dispose);
    });

    await tester.runAsync(() async {
      await fixture.repository.upsert(
        _artworkRecord(
          id: 'local-incomplete',
          title: 'Needs Local Review',
          state: ArtworkRecordState.needsReview,
        ),
      );
      await fixture.repository.upsert(
        _artworkRecord(
          id: 'local-complete',
          title: 'Complete Local Record',
          state: ArtworkRecordState.verifiedByYou,
          source: ArtworkFieldSource.userConfirmed,
        ),
      );
      await fixture.repository.addAttachment(
        _attachmentRecord(
          id: 'receipt-001',
          artworkId: 'local-complete',
          type: AttachmentType.receipt,
        ),
      );
    });

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      MyArtCollectionApp(
        initialRoute: AppRoutes.collectionIncomplete,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Needs Local Review needs review'), findsOneWidget);
    expect(
      find.text('Needs Local Review needs supporting documents'),
      findsOneWidget,
    );
    expect(find.text('Complete Local Record needs review'), findsNothing);
    expect(
      find.text('Complete Local Record needs supporting documents'),
      findsNothing,
    );

    await tester.runAsync(() async {
      await fixture.repository.upsert(
        _artworkRecord(
          id: 'local-incomplete',
          title: 'Needs Local Review',
          state: ArtworkRecordState.verifiedByYou,
          source: ArtworkFieldSource.userConfirmed,
        ),
      );
      await fixture.repository.addAttachment(
        _attachmentRecord(
          id: 'receipt-002',
          artworkId: 'local-incomplete',
          type: AttachmentType.receipt,
        ),
      );
    });

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      MyArtCollectionApp(
        initialRoute: AppRoutes.collectionIncomplete,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Needs Local Review needs review'), findsNothing);
    expect(
      find.text('Needs Local Review needs supporting documents'),
      findsNothing,
    );
    expect(find.text('No incomplete records'), findsOneWidget);
  });

  testWidgets('incomplete missing-values action preserves draft provenance', (
    WidgetTester tester,
  ) async {
    final testDependencies = await tester.runAsync(
      () async => _LiveDependencyFixture.create(),
    );
    final fixture = testDependencies!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.dispose);
    });

    await tester.runAsync(() async {
      await fixture.repository.upsert(
        _artworkRecord(
          id: 'local-draft-route',
          title: 'Draft Route Artwork',
          state: ArtworkRecordState.needsReview,
          missingFieldKeys: {ArtworkFieldKeys.artist},
        ),
      );
    });

    await tester.pumpWidget(
      MyArtCollectionApp(
        initialRoute: AppRoutes.collectionIncomplete,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Draft Route Artwork has missing values'), findsOneWidget);

    await tester.tap(find.text('Open record'));
    await pumpReady(tester);

    expect(find.text('AI draft review'), findsWidgets);
    expect(find.text('Possible values. Please confirm.'), findsOneWidget);
    expect(find.text('AI-suggested'), findsWidgets);
    expect(find.text('Verified by you'), findsNothing);
  });

  testWidgets('settings shell routes render the settings tab', (
    WidgetTester tester,
  ) async {
    for (final route in [AppRoutes.collectionSettings, AppRoutes.settings]) {
      await tester.pumpWidget(MyArtCollectionApp(initialRoute: route));
      await pumpReady(tester);

      expect(find.text('Settings'), findsWidgets);
      expect(find.text('Privacy and storage'), findsWidgets);
      expect(find.text('Disconnect backup'), findsOneWidget);
      expect(find.text('No artworks yet'), findsNothing);
    }
  });
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await pumpReady(tester);
}

Future<void> pumpReady(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> pumpLiveData(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () async => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

class _NoLostImagePicker implements ArtworkImagePicker {
  @override
  Future<XFile?> pick(ArtworkImagePickMode mode) async => null;

  @override
  Future<XFile?> retrieveLostImage() async => null;
}

class _LiveDependencyFixture {
  _LiveDependencyFixture({
    required this.tempDir,
    required this.repository,
    required this.attachmentStore,
  });

  final Directory tempDir;
  LocalArtworkRepository repository;
  final LocalAttachmentStore attachmentStore;

  AppDependencies get dependencies {
    return AppDependencies(
      artworkRepository: repository,
      attachmentStore: attachmentStore,
      imagePicker: _NoLostImagePicker(),
    );
  }

  static Future<_LiveDependencyFixture> create() async {
    final tempDir = await Directory.systemTemp.createTemp(
      'my_art_collection_widget_test_',
    );
    final repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(p.join(tempDir.path, 'records.db')),
    );
    final attachmentStore = await LocalAttachmentStore.openAt(
      Directory(p.join(tempDir.path, 'private_files')),
    );

    return _LiveDependencyFixture(
      tempDir: tempDir,
      repository: repository,
      attachmentStore: attachmentStore,
    );
  }

  Future<void> reopenRepository() async {
    await repository.close();
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(p.join(tempDir.path, 'records.db')),
    );
  }

  Future<void> dispose() async {
    await repository.close();
    await tempDir.delete(recursive: true);
  }
}

ArtworkRecord _artworkRecord({
  required String id,
  required String title,
  required ArtworkRecordState state,
  ArtworkFieldSource source = ArtworkFieldSource.aiSuggested,
  Set<String> missingFieldKeys = const {},
}) {
  final now = DateTime.utc(2026, 7, 4, 12);
  return ArtworkRecord(
    id: id,
    recordState: state,
    primaryImageAttachmentId: 'primary-$id',
    createdAt: now,
    updatedAt: now,
    fields: {
      for (final entry in _testFieldValues.entries)
        if (!missingFieldKeys.contains(entry.key))
          entry.key: ArtworkFieldValue(
            value: entry.key == ArtworkFieldKeys.title ? title : entry.value,
            source: source,
            note: source == ArtworkFieldSource.userConfirmed
                ? 'Confirmed in test fixture.'
                : 'Needs confirmation in test fixture.',
            lastConfirmedAt: source == ArtworkFieldSource.userConfirmed
                ? now
                : null,
          ),
    },
  );
}

AttachmentRecord _attachmentRecord({
  required String id,
  required String artworkId,
  required AttachmentType type,
}) {
  return AttachmentRecord(
    id: id,
    artworkId: artworkId,
    type: type,
    fileName: '$id.pdf',
    mimeType: 'application/pdf',
    fileSizeBytes: 12,
    importedAt: DateTime.utc(2026, 7, 4, 12),
    source: ArtworkFieldSource.userConfirmed,
    relativePath: 'attachments/$id.pdf',
    checksum: 'checksum-$id',
    notes: 'Supporting document fixture.',
  );
}

const _testFieldValues = {
  ArtworkFieldKeys.title: 'Fixture title',
  ArtworkFieldKeys.artist: 'Fixture artist',
  ArtworkFieldKeys.year: '2026',
  ArtworkFieldKeys.medium: 'Oil on canvas',
  ArtworkFieldKeys.dimensions: '40 x 50 cm',
  ArtworkFieldKeys.currentLocation: 'Studio wall',
  ArtworkFieldKeys.insuranceValue: 'USD 100',
  ArtworkFieldKeys.conditionNotes: 'Good condition',
};
