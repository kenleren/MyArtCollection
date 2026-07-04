import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:my_art_collection/app/app.dart';
import 'package:my_art_collection/app/app_dependencies.dart';
import 'package:my_art_collection/app/app_routes.dart';
import 'package:my_art_collection/app/intake/artwork_image_picker.dart';
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
    addTearDown(fixture.dispose);

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

class _NoLostImagePicker implements ArtworkImagePicker {
  @override
  Future<XFile?> pick(ArtworkImagePickMode mode) async => null;

  @override
  Future<XFile?> retrieveLostImage() async => null;
}

class _LiveDependencyFixture {
  const _LiveDependencyFixture({
    required this.tempDir,
    required this.repository,
    required this.dependencies,
  });

  final Directory tempDir;
  final LocalArtworkRepository repository;
  final AppDependencies dependencies;

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
      dependencies: AppDependencies(
        artworkRepository: repository,
        attachmentStore: attachmentStore,
        imagePicker: _NoLostImagePicker(),
      ),
    );
  }

  Future<void> dispose() async {
    await repository.close();
    await tempDir.delete(recursive: true);
  }
}
