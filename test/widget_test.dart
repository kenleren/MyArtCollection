import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:my_art_collection/app/ai/on_device_ai_draft_service.dart';
import 'package:my_art_collection/app/app.dart';
import 'package:my_art_collection/app/app_dependencies.dart';
import 'package:my_art_collection/app/app_routes.dart';
import 'package:my_art_collection/app/config/app_feature_flags.dart';
import 'package:my_art_collection/app/import/csv_import_file_picker.dart';
import 'package:my_art_collection/app/intake/artwork_image_picker.dart';
import 'package:my_art_collection/app/startup_route.dart';
import 'package:my_art_collection/app/storage/ai_research_record.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/attachment_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:my_art_collection/app/storage/local_attachment_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await loadScreenshotFont();
  });

  testWidgets('intro screen shows brand once and value heading once', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ArchivaleApp(initialRoute: AppRoutes.splash));
    await pumpReady(tester);

    expect(find.text('Archivale'), findsOneWidget);
    expect(find.text('Private artwork records'), findsOneWidget);
    expect(find.text('AI drafts. You confirm.'), findsOneWidget);
  });

  testWidgets('app provides system-aware light and dark Material themes', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ArchivaleApp(initialRoute: AppRoutes.splash));
    await pumpReady(tester);

    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.themeMode, ThemeMode.system);
    expect(materialApp.darkTheme, isNotNull);

    await tester.pumpWidget(
      const ArchivaleApp(
        initialRoute: AppRoutes.splash,
        themeMode: ThemeMode.dark,
      ),
    );
    await pumpReady(tester);

    final headingContext = tester.element(find.text('Private artwork records'));
    final theme = Theme.of(headingContext);
    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.primary, const Color(0xFFD9BE78));
    expect(theme.scaffoldBackgroundColor, const Color(0xFF090B0B));
  });

  testWidgets('visual evidence covers refreshed core mobile screens', (
    WidgetTester tester,
  ) async {
    await captureVisualEvidence(
      tester,
      routeName: AppRoutes.splash,
      themeMode: ThemeMode.light,
      fileName: 'light_intro.png',
    );
    await captureVisualEvidence(
      tester,
      routeName: AppRoutes.collection,
      themeMode: ThemeMode.light,
      fileName: 'light_collection.png',
    );
    await captureVisualEvidence(
      tester,
      routeName: AppRoutes.collectionAdd,
      themeMode: ThemeMode.light,
      fileName: 'light_add_artwork.png',
    );
    await captureVisualEvidence(
      tester,
      routeName: AppRoutes.artworkDraft('sample-001'),
      themeMode: ThemeMode.light,
      fileName: 'light_draft_review.png',
    );
    await captureVisualEvidence(
      tester,
      routeName: AppRoutes.artworkReportPreview('sample-001'),
      themeMode: ThemeMode.light,
      fileName: 'light_report_preview.png',
    );
    await captureVisualEvidence(
      tester,
      routeName: AppRoutes.collectionSettings,
      themeMode: ThemeMode.light,
      fileName: 'light_settings.png',
    );
    await captureVisualEvidence(
      tester,
      routeName: AppRoutes.splash,
      themeMode: ThemeMode.dark,
      fileName: 'dark_intro.png',
    );
    await captureVisualEvidence(
      tester,
      routeName: AppRoutes.artworkReportPreview('sample-001'),
      themeMode: ThemeMode.dark,
      fileName: 'dark_report_preview.png',
    );
  });

  testWidgets('visual evidence captures required csv import mobile states', (
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
      await fixture.repository.upsert(_existingCsvDuplicateRecord());
    });

    final csvFile = await tester.runAsync(
      () => fixture.writeTextSource('visual-import.csv', _csvImportCsv),
    );
    final visualCsvFile = csvFile!;

    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collection,
      dependencies: fixture.dependencies,
      fileName: 'issue-108-csv-entry-mobile.png',
      ensureVisibleFinder: find.text('Import CSV', skipOffstage: false),
    );
    await captureCsvImportPreviewVisualEvidence(
      tester,
      dependencies: fixture.dependencies,
      csvPath: visualCsvFile.path,
      fileName: 'issue-108-csv-preview-mobile.png',
    );
    await captureCsvImportSuccessVisualEvidence(
      tester,
      dependencies: fixture.dependenciesWithFlags(
        csvImportFilePicker: _SingleCsvPicker(visualCsvFile),
      ),
      fileName: 'issue-108-csv-success-mobile.png',
    );
  });

  testWidgets('visual evidence captures supporting record mobile states', (
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
          id: 'supporting-visual',
          title: 'Supporting Visual Artwork',
          state: ArtworkRecordState.verifiedByYou,
          source: ArtworkFieldSource.userConfirmed,
        ),
      );
      await fixture.addPrimaryImage(artworkId: 'supporting-visual');
      await fixture.addSupportingPhoto(
        artworkId: 'supporting-visual',
        fileName: 'supporting-visual-detail.png',
      );
    });

    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkDocuments('supporting-visual'),
      dependencies: fixture.dependencies,
      fileName: 'issue-113-documents-mobile.png',
      ensureVisibleFinder: find.text(
        'Import supporting photo',
        skipOffstage: false,
      ),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkSupportingPhotoImport('supporting-visual'),
      dependencies: fixture.dependencies,
      fileName: 'issue-113-supporting-intake-mobile.png',
      ensureVisibleFinder: find.text(
        'Choose supporting photo',
        skipOffstage: false,
      ),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collection,
      dependencies: fixture.dependencies,
      fileName: 'issue-113-saved-list-mobile.png',
      ensureVisibleFinder: find.text(
        '1 supporting record attached.',
        skipOffstage: false,
      ),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkReportPreview('supporting-visual'),
      dependencies: fixture.dependencies,
      fileName: 'issue-113-report-preview-mobile.png',
      ensureVisibleFinder: find.text(
        '1 supporting record listed.',
        skipOffstage: false,
      ),
    );
  });

  testWidgets('visual evidence captures document affordance states', (
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
          id: 'document-visual',
          title: 'Document Visual Artwork',
          state: ArtworkRecordState.verifiedByYou,
          source: ArtworkFieldSource.userConfirmed,
        ),
      );
      await fixture.addPrimaryImage(artworkId: 'document-visual');
    });
    final supportingSource = await tester.runAsync(
      () => fixture.writePngSource('document-visual-receipt-photo.png'),
    );
    final missingSource = File(p.join(fixture.tempDir.path, 'missing.png'));

    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collectionAdd,
      fileName: 'issue-130-add-artwork-document-gated.png',
      ensureVisibleFinder: find.text(
        'Document upload unavailable',
        skipOffstage: false,
      ),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkDetails('document-visual'),
      dependencies: fixture.dependencies,
      fileName: 'issue-130-detail-supporting-records-action.png',
      ensureVisibleFinder: find.text(
        'Add supporting records',
        skipOffstage: false,
      ),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkDocuments('document-visual'),
      dependencies: fixture.dependencies,
      fileName: 'issue-130-documents-empty-gated.png',
      ensureVisibleFinder: find.text(
        'Missing-file recovery preview',
        skipOffstage: false,
      ),
    );
    await captureSupportingPhotoActionVisualEvidence(
      tester,
      dependencies: fixture.dependenciesWithPicker(
        _SingleImagePicker(supportingSource!),
      ),
      fileName: 'issue-130-supporting-photo-success.png',
      settledState: find.text('Supporting photo imported'),
    );
    await captureSupportingPhotoActionVisualEvidence(
      tester,
      dependencies: fixture.dependencies,
      fileName: 'issue-130-supporting-photo-cancelled.png',
      settledState: find.textContaining(
        'Supporting photo import was cancelled.',
      ),
    );
    await captureSupportingPhotoActionVisualEvidence(
      tester,
      dependencies: fixture.dependenciesWithPicker(
        _SingleImagePicker(missingSource),
      ),
      fileName: 'issue-130-supporting-photo-missing-file.png',
      settledState: find.textContaining(
        'The selected file could not be found.',
      ),
    );
  });

  testWidgets('visual evidence captures placeholder confirmation states', (
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
      await fixture.repository.upsert(_placeholderDraftRecord());
      await fixture.addPrimaryImage(artworkId: 'placeholder-draft');
    });

    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkEdit('placeholder-draft'),
      dependencies: fixture.dependencies,
      ensureVisibleFinder: find.text('Save user-confirmed fields'),
      fileName: 'issue-129-01-edit-placeholder-draft.png',
    );

    await capturePlaceholderSaveVisualEvidence(
      tester,
      dependencies: fixture.dependencies,
      fileName: 'issue-129-02-after-save-draft.png',
    );

    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkDetails('placeholder-draft'),
      dependencies: fixture.dependencies,
      ensureVisibleFinder: find.text('Record state: Needs review'),
      fileName: 'issue-129-03-detail-needs-review.png',
    );

    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collectionIncomplete,
      dependencies: fixture.dependencies,
      fileName: 'issue-129-04-incomplete-queue.png',
    );

    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkReportPreview('placeholder-draft'),
      dependencies: fixture.dependencies,
      fileName: 'issue-129-05-report-preview.png',
    );
  });

  testWidgets('visual evidence captures import intake failure states', (
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

    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.import,
      dependencies: fixture.dependencies,
      fileName: 'issue-127-01-import-entry.png',
      ensureVisibleFinder: find.text('Choose from system picker'),
    );
    await captureImportActionVisualEvidence(
      tester,
      dependencies: fixture.dependencies,
      actionLabel: 'Choose from system picker',
      settledState: find.text('Import cancelled'),
      fileName: 'issue-127-02-import-cancelled.png',
    );
    await captureImportActionVisualEvidence(
      tester,
      dependencies: fixture.dependencies,
      actionLabel: 'Recover interrupted import',
      settledState: find.text('Import needs attention'),
      fileName: 'issue-127-03-recover-unavailable.png',
    );
  });

  testWidgets('collection shell renders and can open add artwork', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const ArchivaleApp(initialRoute: AppRoutes.collection),
    );
    await pumpReady(tester);

    expect(find.text('Collection'), findsWidgets);
    expect(find.text('Incomplete'), findsOneWidget);
    expect(find.text('Reports'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('No artworks yet'), findsOneWidget);
    expect(find.text('Blue Interior Study'), findsNothing);
    expect(find.text('Import CSV'), findsOneWidget);

    await tapVisible(tester, find.widgetWithText(FilledButton, 'Add artwork'));

    expect(find.text('Add artwork'), findsWidgets);
    expect(find.text('Take photo'), findsOneWidget);
    expect(find.text('Import photo'), findsOneWidget);
    expect(find.byKey(const ValueKey('evidence-photo-guide')), findsOneWidget);
    expect(find.text('Evidence photo checklist'), findsOneWidget);
    expect(find.textContaining('signature or maker marks'), findsOneWidget);
    expect(find.textContaining('70/250'), findsOneWidget);
    expect(find.textContaining('Back, frame, label'), findsOneWidget);
    expect(
      find.textContaining('do not confirm attribution or value'),
      findsOneWidget,
    );
    expect(find.textContaining('prove authenticity'), findsNothing);
    expect(find.textContaining('appraise value'), findsNothing);
  });

  testWidgets(
    'csv import entry shows privacy framing, mapping edits, preview categories, and cancel with no write',
    (WidgetTester tester) async {
      final testDependencies = await tester.runAsync(
        () async => _LiveDependencyFixture.create(),
      );
      final fixture = testDependencies!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.dispose);
      });

      await tester.runAsync(() async {
        await fixture.repository.upsert(_existingCsvDuplicateRecord());
      });

      final csvFile = await tester.runAsync(
        () => fixture.writeTextSource('collector-import.csv', _csvImportCsv),
      );

      await tester.pumpWidget(
        ArchivaleApp(
          initialRoute: AppRoutes.collectionImportCsv,
          dependencies: fixture.dependencies,
        ),
      );
      await pumpLiveData(tester);

      expect(find.text('Import collector CSV'), findsOneWidget);
      expect(find.text('Private local records only'), findsOneWidget);
      expect(find.text('Local-only CSV review'), findsOneWidget);
      expect(find.textContaining('does not connect to Drive'), findsOneWidget);
      expect(find.text('Choose CSV file'), findsOneWidget);
      expect(find.text('Load test harness path'), findsOneWidget);
      expect(find.text('Choose from system picker'), findsNothing);

      await enterVisibleText(
        tester,
        find.byKey(const ValueKey('csv-test-harness-path-field')),
        csvFile!.path,
      );
      await pressAsyncButton(
        tester,
        find.widgetWithText(OutlinedButton, 'Load test harness path'),
      );
      await waitForFinder(
        tester,
        find.byKey(const ValueKey('csv-mapping-Work Name')),
      );
      await selectDropdownItem(
        tester,
        find.byKey(const ValueKey('csv-mapping-Work Name')),
        'field:title',
      );
      await pumpLiveData(tester);

      expect(find.text('Preview categories'), findsOneWidget);
      expect(find.text('Ready: 1'), findsOneWidget);
      expect(find.text('Warning: 1'), findsOneWidget);
      expect(find.text('Duplicate candidate: 1'), findsOneWidget);
      expect(find.text('Blocked: 1'), findsOneWidget);
      expect(find.text('Skip'), findsOneWidget);
      expect(find.text('Import as new'), findsOneWidget);

      await tapVisible(tester, find.text('Cancel without writing'));

      final recordsAfterCancel = await tester.runAsync(fixture.repository.list);
      expect(recordsAfterCancel!.map((record) => record.id), ['existing-001']);
      expect(find.text('Choose CSV file'), findsOneWidget);
      expect(find.text('Preview categories'), findsNothing);
    },
  );

  testWidgets(
    'csv import can load from file picker, confirm writes, and open an imported record',
    (WidgetTester tester) async {
      final testDependencies = await tester.runAsync(
        () async => _LiveDependencyFixture.create(),
      );
      final fixture = testDependencies!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.dispose);
      });

      await tester.runAsync(() async {
        await fixture.repository.upsert(_existingCsvDuplicateRecord());
      });

      final csvFile = await tester.runAsync(
        () => fixture.writeTextSource('picker-import.csv', _csvImportCsv),
      );

      await tester.pumpWidget(
        ArchivaleApp(
          initialRoute: AppRoutes.collectionImportCsv,
          dependencies: fixture.dependenciesWithFlags(
            csvImportFilePicker: _SingleCsvPicker(csvFile!),
          ),
        ),
      );
      await pumpLiveData(tester);

      await pressAsyncButton(
        tester,
        find.widgetWithText(FilledButton, 'Choose CSV file'),
      );
      await waitForFinder(
        tester,
        find.byKey(const ValueKey('csv-mapping-Work Name')),
      );
      await selectDropdownItem(
        tester,
        find.byKey(const ValueKey('csv-mapping-Work Name')),
        'field:title',
      );
      await pumpLiveData(tester);
      await tapVisible(tester, find.text('Import as new'));
      await pressAsyncButton(
        tester,
        find.widgetWithText(FilledButton, 'Confirm local import'),
      );

      expect(find.text('Local CSV import complete'), findsOneWidget);
      expect(find.text('Imported records: 3'), findsOneWidget);
      expect(find.text('Skipped duplicate candidates: 0'), findsOneWidget);
      expect(find.text('Imported with warnings: 1'), findsOneWidget);
      expect(find.text('Blocked rows left unchanged: 1'), findsOneWidget);

      final recordsAfterImport = await tester.runAsync(fixture.repository.list);
      expect(recordsAfterImport, hasLength(4));
      expect(
        recordsAfterImport!
            .where(
              (record) =>
                  record.field(ArtworkFieldKeys.title)?.value == 'Fresh Harbor',
            )
            .single
            .primaryImageAttachmentId,
        isNull,
      );
      expect(
        recordsAfterImport.any(
          (record) =>
              record.field(ArtworkFieldKeys.title)?.value == 'Blue Interior' &&
              record.id != 'existing-001',
        ),
        isTrue,
      );

      await tapVisible(tester, find.text('Open first imported record'));
      await pumpLiveData(tester);

      expect(find.text('Draft review'), findsWidgets);
      expect(find.text('Fresh Harbor'), findsWidgets);
      expect(find.text('Add evidence photos next'), findsOneWidget);
    },
  );

  testWidgets('collection shell localizes supported mobile locales', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final expectedLabels = <Locale, List<String>>{
      const Locale('en'): ['Collection', 'Incomplete', 'Reports', 'Settings'],
      const Locale('nb'): [
        'Samling',
        'Ufullstendig',
        'Rapporter',
        'Innstillinger',
      ],
      const Locale('de'): [
        'Sammlung',
        'Unvollstaendig',
        'Berichte',
        'Einstellungen',
      ],
      const Locale('fr'): ['Collection', 'Incomplet', 'Rapports', 'Reglages'],
    };

    for (final entry in expectedLabels.entries) {
      await tester.pumpWidget(
        ArchivaleApp(initialRoute: AppRoutes.collection, locale: entry.key),
      );
      await pumpReady(tester);

      for (final label in entry.value) {
        expect(find.text(label), findsWidgets);
      }

      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('first artwork prototype reaches report and export preview', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const ArchivaleApp(initialRoute: AppRoutes.collection),
    );
    await pumpReady(tester);

    await tapVisible(tester, find.widgetWithText(FilledButton, 'Add artwork'));
    await tapVisible(tester, find.text('Import photo'));
    expect(find.text('Photo imported'), findsOneWidget);
    expect(find.text('Upload-failure state'), findsNothing);

    await tapVisible(tester, find.text('Review AI draft'));
    expect(find.text('AI draft review'), findsWidgets);
    expect(find.text('AI-suggested'), findsWidgets);
    expect(find.text('User confirmed'), findsOneWidget);
    expect(find.text('Document-extracted'), findsOneWidget);
    expect(find.text('Unknown'), findsOneWidget);

    await tapVisible(tester, find.text('Confirm suggested fields'));
    expect(find.text('Verified by you'), findsNothing);
    expect(find.text('Blue Interior Study'), findsWidgets);
    expect(find.text('Record state: Needs review'), findsOneWidget);
    expect(
      find.text('3 of 8 core fields are user-confirmed or document-reviewed.'),
      findsOneWidget,
    );

    await tapVisible(tester, find.text('Add supporting records'));
    expect(find.text('Documents'), findsWidgets);
    expect(find.text('gallery-receipt-2025.pdf'), findsOneWidget);
    expect(find.text('Document upload unavailable'), findsOneWidget);
    expect(find.text('Missing-file recovery preview'), findsOneWidget);

    await tapVisible(
      tester,
      find.widgetWithText(OutlinedButton, 'Report preview').last,
    );
    expect(find.text('Generate an insurance-ready PDF'), findsWidgets);
    expect(find.text('Purchase price: USD 1,800.'), findsOneWidget);
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
      ArchivaleApp(
        initialRoute: AppRoutes.import,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpReady(tester);

    expect(find.text('Use system photo picker'), findsOneWidget);
    expect(find.text('Evidence photo checklist'), findsOneWidget);
    expect(find.text('Choose from system picker'), findsOneWidget);
    expect(find.text('Recover interrupted import'), findsOneWidget);
    expect(find.text('Upload-failure state'), findsNothing);

    await tapVisible(tester, find.text('Recover interrupted import'));

    expect(find.text('Import needs attention'), findsOneWidget);
    expect(
      find.textContaining('No interrupted import was available.'),
      findsOneWidget,
    );
    expect(find.text('Evidence photo checklist'), findsOneWidget);
    expect(find.textContaining('prints or lithographs'), findsOneWidget);
    expect(find.textContaining('Receipts, certificates'), findsOneWidget);
    expect(find.text('Choose from system picker'), findsOneWidget);
    expect(find.text('Recover interrupted import'), findsOneWidget);
    expect(find.text('Upload-failure state'), findsNothing);
  });

  testWidgets('live import flow shows cancelled picker state', (
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
      ArchivaleApp(
        initialRoute: AppRoutes.import,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpReady(tester);

    await tapVisible(tester, find.text('Choose from system picker'));

    expect(find.text('Import cancelled'), findsOneWidget);
    expect(find.textContaining('Photo import was cancelled.'), findsOneWidget);
    expect(find.text('Import needs attention'), findsNothing);
    expect(find.text('Choose from system picker'), findsOneWidget);
    expect(find.text('Recover interrupted import'), findsOneWidget);
    expect(find.text('Upload-failure state'), findsNothing);
  });

  testWidgets('live import success displays the saved primary image', (
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

    final sourceImage = await tester.runAsync(
      () => fixture.writePngSource('picker-primary.png'),
    );

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.import,
        dependencies: fixture.dependenciesWithPicker(
          _SingleImagePicker(sourceImage!),
        ),
      ),
    );
    await pumpReady(tester);

    await tester.runAsync(() async {
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Choose from system picker'),
      );
      button.onPressed!();
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await pumpLiveData(tester);

    expect(find.text('Photo imported'), findsOneWidget);
    expect(find.text('On-device AI unavailable'), findsOneWidget);
    expect(find.textContaining('No photo was sent online'), findsOneWidget);
    expect(find.text('Review draft'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('primary-artwork-image-preview')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('primary-artwork-image-placeholder')),
      findsNothing,
    );
  });

  testWidgets(
    'existing artwork can import supporting photo without replacing primary image',
    (WidgetTester tester) async {
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
            id: 'supporting-ui',
            title: 'Supporting UI Artwork',
            state: ArtworkRecordState.verifiedByYou,
            source: ArtworkFieldSource.userConfirmed,
          ),
        );
        await fixture.addPrimaryImage(artworkId: 'supporting-ui');
      });
      final supportingSource = await tester.runAsync(
        () => fixture.writePngSource('signature-detail.png'),
      );

      await tester.pumpWidget(
        ArchivaleApp(
          initialRoute: AppRoutes.artworkDetails('supporting-ui'),
          dependencies: fixture.dependenciesWithPicker(
            _SingleImagePicker(supportingSource!),
          ),
        ),
      );
      await pumpLiveData(tester);

      expect(find.text('Supporting UI Artwork'), findsWidgets);

      await tapVisible(tester, find.text('Add supporting records'));
      await pumpLiveData(tester);

      expect(find.text('Documents'), findsWidgets);
      expect(find.text('No supporting records yet'), findsOneWidget);
      expect(find.text('Take supporting photo'), findsOneWidget);
      expect(find.text('Import supporting photo'), findsOneWidget);

      await tapVisible(tester, find.text('Import supporting photo'));
      await pumpLiveData(tester);
      expect(find.text('Import supporting photo'), findsWidgets);
      expect(find.text('Supporting UI Artwork'), findsWidgets);
      expect(find.text('Artwork-scoped save'), findsOneWidget);

      await pressAsyncButton(
        tester,
        find.widgetWithText(FilledButton, 'Choose supporting photo'),
      );

      expect(find.text('Supporting photo imported'), findsOneWidget);
      expect(
        find.text(
          'Saved as a supporting record. The primary artwork image is unchanged.',
        ),
        findsOneWidget,
      );
      expect(find.text('View supporting records'), findsOneWidget);

      final savedRecord = await tester.runAsync(
        () => fixture.repository.get('supporting-ui'),
      );
      expect(savedRecord!.primaryImageAttachmentId, 'primary-supporting-ui');
      final attachments = await tester.runAsync(
        () => fixture.repository.attachmentsForArtwork('supporting-ui'),
      );
      expect(attachments, isNotNull);
      expect(
        attachments!
            .where(
              (attachment) =>
                  attachment.role == AttachmentRole.supportingPhoto &&
                  attachment.type == AttachmentType.photo,
            )
            .length,
        1,
      );
      expect(
        attachments.where(
          (attachment) => attachment.id == 'primary-supporting-ui',
        ),
        hasLength(1),
      );

      await tapVisible(tester, find.text('View supporting records'));
      await pumpLiveData(tester);

      expect(find.text('Supporting photo'), findsOneWidget);
      expect(find.text('signature-detail.png'), findsOneWidget);
      expect(find.text('No supporting records yet'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        ArchivaleApp(
          initialRoute: AppRoutes.collection,
          dependencies: fixture.dependencies,
        ),
      );
      await pumpLiveData(tester);

      expect(find.text('Supporting UI Artwork'), findsOneWidget);
      expect(find.text('1 supporting record attached.'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        ArchivaleApp(
          initialRoute: AppRoutes.artworkReportPreview('supporting-ui'),
          dependencies: fixture.dependencies,
        ),
      );
      await pumpLiveData(tester);

      expect(find.text('Report preview'), findsWidgets);
      expect(find.text('1 supporting record listed.'), findsOneWidget);
    },
  );

  testWidgets('document upload affordances are gated when unavailable', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const ArchivaleApp(initialRoute: AppRoutes.collectionAdd),
    );
    await pumpReady(tester);

    expect(find.text('Document upload unavailable'), findsOneWidget);
    expect(find.text('Attach document'), findsNothing);
    expect(find.byIcon(Icons.attach_file), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Attach document'),
      findsNothing,
    );

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
          id: 'document-gated',
          title: 'Document Gated Artwork',
          state: ArtworkRecordState.verifiedByYou,
          source: ArtworkFieldSource.userConfirmed,
        ),
      );
      await fixture.addPrimaryImage(artworkId: 'document-gated');
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkDocuments('document-gated'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('No supporting records yet'), findsOneWidget);
    expect(find.text('Take supporting photo'), findsOneWidget);
    expect(find.text('Import supporting photo'), findsOneWidget);
    expect(find.text('Document upload unavailable'), findsOneWidget);
    expect(find.text('Missing-file recovery preview'), findsOneWidget);
    expect(find.text('Attach document'), findsNothing);
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
      ArchivaleApp(
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

  testWidgets('cold start opens collection when local records exist', (
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

    final emptyRoute = await tester.runAsync(
      () => initialRouteForRepository(fixture.repository),
    );
    expect(emptyRoute, AppRoutes.splash);

    await tester.runAsync(() async {
      await fixture.repository.upsert(
        _artworkRecord(
          id: 'cold-start-local-record',
          title: 'Cold Start Local Record',
          state: ArtworkRecordState.needsReview,
        ),
      );
      await fixture.reopenRepository();
    });

    final existingRecordsRoute = await tester.runAsync(
      () => initialRouteForRepository(fixture.repository),
    );
    expect(existingRecordsRoute, AppRoutes.collection);

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: existingRecordsRoute!,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Collection'), findsWidgets);
    expect(find.text('Cold Start Local Record'), findsOneWidget);
    expect(find.text('Private artwork records'), findsNothing);
  });

  testWidgets('collection and draft show local primary image preview', (
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
          id: 'local-photo',
          title: 'Photo Preview Artwork',
          state: ArtworkRecordState.needsReview,
        ),
      );
      await fixture.addPrimaryImage(artworkId: 'local-photo');
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.collection,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Photo Preview Artwork'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('primary-artwork-image-preview')),
      findsOneWidget,
    );

    await tapVisible(tester, find.text('Resume draft'));
    await pumpLiveData(tester);
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();

    expect(find.text('Draft review'), findsWidgets);
    expect(find.text('Add evidence photos next'), findsOneWidget);
    expect(find.textContaining('better clues'), findsOneWidget);
    expect(find.textContaining('signature or maker marks'), findsOneWidget);
    expect(find.text('Private AI draft'), findsOneWidget);
    expect(find.textContaining('has not run for this photo'), findsOneWidget);
    expect(find.text('Photo Preview Artwork'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('primary-artwork-image-preview')),
      findsOneWidget,
    );
    expect(find.text('AI-suggested'), findsNothing);
    expect(find.text('Unknown'), findsWidgets);

    await tapVisible(tester, find.text('Continue review'));
    await pumpLiveData(tester);
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();

    expect(find.text('Verified by you'), findsNothing);
    expect(find.text('Record state: Needs review'), findsOneWidget);
    expect(find.text('Photo Preview Artwork'), findsWidgets);
    expect(
      find.byKey(const ValueKey('primary-artwork-image-preview')),
      findsOneWidget,
    );
    expect(find.text('Primary image fixture'), findsNothing);
  });

  testWidgets('local draft route first frame is neutral while loading', (
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
          id: 'neutral-loading-draft',
          title: 'Neutral Loading Draft',
          state: ArtworkRecordState.needsReview,
          missingFieldKeys: {ArtworkFieldKeys.artist},
        ),
      );
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkDraft('neutral-loading-draft'),
        dependencies: fixture.dependencies,
      ),
    );

    expect(find.text('Loading artwork'), findsWidgets);
    expect(find.text('Opening local record'), findsOneWidget);
    expect(find.text('AI draft review'), findsNothing);
    expect(find.text('AI-suggested'), findsNothing);

    await pumpLiveData(tester);

    expect(find.text('Draft review'), findsWidgets);
    expect(find.text('Local draft. Please confirm.'), findsOneWidget);
    expect(find.text('Neutral Loading Draft'), findsWidgets);
    expect(find.text('AI-suggested'), findsNothing);
  });

  testWidgets('missing primary image fallback does not leak storage paths', (
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
    const secretRelativePath =
        'artworks/missing-image/attachments/private-secret-file.png';

    await tester.runAsync(() async {
      await fixture.repository.upsert(
        _artworkRecord(
          id: 'missing-image',
          title: 'Missing Preview Artwork',
          state: ArtworkRecordState.needsReview,
        ),
      );
      await fixture.repository.addAttachment(
        _primaryImageAttachmentRecord(
          id: 'primary-missing-image',
          artworkId: 'missing-image',
          relativePath: secretRelativePath,
        ),
      );
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.collection,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Missing Preview Artwork'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('primary-artwork-image-placeholder')),
      findsOneWidget,
    );
    expect(find.textContaining('private-secret'), findsNothing);
    expect(find.textContaining('artworks/missing-image'), findsNothing);
    expect(find.textContaining(fixture.tempDir.path), findsNothing);

    await tapVisible(tester, find.text('Resume draft'));
    await pumpLiveData(tester);

    expect(find.text('Draft review'), findsWidgets);
    expect(
      find.byKey(const ValueKey('primary-artwork-image-placeholder')),
      findsOneWidget,
    );
    expect(find.textContaining('private-secret'), findsNothing);
    expect(find.textContaining('artworks/missing-image'), findsNothing);
    expect(find.textContaining(fixture.tempDir.path), findsNothing);
  });

  testWidgets('private on-device AI draft displays after live import', (
    WidgetTester tester,
  ) async {
    final testDependencies = await tester.runAsync(
      () async => _LiveDependencyFixture.create(
        onDeviceAiDraftProvider: const _CompletedAiDraftProvider(),
      ),
    );
    final fixture = testDependencies!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.dispose);
    });

    final sourceImage = await tester.runAsync(
      () => fixture.writePngSource('picker-ai-primary.png'),
    );

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.import,
        dependencies: fixture.dependenciesWithPicker(
          _SingleImagePicker(sourceImage!),
        ),
      ),
    );
    await pumpReady(tester);

    await tester.runAsync(() async {
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Choose from system picker'),
      );
      button.onPressed!();
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await pumpLiveData(tester);

    expect(find.text('Photo imported'), findsOneWidget);
    expect(find.text('Private AI draft saved'), findsOneWidget);
    expect(
      find.textContaining('Visible lower-right signature'),
      findsOneWidget,
    );

    await tapVisible(tester, find.text('Review AI draft'));
    await pumpLiveData(tester);
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();

    expect(find.text('AI draft review'), findsWidgets);
    expect(find.text('Private AI draft saved'), findsOneWidget);
    expect(find.textContaining('AI-suggested only'), findsOneWidget);
    expect(find.text('User confirmed'), findsNothing);
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
      ArchivaleApp(
        initialRoute: AppRoutes.collectionIncomplete,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Needs Local Review needs review'), findsOneWidget);
    expect(
      find.text('Needs Local Review needs supporting records'),
      findsOneWidget,
    );
    expect(find.text('Complete Local Record needs review'), findsNothing);
    expect(
      find.text('Complete Local Record needs supporting records'),
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
      ArchivaleApp(
        initialRoute: AppRoutes.collectionIncomplete,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Needs Local Review needs review'), findsNothing);
    expect(
      find.text('Needs Local Review needs supporting records'),
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
      ArchivaleApp(
        initialRoute: AppRoutes.collectionIncomplete,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Draft Route Artwork has missing values'), findsOneWidget);

    await tester.tap(find.text('Open record'));
    await pumpReady(tester);
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();

    expect(find.text('Draft review'), findsWidgets);
    expect(find.text('Local draft. Please confirm.'), findsOneWidget);
    expect(find.text('AI-suggested'), findsNothing);
    expect(find.text('Unknown'), findsWidgets);
    expect(find.text('Verified by you'), findsNothing);
  });

  testWidgets(
    'lifecycle controls persist non-active statuses and soft remove',
    (WidgetTester tester) async {
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
            id: 'lifecycle-ui',
            title: 'Lifecycle UI Artwork',
            state: ArtworkRecordState.verifiedByYou,
            source: ArtworkFieldSource.userConfirmed,
          ),
        );
        await fixture.repository.addAttachment(
          _attachmentRecord(
            id: 'lifecycle-receipt',
            artworkId: 'lifecycle-ui',
            type: AttachmentType.receipt,
          ),
        );
      });

      await tester.pumpWidget(
        ArchivaleApp(
          initialRoute: AppRoutes.collection,
          dependencies: fixture.dependencies,
        ),
      );
      await pumpLiveData(tester);

      expect(find.text('Lifecycle UI Artwork'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);

      await tapVisible(tester, find.text('Open record'));
      await pumpLiveData(tester);

      expect(find.text('Lifecycle status'), findsOneWidget);
      expect(
        find.text('This artwork is treated as a current holding.'),
        findsOneWidget,
      );

      await tapVisible(tester, find.widgetWithText(ActionChip, 'Sold'));
      await pumpLiveData(tester);
      expect(
        find.text('This artwork is retained in your records but marked sold.'),
        findsOneWidget,
      );

      ArtworkRecord? saved = await tester.runAsync<ArtworkRecord?>(
        () => fixture.repository.get('lifecycle-ui'),
      );
      expect(saved?.lifecycleStatus, ArtworkLifecycleStatus.sold);

      await tapVisible(tester, find.widgetWithText(ActionChip, 'Lost'));
      await pumpLiveData(tester);
      saved = await tester.runAsync<ArtworkRecord?>(
        () => fixture.repository.get('lifecycle-ui'),
      );
      expect(saved?.lifecycleStatus, ArtworkLifecycleStatus.lost);

      await tapVisible(tester, find.widgetWithText(ActionChip, 'Stolen'));
      await pumpLiveData(tester);
      saved = await tester.runAsync<ArtworkRecord?>(
        () => fixture.repository.get('lifecycle-ui'),
      );
      expect(saved?.lifecycleStatus, ArtworkLifecycleStatus.stolen);

      await tapVisible(tester, find.widgetWithText(ActionChip, 'Removed'));
      expect(find.text('Remove from current holdings?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await pumpReady(tester);
      saved = await tester.runAsync<ArtworkRecord?>(
        () => fixture.repository.get('lifecycle-ui'),
      );
      expect(saved?.lifecycleStatus, ArtworkLifecycleStatus.stolen);

      await tapVisible(tester, find.widgetWithText(ActionChip, 'Removed'));
      expect(find.text('Remove from current holdings?'), findsOneWidget);
      await tester.tap(find.text('Mark removed'));
      await pumpLiveData(tester);

      saved = await tester.runAsync<ArtworkRecord?>(
        () => fixture.repository.get('lifecycle-ui'),
      );
      expect(saved?.lifecycleStatus, ArtworkLifecycleStatus.removed);

      await tester.runAsync(fixture.reopenRepository);
      saved = await tester.runAsync<ArtworkRecord?>(
        () => fixture.repository.get('lifecycle-ui'),
      );
      expect(saved?.lifecycleStatus, ArtworkLifecycleStatus.removed);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        ArchivaleApp(
          initialRoute: AppRoutes.collection,
          dependencies: fixture.dependencies,
        ),
      );
      await pumpLiveData(tester);

      expect(find.text('Lifecycle UI Artwork'), findsOneWidget);
      expect(find.text('Removed'), findsOneWidget);
      expect(
        find.textContaining('Marked removed; retained in the local record.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('incomplete queue separates non-active lifecycle records', (
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
          id: 'sold-incomplete',
          title: 'Sold Incomplete Artwork',
          state: ArtworkRecordState.needsReview,
          lifecycleStatus: ArtworkLifecycleStatus.sold,
        ),
      );
      await fixture.repository.upsert(
        _artworkRecord(
          id: 'removed-incomplete',
          title: 'Removed Incomplete Artwork',
          state: ArtworkRecordState.needsReview,
          lifecycleStatus: ArtworkLifecycleStatus.removed,
        ),
      );
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.collectionIncomplete,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Sold Incomplete Artwork is marked sold'), findsOneWidget);
    expect(
      find.textContaining('not treated as a current incomplete holding'),
      findsOneWidget,
    );
    expect(find.text('Sold Incomplete Artwork needs review'), findsNothing);
    expect(
      find.text('Sold Incomplete Artwork needs supporting records'),
      findsNothing,
    );
    expect(find.textContaining('Removed Incomplete Artwork'), findsNothing);
  });

  testWidgets('saving unchanged placeholder draft does not verify defaults', (
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
      await fixture.repository.upsert(_placeholderDraftRecord());
      await fixture.addPrimaryImage(artworkId: 'placeholder-draft');
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkEdit('placeholder-draft'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Untitled artwork'), findsOneWidget);
    expect(find.text('Unknown'), findsOneWidget);
    expect(find.text('Needs review'), findsWidgets);

    await tapVisible(tester, find.text('Save user-confirmed fields'));
    await pumpLiveData(tester);

    final saved = await tester.runAsync(
      () => fixture.repository.get('placeholder-draft'),
    );
    expect(saved, isNotNull);
    expect(saved!.recordState, ArtworkRecordState.needsReview);
    expect(
      saved.field(ArtworkFieldKeys.title)?.source,
      ArtworkFieldSource.unknown,
    );
    expect(saved.field(ArtworkFieldKeys.title)?.lastConfirmedAt, isNull);
    expect(
      saved.field(ArtworkFieldKeys.conditionNotes)?.source,
      ArtworkFieldSource.unknown,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkDetails('placeholder-draft'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();

    expect(find.text('Record state: Needs review'), findsOneWidget);
    expect(
      find.text('0 of 8 core fields are user-confirmed or document-reviewed.'),
      findsOneWidget,
    );
    expect(find.text('Verified by you'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.collectionIncomplete,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Untitled artwork needs review'), findsOneWidget);
    expect(find.text('Untitled artwork has missing values'), findsOneWidget);
  });

  testWidgets('partially edited placeholder draft stays in review', (
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
        _placeholderDraftRecord(id: 'partial-placeholder-draft'),
      );
      await fixture.addPrimaryImage(artworkId: 'partial-placeholder-draft');
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkEdit('partial-placeholder-draft'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    await enterVisibleText(
      tester,
      find.byKey(const ValueKey('artwork-edit-title')),
      'Confirmed Partial Title',
    );
    await tapVisible(tester, find.text('Save user-confirmed fields'));
    await pumpLiveData(tester);

    final saved = await tester.runAsync(
      () => fixture.repository.get('partial-placeholder-draft'),
    );
    expect(saved, isNotNull);
    expect(saved!.recordState, ArtworkRecordState.needsReview);
    expect(
      saved.field(ArtworkFieldKeys.title)?.source,
      ArtworkFieldSource.userConfirmed,
    );
    expect(
      saved.field(ArtworkFieldKeys.artist)?.source,
      ArtworkFieldSource.unknown,
    );
    expect(saved.field(ArtworkFieldKeys.artist)?.lastConfirmedAt, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkDetails('partial-placeholder-draft'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();

    expect(find.text('Confirmed Partial Title'), findsWidgets);
    expect(find.text('Record state: Needs review'), findsOneWidget);
    expect(
      find.text('1 of 8 core fields are user-confirmed or document-reviewed.'),
      findsOneWidget,
    );
    expect(find.text('Verified by you'), findsNothing);
  });

  testWidgets('manual edits persist as user-confirmed local fields', (
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
          id: 'manual-edit',
          title: 'AI Draft Title',
          state: ArtworkRecordState.needsReview,
          source: ArtworkFieldSource.aiSuggested,
        ),
      );
      await fixture.addPrimaryImage(artworkId: 'manual-edit');
      await fixture.repository.upsertResearchJob(
        _researchJob(artworkId: 'manual-edit'),
      );
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkDraft('manual-edit'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Draft review'), findsWidgets);
    expect(find.text('AI Draft Title'), findsWidgets);
    expect(find.text('AI-suggested'), findsWidgets);

    await tapVisible(tester, find.text('Edit record fields'));
    await pumpLiveData(tester);
    expect(find.text('Your values outrank AI suggestions'), findsOneWidget);

    await enterVisibleText(
      tester,
      find.byKey(const ValueKey('artwork-edit-title')),
      'Manual Confirmed Title',
    );
    await enterVisibleText(
      tester,
      find.byKey(const ValueKey('artwork-edit-artist')),
      'Manual Artist',
    );
    await enterVisibleText(
      tester,
      find.byKey(const ValueKey('artwork-edit-year')),
      '1998',
    );
    await enterVisibleText(
      tester,
      find.byKey(const ValueKey('artwork-edit-medium')),
      'Lithograph on paper',
    );
    await enterVisibleText(
      tester,
      find.byKey(const ValueKey('artwork-edit-dimensions')),
      '30 x 40 cm',
    );
    await enterVisibleText(
      tester,
      find.byKey(const ValueKey('artwork-edit-current_location')),
      'Hallway',
    );
    await enterVisibleText(
      tester,
      find.byKey(const ValueKey('artwork-edit-insurance_value')),
      'NOK 12,000',
    );
    await enterVisibleText(
      tester,
      find.byKey(const ValueKey('artwork-edit-condition_notes')),
      'Small crease in lower-left margin.',
    );

    await tapVisible(tester, find.text('Save user-confirmed fields'));
    await pumpLiveData(tester);
    await tester.pump(const Duration(seconds: 1));
    await pumpLiveData(tester);

    expect(find.text('Draft review'), findsWidgets);
    expect(find.text('Manual Confirmed Title'), findsWidgets);
    expect(find.text('Manual Artist'), findsOneWidget);
    expect(find.text('User confirmed'), findsWidgets);

    var saved = await tester.runAsync(
      () => fixture.repository.get('manual-edit'),
    );
    expect(saved, isNotNull);
    expect(saved!.recordState, ArtworkRecordState.verifiedByYou);
    expect(
      saved.field(ArtworkFieldKeys.title)?.source,
      ArtworkFieldSource.userConfirmed,
    );
    expect(
      saved.field(ArtworkFieldKeys.title)?.value,
      'Manual Confirmed Title',
    );
    expect(
      saved.field(ArtworkFieldKeys.conditionNotes)?.value,
      contains('crease'),
    );
    expect(saved.field(ArtworkFieldKeys.title)?.lastConfirmedAt, isNotNull);

    final attachments = await tester.runAsync(
      () => fixture.repository.attachmentsForArtwork('manual-edit'),
    );
    expect(attachments, isNotNull);
    expect(attachments!, hasLength(1));

    final researchJobs = await tester.runAsync(
      () => fixture.repository.researchJobsForArtwork('manual-edit'),
    );
    expect(researchJobs, isNotNull);
    expect(researchJobs!, hasLength(1));
    expect(researchJobs.single.sourceHits, hasLength(1));

    await tester.runAsync(fixture.reopenRepository);
    saved = await tester.runAsync(() => fixture.repository.get('manual-edit'));
    expect(saved?.field(ArtworkFieldKeys.artist)?.value, 'Manual Artist');
    expect(
      saved?.field(ArtworkFieldKeys.artist)?.source,
      ArtworkFieldSource.userConfirmed,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.collection,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Manual Confirmed Title'), findsOneWidget);
    expect(find.text('Verified by you'), findsOneWidget);
    expect(
      find.text('1 incomplete queue item needs attention.'),
      findsOneWidget,
    );

    await tapVisible(tester, find.text('Open record'));
    await pumpLiveData(tester);

    expect(find.text('Verified by you'), findsWidgets);
    expect(find.text('Manual Confirmed Title'), findsWidgets);
    expect(find.text('Manual Artist'), findsOneWidget);
    expect(find.text('1998'), findsWidgets);
    expect(
      find.text('8 of 8 core fields are user-confirmed or document-reviewed.'),
      findsOneWidget,
    );
    expect(find.text('NOK 12,000'), findsOneWidget);
    expect(find.text('User confirmed'), findsWidgets);

    await tapVisible(tester, find.text('Report preview'));
    await pumpLiveData(tester);

    expect(find.text('Generate an insurance-ready PDF'), findsWidgets);
    expect(
      find.text('User-provided insurance value: NOK 12,000.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'structured money fields render in details, report, and export views',
    (WidgetTester tester) async {
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
            id: 'structured-money',
            title: 'Structured Money Artwork',
            state: ArtworkRecordState.verifiedByYou,
            source: ArtworkFieldSource.userConfirmed,
            overrides: {
              ArtworkFieldKeys.purchasePrice: const ArtworkFieldValue(
                value: 'legacy purchase note',
                source: ArtworkFieldSource.userConfirmed,
                note: 'Structured purchase price fixture.',
                moneyAmount: '1200.50',
                moneyCurrencyCode: 'USD',
              ),
              ArtworkFieldKeys.insuranceValue: const ArtworkFieldValue(
                value: 'legacy insurance note',
                source: ArtworkFieldSource.userConfirmed,
                note: 'Structured insurance value fixture.',
                moneyAmount: '12000',
                moneyCurrencyCode: 'NOK',
              ),
            },
          ),
        );
        await fixture.addPrimaryImage(artworkId: 'structured-money');
      });

      await tester.pumpWidget(
        ArchivaleApp(
          initialRoute: AppRoutes.artworkDetails('structured-money'),
          dependencies: fixture.dependencies,
        ),
      );
      await pumpLiveData(tester);

      expect(find.text('Structured Money Artwork'), findsWidgets);
      expect(find.text('USD 1,200.50'), findsOneWidget);
      expect(find.text('NOK 12,000'), findsOneWidget);
      expect(find.text('legacy purchase note'), findsNothing);
      expect(find.text('legacy insurance note'), findsNothing);

      await tapVisible(tester, find.text('Report preview'));
      await pumpLiveData(tester);

      expect(find.text('Purchase price: USD 1,200.50.'), findsOneWidget);
      expect(
        find.text('User-provided insurance value: NOK 12,000.'),
        findsOneWidget,
      );

      await tapVisible(tester, find.text('Export archive preview'));
      await pumpLiveData(tester);

      expect(find.text('Export record package'), findsWidgets);
      expect(find.text('Purchase price: USD 1,200.50.'), findsOneWidget);
      expect(
        find.text('User-provided insurance value: NOK 12,000.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('online research stays hidden by default', (
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
          id: 'research-draft',
          title: 'Interior Study',
          state: ArtworkRecordState.needsReview,
        ),
      );
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkDraft('research-draft'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Research online'), findsNothing);
    expect(find.text('Research consent'), findsNothing);
    expect(find.text('Source-backed candidates'), findsNothing);
    expect(find.text('Professional-source research disabled'), findsOneWidget);
  });

  testWidgets('online research requires consent and shows cited candidates', (
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
          id: 'research-draft',
          title: 'Interior Study',
          state: ArtworkRecordState.needsReview,
        ),
      );
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkDraft('research-draft'),
        dependencies: fixture.dependenciesWithFlags(
          featureFlags: const AppFeatureFlags(onlineResearchEnabled: true),
        ),
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Research online'), findsOneWidget);
    expect(find.text('Source-backed candidates'), findsNothing);

    await tapVisible(tester, find.text('Research online'));

    expect(find.text('Research consent'), findsOneWidget);
    expect(find.textContaining('what leaves this device'), findsNothing);
    expect(find.textContaining('selected artwork image'), findsOneWidget);
    expect(
      find.textContaining('Your full collection is not sent'),
      findsOneWidget,
    );

    await tapVisible(tester, find.text('Skip online research'));

    expect(find.text('Research online'), findsOneWidget);
    expect(find.text('Source-backed candidates'), findsNothing);

    await tapVisible(tester, find.text('Research online'));
    await tapVisible(tester, find.text('Allow professional research'));
    await pumpLiveData(tester);

    expect(find.text('Source-backed candidates'), findsOneWidget);
    expect(
      find.textContaining('2 professional-source citations found'),
      findsOneWidget,
    );
    expect(find.textContaining('The Met Collection'), findsWidgets);
    expect(find.textContaining('https://www.metmuseum.org/'), findsWidgets);
    expect(find.text('AI-suggested'), findsWidgets);

    await tester.ensureVisible(find.text('Comparable source signals'));
    await tester.pump();

    expect(find.text('Comparable source signals'), findsOneWidget);
    expect(find.text('No reliable comparable found'), findsOneWidget);
    expect(find.textContaining('Comparable amount'), findsNothing);
    expect(find.textContaining('Signal date'), findsNothing);
    expect(
      find.textContaining('No source-backed comparable was available'),
      findsOneWidget,
    );
    expect(find.textContaining('Market value'), findsNothing);
    expect(find.textContaining('Worth'), findsNothing);
    expect(find.textContaining('Appraised at'), findsNothing);
    expect(find.textContaining('Certified value'), findsNothing);
    expect(find.textContaining('Authentic value'), findsNothing);

    await tapVisible(tester, find.text('Accept suggestion').first);
    expect(find.text('Accepted for review'), findsOneWidget);
    expect(find.text('AI-suggested'), findsWidgets);

    await tapVisible(tester, find.text('Reject').first);
    expect(find.text('Rejected for this draft'), findsOneWidget);
    expect(find.text('Accepted for review'), findsNothing);
    expect(find.text('AI-suggested'), findsWidgets);

    final jobs = await tester.runAsync(
      () => fixture.repository.researchJobsForArtwork('research-draft'),
    );
    expect(jobs, isNotNull);
    expect(jobs!, hasLength(1));
    expect(
      jobs.single.sourceHits.map((hit) => hit.sourceName),
      contains('The Met Collection'),
    );
  });

  testWidgets('online research displays no reliable comparable guardrail', (
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
          id: 'no-comparable-draft',
          title: 'Bronze Garden Sculpture',
          state: ArtworkRecordState.needsReview,
        ),
      );
      await fixture.repository.upsertResearchJob(
        _researchJob(
          artworkId: 'no-comparable-draft',
          sourceHits: const [],
          candidateAttributions: const [],
          comparableValueSignals: const [
            ComparableValueSignal(
              id: 'no-comparable-signal',
              researchJobId: 'research-no-comparable-draft',
              kind: ComparableValueKind.noReliableComparable,
              label: 'No reliable comparable found',
              sourceName: 'Professional-source search',
              caveat:
                  'No source-backed comparable was available for this draft.',
            ),
          ],
        ),
      );
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkDraft('no-comparable-draft'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('No source-backed match yet'), findsOneWidget);
    await tester.ensureVisible(find.text('Comparable source signals'));
    await tester.pump();

    expect(find.text('Comparable source signals'), findsOneWidget);
    expect(
      find.text(
        'No comparable sale or public estimate was available from verified sources.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('source-backed comparable signal'),
      findsNothing,
    );
    expect(find.text('No reliable comparable found'), findsOneWidget);
    expect(find.text('Source: Professional-source search'), findsOneWidget);
    expect(
      find.text('No source-backed comparable was available for this draft.'),
      findsOneWidget,
    );
    expect(find.textContaining('Market value'), findsNothing);
    expect(find.textContaining('Worth'), findsNothing);
    expect(find.textContaining('Appraised at'), findsNothing);
    expect(find.textContaining('Certified value'), findsNothing);
    expect(find.textContaining('Authentic value'), findsNothing);
  });

  testWidgets('online research hides comparable estimates without source hits', (
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
          id: 'unverified-comparable-draft',
          title: 'Interior Study',
          state: ArtworkRecordState.needsReview,
        ),
      );
      await fixture.repository.upsertResearchJob(
        _researchJob(
          artworkId: 'unverified-comparable-draft',
          sourceHits: const [],
          candidateAttributions: const [],
          comparableValueSignals: const [
            ComparableValueSignal(
              id: 'unverified-value-signal',
              researchJobId: 'research-unverified-comparable-draft',
              sourceHitId: 'missing-source',
              kind: ComparableValueKind.publicEstimate,
              label: 'Market value',
              sourceName: 'Unverified public estimate',
              sourceUrl: 'https://estimate.example/value',
              amountLow: '2200',
              amountHigh: '2800',
              currency: 'USD',
              caveat: 'Comparable data may not apply to this artwork.',
            ),
          ],
        ),
      );
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkDraft('unverified-comparable-draft'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('No source-backed match yet'), findsOneWidget);
    await tester.ensureVisible(find.text('Comparable source signals'));
    await tester.pump();

    expect(
      find.text(
        '1 comparable signal was hidden because linked sources are missing or could not be verified.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('source-backed comparable signal'),
      findsNothing,
    );
    expect(find.text('No reliable comparable found'), findsOneWidget);
    expect(find.textContaining('Market value'), findsNothing);
    expect(find.textContaining('https://estimate.example'), findsNothing);
    expect(find.textContaining('Comparable amount'), findsNothing);
    expect(
      find.text(
        'Comparable signal hidden because its source could not be verified.',
      ),
      findsOneWidget,
    );

    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkDraft('unverified-comparable-draft'),
      dependencies: fixture.dependencies,
      ensureVisibleFinder: find.text(
        '1 comparable signal was hidden because linked sources are missing or could not be verified.',
      ),
      fileName: 'issue-128-draft-review-comparable-hidden.png',
    );
  });

  testWidgets('online research displays allowed auction comparable amount', (
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
          id: 'auction-comparable-draft',
          title: 'Interior Study',
          state: ArtworkRecordState.needsReview,
        ),
      );
      await fixture.repository.upsertResearchJob(
        _researchJob(
          artworkId: 'auction-comparable-draft',
          sourceHits: const [
            ResearchSourceHit(
              id: 'auction-source',
              researchJobId: 'research-auction-comparable-draft',
              sourceName: 'Example Auction Results',
              sourceType: ResearchSourceType.auctionHouse,
              confidence: ResearchConfidence.possible,
              sourceUrl: 'https://auction.example/lot/123',
              title: 'Interior Study',
              artist: 'Example Auction Artist',
            ),
          ],
          candidateAttributions: const [],
          comparableValueSignals: [
            ComparableValueSignal(
              id: 'auction-value-signal',
              researchJobId: 'research-auction-comparable-draft',
              sourceHitId: 'auction-source',
              kind: ComparableValueKind.comparableSaleSignal,
              label: 'Market value',
              sourceName: 'Untrusted persisted source name',
              sourceUrl: 'https://auction.example/lot/123',
              amountLow: '2200',
              amountHigh: '2800',
              currency: 'USD',
              signalDate: DateTime.utc(2025, 5, 1),
              caveat:
                  'Comparable data may not apply to this artwork; confirm with an expert.',
            ),
          ],
        ),
      );
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkDraft('auction-comparable-draft'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    await tester.ensureVisible(find.text('Comparable source signals'));
    await tester.pump();

    expect(find.text('Comparable sale signal'), findsOneWidget);
    expect(find.textContaining('Market value'), findsNothing);
    expect(find.text('Source: Example Auction Results'), findsOneWidget);
    expect(
      find.text('Citation: https://auction.example/lot/123'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Comparable amount: USD 2,200-2,800'),
      findsOneWidget,
    );
    expect(find.textContaining('Signal date: 2025-05-01'), findsOneWidget);
  });

  testWidgets('online research suppresses unsafe comparable display data', (
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
          id: 'unsafe-comparable-draft',
          title: 'Interior Study',
          state: ArtworkRecordState.needsReview,
        ),
      );
      await fixture.repository.upsertResearchJob(
        _researchJob(
          artworkId: 'unsafe-comparable-draft',
          sourceHits: const [
            ResearchSourceHit(
              id: 'unsafe-source',
              researchJobId: 'research-unsafe-comparable-draft',
              sourceName: 'Example Auction Results',
              sourceType: ResearchSourceType.auctionHouse,
              confidence: ResearchConfidence.possible,
              sourceUrl: 'https://auction.example/lot/123',
              title: 'Interior Study',
              artist: 'Example Auction Artist',
            ),
          ],
          candidateAttributions: const [],
          comparableValueSignals: const [
            ComparableValueSignal(
              id: 'unsafe-value-signal',
              researchJobId: 'research-unsafe-comparable-draft',
              sourceHitId: 'unsafe-source',
              kind: ComparableValueKind.publicEstimate,
              label: 'Market value',
              sourceName: 'Unsafe persisted source',
              sourceUrl: 'https://evil.example/lot/123',
              amountLow: '2200',
              amountHigh: '2800',
              currency: 'USD',
              caveat: 'Market value from unsafe persisted text.',
            ),
          ],
        ),
      );
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkDraft('unsafe-comparable-draft'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    await tester.ensureVisible(find.text('Comparable source signals'));
    await tester.pump();

    expect(find.text('No reliable comparable found'), findsOneWidget);
    expect(find.textContaining('Market value'), findsNothing);
    expect(find.textContaining('https://evil.example'), findsNothing);
    expect(find.textContaining('Comparable amount'), findsNothing);
    expect(
      find.text(
        'Comparable signal hidden because its source could not be verified.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('settings shell routes render the settings tab', (
    WidgetTester tester,
  ) async {
    for (final route in [AppRoutes.collectionSettings, AppRoutes.settings]) {
      await tester.pumpWidget(ArchivaleApp(initialRoute: route));
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

Future<void> enterVisibleText(
  WidgetTester tester,
  Finder finder,
  String text,
) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.enterText(finder, text);
  await tester.pump();
}

Future<void> selectDropdownItem(
  WidgetTester tester,
  Finder finder,
  String value,
) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  final dropdown = tester.widget<DropdownButtonFormField<String>>(finder);
  dropdown.onChanged!(value);
  await pumpLiveData(tester);
}

Future<void> waitForFinder(
  WidgetTester tester,
  Finder finder, {
  int attempts = 20,
}) async {
  for (var attempt = 0; attempt < attempts; attempt += 1) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }

  final visibleTexts = find
      .byType(Text)
      .evaluate()
      .map((element) => element.widget)
      .whereType<Text>()
      .map((text) => text.data)
      .whereType<String>()
      .toList();
  fail('Finder not found. Visible text: ${visibleTexts.join(' | ')}');
}

Future<void> pressAsyncButton(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.runAsync(() async {
    final dynamic button = tester.widget(finder);
    (button.onPressed as VoidCallback?)!.call();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await pumpLiveData(tester);
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

Future<void> loadScreenshotFont() async {
  const materialIconPath =
      '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
  final materialIconFile = File(materialIconPath);
  if (materialIconFile.existsSync()) {
    final iconBytes = await materialIconFile.readAsBytes();
    final iconLoader = FontLoader('MaterialIcons')
      ..addFont(Future<ByteData>.value(ByteData.sublistView(iconBytes)));
    await iconLoader.load();
  }

  const fontPaths = [
    '/System/Library/Fonts/SFNS.ttf',
    '/Library/Fonts/Arial.ttf',
  ];

  for (final path in fontPaths) {
    final file = File(path);
    if (!file.existsSync()) {
      continue;
    }

    final bytes = await file.readAsBytes();
    final loader = FontLoader('Roboto')
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
    return;
  }
}

Future<void> _configureMobileViewport(WidgetTester tester) async {
  tester.view.physicalSize = const Size(393, 852);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> captureVisualEvidence(
  WidgetTester tester, {
  required String routeName,
  required ThemeMode themeMode,
  required String fileName,
}) async {
  await _configureMobileViewport(tester);

  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: ArchivaleApp(initialRoute: routeName, themeMode: themeMode),
    ),
  );
  await pumpReady(tester);

  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync<Uint8List>(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData!.buffer.asUint8List();
  });

  final outputDirectory = Directory(
    p.join('.dart_tool', 'issue102_visual_evidence'),
  );
  outputDirectory.createSync(recursive: true);
  final screenshotFile = File(p.join(outputDirectory.path, fileName));
  screenshotFile.writeAsBytesSync(bytes!);

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

Future<void> captureArtifactForApp(
  WidgetTester tester, {
  required String routeName,
  required String fileName,
  ThemeMode themeMode = ThemeMode.system,
  AppDependencies? dependencies,
  Finder? ensureVisibleFinder,
}) async {
  await _configureMobileViewport(tester);

  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: ArchivaleApp(
        initialRoute: routeName,
        dependencies: dependencies,
        themeMode: themeMode,
      ),
    ),
  );
  await pumpLiveData(tester);
  if (ensureVisibleFinder != null) {
    await tester.ensureVisible(ensureVisibleFinder);
    await tester.pump();
  }
  await captureBoundaryToArtifacts(tester, boundaryKey, fileName);
}

Future<void> captureImportActionVisualEvidence(
  WidgetTester tester, {
  required AppDependencies dependencies,
  required String actionLabel,
  required Finder settledState,
  required String fileName,
}) async {
  await _configureMobileViewport(tester);

  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: ArchivaleApp(
        initialRoute: AppRoutes.import,
        dependencies: dependencies,
      ),
    ),
  );
  await pumpLiveData(tester);
  await tapVisible(tester, find.text(actionLabel));
  await waitForFinder(tester, settledState);
  await captureBoundaryToArtifacts(tester, boundaryKey, fileName);
}

Future<void> captureSupportingPhotoActionVisualEvidence(
  WidgetTester tester, {
  required AppDependencies dependencies,
  required Finder settledState,
  required String fileName,
}) async {
  await _configureMobileViewport(tester);

  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: ArchivaleApp(
        initialRoute: AppRoutes.artworkSupportingPhotoImport('document-visual'),
        dependencies: dependencies,
      ),
    ),
  );
  await pumpLiveData(tester);
  await pressAsyncButton(
    tester,
    find.widgetWithText(FilledButton, 'Choose supporting photo'),
  );
  await waitForFinder(tester, settledState);
  await captureBoundaryToArtifacts(tester, boundaryKey, fileName);
}

Future<void> capturePlaceholderSaveVisualEvidence(
  WidgetTester tester, {
  required AppDependencies dependencies,
  required String fileName,
}) async {
  await _configureMobileViewport(tester);

  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: ArchivaleApp(
        initialRoute: AppRoutes.artworkEdit('placeholder-draft'),
        dependencies: dependencies,
      ),
    ),
  );
  await pumpLiveData(tester);
  await tapVisible(tester, find.text('Save user-confirmed fields'));
  await pumpLiveData(tester);
  await tester.runAsync(
    () async => Future<void>.delayed(const Duration(milliseconds: 500)),
  );
  await tester.pump();
  await waitForFinder(tester, find.text('Draft review'), attempts: 60);
  await tester.ensureVisible(find.text('Untitled artwork'));
  await tester.pump();

  await captureBoundaryToArtifacts(tester, boundaryKey, fileName);
}

Future<void> captureCsvImportPreviewVisualEvidence(
  WidgetTester tester, {
  required AppDependencies dependencies,
  required String csvPath,
  required String fileName,
}) async {
  await _configureMobileViewport(tester);

  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: ArchivaleApp(
        initialRoute: AppRoutes.collectionImportCsv,
        dependencies: dependencies,
      ),
    ),
  );
  await pumpLiveData(tester);
  await enterVisibleText(
    tester,
    find.byKey(const ValueKey('csv-test-harness-path-field')),
    csvPath,
  );
  await pressAsyncButton(
    tester,
    find.widgetWithText(OutlinedButton, 'Load test harness path'),
  );
  await waitForFinder(
    tester,
    find.byKey(const ValueKey('csv-mapping-Work Name')),
  );
  await selectDropdownItem(
    tester,
    find.byKey(const ValueKey('csv-mapping-Work Name')),
    'field:title',
  );
  await pumpLiveData(tester);
  await tester.ensureVisible(find.text('Cancel without writing'));
  await tester.pump();

  await captureBoundaryToArtifacts(tester, boundaryKey, fileName);
}

Future<void> captureCsvImportSuccessVisualEvidence(
  WidgetTester tester, {
  required AppDependencies dependencies,
  required String fileName,
}) async {
  await _configureMobileViewport(tester);

  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: ArchivaleApp(
        initialRoute: AppRoutes.collectionImportCsv,
        dependencies: dependencies,
      ),
    ),
  );
  await pumpLiveData(tester);
  await pressAsyncButton(
    tester,
    find.widgetWithText(FilledButton, 'Choose CSV file'),
  );
  await waitForFinder(
    tester,
    find.byKey(const ValueKey('csv-mapping-Work Name')),
  );
  await selectDropdownItem(
    tester,
    find.byKey(const ValueKey('csv-mapping-Work Name')),
    'field:title',
  );
  await pumpLiveData(tester);
  await tapVisible(tester, find.text('Import as new'));
  await pressAsyncButton(
    tester,
    find.widgetWithText(FilledButton, 'Confirm local import'),
  );
  await waitForFinder(tester, find.text('Open first imported record'));
  await tester.ensureVisible(find.text('Open first imported record'));
  await tester.pump();

  await captureBoundaryToArtifacts(tester, boundaryKey, fileName);
}

Future<void> captureBoundaryToArtifacts(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String fileName,
) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync<Uint8List>(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData!.buffer.asUint8List();
  });

  final outputDirectory = Directory(p.join('artifacts', 'visual'));
  outputDirectory.createSync(recursive: true);
  final screenshotFile = File(p.join(outputDirectory.path, fileName));
  screenshotFile.writeAsBytesSync(bytes!);

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
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
    required this.onDeviceAiDraftProvider,
  });

  final Directory tempDir;
  LocalArtworkRepository repository;
  final LocalAttachmentStore attachmentStore;
  final OnDeviceAiDraftProvider onDeviceAiDraftProvider;

  AppDependencies get dependencies {
    return dependenciesWithPicker(_NoLostImagePicker());
  }

  AppDependencies dependenciesWithPicker(ArtworkImagePicker imagePicker) {
    return dependenciesWithFlags(imagePicker: imagePicker);
  }

  AppDependencies dependenciesWithFlags({
    ArtworkImagePicker? imagePicker,
    CsvImportFilePicker csvImportFilePicker = const _NoCsvPicker(),
    AppFeatureFlags featureFlags = const AppFeatureFlags(),
  }) {
    return AppDependencies(
      artworkRepository: repository,
      attachmentStore: attachmentStore,
      imagePicker: imagePicker ?? _NoLostImagePicker(),
      csvImportFilePicker: csvImportFilePicker,
      featureFlags: featureFlags,
      onDeviceAiDraftProvider: onDeviceAiDraftProvider,
    );
  }

  static Future<_LiveDependencyFixture> create({
    OnDeviceAiDraftProvider onDeviceAiDraftProvider =
        const DisabledOnDeviceAiDraftProvider(),
  }) async {
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
      onDeviceAiDraftProvider: onDeviceAiDraftProvider,
    );
  }

  Future<void> reopenRepository() async {
    await repository.close();
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(p.join(tempDir.path, 'records.db')),
    );
  }

  Future<File> writePngSource(String fileName) async {
    final file = File(p.join(tempDir.path, fileName));
    await file.writeAsBytes(_tinyPngBytes);
    return file;
  }

  Future<File> writeTextSource(String fileName, String contents) async {
    final file = File(p.join(tempDir.path, fileName));
    await file.writeAsString(contents);
    return file;
  }

  Future<AttachmentRecord> addPrimaryImage({
    required String artworkId,
    String? attachmentId,
  }) async {
    final id = attachmentId ?? 'primary-$artworkId';
    final source = await writePngSource('$id.png');
    final attachment = await attachmentStore.saveImportedAttachment(
      artworkId: artworkId,
      attachmentId: id,
      sourceFile: source,
      originalFileName: source.path,
      mimeType: 'image/png',
      type: AttachmentType.photo,
      source: ArtworkFieldSource.userConfirmed,
      importedAt: DateTime.utc(2026, 7, 4, 12),
      notes: 'Primary image fixture.',
    );
    await repository.addAttachment(attachment);
    return attachment;
  }

  Future<AttachmentRecord> addSupportingPhoto({
    required String artworkId,
    String? attachmentId,
    String fileName = 'supporting-photo.png',
  }) async {
    final id = attachmentId ?? 'supporting-$artworkId';
    final source = await writePngSource(fileName);
    final attachment = await attachmentStore.saveImportedAttachment(
      artworkId: artworkId,
      attachmentId: id,
      sourceFile: source,
      originalFileName: fileName,
      mimeType: 'image/png',
      type: AttachmentType.photo,
      role: AttachmentRole.supportingPhoto,
      source: ArtworkFieldSource.userConfirmed,
      importedAt: DateTime.utc(2026, 7, 5, 12),
      notes: 'Supporting photo fixture.',
    );
    await repository.addAttachment(attachment);
    return attachment;
  }

  Future<void> dispose() async {
    await repository.close();
    await tempDir.delete(recursive: true);
  }
}

class _SingleImagePicker implements ArtworkImagePicker {
  const _SingleImagePicker(this.file);

  final File file;

  @override
  Future<XFile?> pick(ArtworkImagePickMode mode) async {
    return XFile(file.path, name: p.basename(file.path), mimeType: 'image/png');
  }

  @override
  Future<XFile?> retrieveLostImage() async => null;
}

class _NoCsvPicker implements CsvImportFilePicker {
  const _NoCsvPicker();

  @override
  Future<CsvImportFileSelection?> pickCsvFile() async => null;
}

class _SingleCsvPicker implements CsvImportFilePicker {
  const _SingleCsvPicker(this.file);

  final File file;

  @override
  Future<CsvImportFileSelection?> pickCsvFile() async {
    return CsvImportFileSelection(
      displayName: p.basename(file.path),
      path: file.path,
      bytes: await file.readAsBytes(),
    );
  }
}

class _CompletedAiDraftProvider implements OnDeviceAiDraftProvider {
  const _CompletedAiDraftProvider();

  @override
  Future<OnDeviceAiCapability> checkAvailability() async {
    return const OnDeviceAiCapability(
      availability: OnDeviceAiAvailability.available,
      deviceModel: 'Pixel test device',
    );
  }

  @override
  Future<OnDeviceAiDraftResult> createDraft(
    OnDeviceAiDraftRequest request,
  ) async {
    return const OnDeviceAiDraftResult(
      visualSummary: 'Visible lower-right signature on a framed artwork.',
      signatureNotes: 'May read E. Test.',
      mediumHint: 'Print or lithograph on paper',
      searchTerms: ['E. Test framed artwork'],
    );
  }
}

ArtworkRecord _artworkRecord({
  required String id,
  required String title,
  required ArtworkRecordState state,
  ArtworkLifecycleStatus lifecycleStatus = ArtworkLifecycleStatus.active,
  ArtworkFieldSource source = ArtworkFieldSource.unknown,
  Set<String> missingFieldKeys = const {},
  Map<String, ArtworkFieldValue> overrides = const {},
}) {
  final now = DateTime.utc(2026, 7, 4, 12);
  return ArtworkRecord(
    id: id,
    recordState: state,
    lifecycleStatus: lifecycleStatus,
    primaryImageAttachmentId: 'primary-$id',
    createdAt: now,
    updatedAt: now,
    fields: {
      for (final entry in _testFieldValues.entries)
        if (!missingFieldKeys.contains(entry.key))
          entry.key:
              overrides[entry.key] ??
              ArtworkFieldValue(
                value: entry.key == ArtworkFieldKeys.title
                    ? title
                    : entry.value,
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

ArtworkRecord _placeholderDraftRecord({String id = 'placeholder-draft'}) {
  final now = DateTime.utc(2026, 7, 4, 12);
  const placeholders = {
    ArtworkFieldKeys.title: 'Untitled artwork',
    ArtworkFieldKeys.artist: 'Unknown',
    ArtworkFieldKeys.year: 'Could not determine',
    ArtworkFieldKeys.medium: 'Needs review',
    ArtworkFieldKeys.dimensions: 'Needs review',
    ArtworkFieldKeys.currentLocation: 'Needs review',
    ArtworkFieldKeys.insuranceValue: 'Not set',
    ArtworkFieldKeys.conditionNotes: 'Needs review',
  };
  return ArtworkRecord(
    id: id,
    recordState: ArtworkRecordState.needsReview,
    primaryImageAttachmentId: 'primary-$id',
    createdAt: now,
    updatedAt: now,
    fields: {
      for (final entry in placeholders.entries)
        entry.key: ArtworkFieldValue(
          value: entry.value,
          source: ArtworkFieldSource.unknown,
          note: 'Placeholder fixture.',
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

AttachmentRecord _primaryImageAttachmentRecord({
  required String id,
  required String artworkId,
  required String relativePath,
}) {
  return AttachmentRecord(
    id: id,
    artworkId: artworkId,
    type: AttachmentType.photo,
    fileName: 'primary.png',
    mimeType: 'image/png',
    fileSizeBytes: 12,
    importedAt: DateTime.utc(2026, 7, 4, 12),
    source: ArtworkFieldSource.userConfirmed,
    relativePath: relativePath,
    checksum: 'missing-checksum',
    notes: 'Missing primary image fixture.',
  );
}

ResearchJob _researchJob({
  required String artworkId,
  List<ResearchSourceHit>? sourceHits,
  List<CandidateAttribution>? candidateAttributions,
  List<ComparableValueSignal>? comparableValueSignals,
}) {
  final now = DateTime.utc(2026, 7, 4, 12);
  final jobId = 'research-$artworkId';
  return ResearchJob(
    id: jobId,
    artworkId: artworkId,
    status: ResearchJobStatus.completed,
    createdAt: now,
    updatedAt: now,
    completedAt: now,
    consentSummary: 'Fixture consent.',
    querySummary: 'Fixture query.',
    provider: 'fixture',
    sourceHits:
        sourceHits ??
        [
          ResearchSourceHit(
            id: 'source-$artworkId',
            researchJobId: jobId,
            sourceName: 'The Met Collection',
            sourceType: ResearchSourceType.museumCollection,
            confidence: ResearchConfidence.possible,
            sourceUrl: 'https://www.metmuseum.org/',
            title: 'AI Draft Title',
            artist: 'Candidate Artist',
          ),
        ],
    candidateAttributions:
        candidateAttributions ??
        [
          CandidateAttribution(
            id: 'candidate-$artworkId',
            researchJobId: jobId,
            sourceHitId: 'source-$artworkId',
            title: 'AI Draft Title',
            artist: 'Candidate Artist',
            confidence: ResearchConfidence.possible,
            matchReason: 'Fixture candidate.',
          ),
        ],
    comparableValueSignals:
        comparableValueSignals ??
        [
          ComparableValueSignal(
            id: 'value-$artworkId',
            researchJobId: jobId,
            kind: ComparableValueKind.noReliableComparable,
            label: 'No reliable comparable found',
            sourceName: 'Professional-source search',
            caveat: 'No source-backed comparable was available for this draft.',
          ),
        ],
  );
}

ArtworkRecord _existingCsvDuplicateRecord() {
  return _artworkRecord(
    id: 'existing-001',
    title: 'Blue Interior',
    state: ArtworkRecordState.verifiedByYou,
    source: ArtworkFieldSource.userConfirmed,
    overrides: {
      ArtworkFieldKeys.artist: ArtworkFieldValue(
        value: 'A. Maker',
        source: ArtworkFieldSource.userConfirmed,
        note: 'Confirmed in test fixture.',
        lastConfirmedAt: DateTime.utc(2026, 7, 4, 12),
      ),
      ArtworkFieldKeys.year: ArtworkFieldValue(
        value: '2020',
        source: ArtworkFieldSource.userConfirmed,
        note: 'Confirmed in test fixture.',
        lastConfirmedAt: DateTime.utc(2026, 7, 4, 12),
      ),
      ArtworkFieldKeys.dimensions: ArtworkFieldValue(
        value: '40 x 50 cm',
        source: ArtworkFieldSource.userConfirmed,
        note: 'Confirmed in test fixture.',
        lastConfirmedAt: DateTime.utc(2026, 7, 4, 12),
      ),
    },
  );
}

const _csvImportCsv =
    'Work Name,Creator,Year,Dimensions,Notes\n'
    'Fresh Harbor,A. Maker,2020,40 x 50 cm,\n'
    'Question Mark,,c. 1900,about 40 x 50,Owner note\n'
    'Blue Interior,A. Maker,2020,40 x 50 cm,\n'
    ',,1998,40 x 50 cm,\n';

const _testFieldValues = {
  ArtworkFieldKeys.title: 'Fixture title',
  ArtworkFieldKeys.artist: 'Fixture artist',
  ArtworkFieldKeys.year: '2026',
  ArtworkFieldKeys.medium: 'Oil on canvas',
  ArtworkFieldKeys.dimensions: '40 x 50 cm',
  ArtworkFieldKeys.purchasePrice: 'USD 80',
  ArtworkFieldKeys.currentLocation: 'Studio wall',
  ArtworkFieldKeys.insuranceValue: 'USD 100',
  ArtworkFieldKeys.conditionNotes: 'Good condition',
};

final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
);
