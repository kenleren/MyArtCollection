import 'dart:async';
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
import 'package:my_art_collection/app/billing/entitlement_plan.dart';
import 'package:my_art_collection/app/billing/play_billing_adapter.dart';
import 'package:my_art_collection/app/config/app_feature_flags.dart';
import 'package:my_art_collection/app/research/online_research_service.dart';
import 'package:my_art_collection/app/research/broker_online_research_client.dart';
import 'package:my_art_collection/app/research/broker_http_client.dart';
import 'package:my_art_collection/app/import/csv_import_file_picker.dart';
import 'package:my_art_collection/app/intake/artwork_image_picker.dart';
import 'package:my_art_collection/app/intake/attachment_viewer_gateway.dart';
import 'package:my_art_collection/app/intake/supporting_document_picker.dart';
import 'package:my_art_collection/app/prototype/prototype_artwork.dart';
import 'package:my_art_collection/app/screens/prototype_flow.dart';
import 'package:my_art_collection/app/startup_route.dart';
import 'package:my_art_collection/app/storage/ai_research_record.dart';
import 'package:my_art_collection/app/storage/artwork_collection_query.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/attachment_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:my_art_collection/app/storage/local_attachment_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

enum _Issue211CollectionVisualState {
  populated,
  composed,
  noResults,
  trueEmpty,
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await loadScreenshotFont();
  });

  testWidgets('intro screen shows first-run stewardship copy', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ArchivaleApp(initialRoute: AppRoutes.splash));
    await pumpLiveData(tester);

    expect(find.text('Archivale'), findsOneWidget);
    expect(find.text('Private collection records'), findsOneWidget);
    expect(find.text('Photograph, draft, confirm, preserve.'), findsOneWidget);
    expect(
      find.text(
        'Photograph an artwork. Archivale drafts the record. You confirm the facts.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'Keep your collection on this device, with backup in your Google account when you choose it.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('app provides system-aware light and dark Material themes', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ArchivaleApp(initialRoute: AppRoutes.splash));
    await pumpLiveData(tester);

    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.themeMode, ThemeMode.system);
    expect(materialApp.darkTheme, isNotNull);

    await tester.pumpWidget(
      const ArchivaleApp(
        initialRoute: AppRoutes.splash,
        themeMode: ThemeMode.dark,
      ),
    );
    await pumpLiveData(tester);

    final headingContext = tester.element(
      find.text('Private collection records'),
    );
    final theme = Theme.of(headingContext);
    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.primary, const Color(0xFFD9BE78));
    expect(theme.scaffoldBackgroundColor, const Color(0xFF090B0B));
  });

  testWidgets('onboarding first-run routes keep collector-facing trust copy', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const ArchivaleApp(initialRoute: AppRoutes.onboarding),
    );
    await pumpLiveData(tester);

    expect(find.text('Start your first artwork record'), findsOneWidget);
    expect(find.text('Photograph, draft, confirm, preserve.'), findsOneWidget);
    expect(
      find.text(
        'Archivale helps you draft the record, but it does not determine authenticity or appraise value.',
      ),
      findsOneWidget,
    );
    expect(find.text('Photograph artwork'), findsOneWidget);
    expect(find.text('Privacy and storage'), findsOneWidget);
    expect(find.text('Photograph'), findsOneWidget);
    expect(find.text('Attach records'), findsOneWidget);
    expect(find.text('Preserve'), findsOneWidget);
    final firstRunAction = tester.widget<PrimaryActionButton>(
      find.byType(PrimaryActionButton).first,
    );
    expect(firstRunAction.routeName, AppRoutes.onboardingFirstAdd);

    await tester.pumpWidget(
      const ArchivaleApp(initialRoute: AppRoutes.onboardingPrivacy),
    );
    await pumpLiveData(tester);

    expect(find.text('Privacy and storage'), findsOneWidget);
  });

  testWidgets('onboarding first-add route shows collector-facing copy', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const ArchivaleApp(initialRoute: AppRoutes.onboardingFirstAdd),
    );
    await pumpLiveData(tester);

    final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(materialApp.initialRoute, AppRoutes.onboardingFirstAdd);
    expect(find.text('Add supporting records next'), findsOneWidget);
    expect(
      find.text(
        'Create the artwork record first, then add supporting photos and records when they are ready.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'issue 214 captures gated local organization mobile and desktop',
    (WidgetTester tester) async {
      final fixture = (await tester.runAsync(_LiveDependencyFixture.create))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.dispose);
      });
      await tester.runAsync(() async {
        await fixture.repository.createGroup(
          id: 'group-studio',
          name: 'Studio',
        );
        await fixture.repository.createGroup(id: 'group-loan', name: 'Loan');
      });
      final dependencies = fixture.dependenciesWithFlags(
        featureFlags: const AppFeatureFlags(groupingsEnabled: true),
      );
      final boundaryKey = GlobalKey();
      await _configureMobileViewport(tester);
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: ArchivaleApp(
            initialRoute: AppRoutes.collectionGroups,
            dependencies: dependencies,
          ),
        ),
      );
      await pumpLiveData(tester);
      expect(find.text('Manage groups'), findsOneWidget);
      expect(find.text('Studio'), findsOneWidget);
      await captureBoundaryToArtifacts(
        tester,
        boundaryKey,
        'issue-214-groups-mobile.png',
        resetAfterCapture: false,
      );

      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      await tester.pump();
      await captureBoundaryToArtifacts(
        tester,
        boundaryKey,
        'issue-214-groups-desktop.png',
      );
    },
  );

  testWidgets('issue 214 exercises local organization workflows', (
    WidgetTester tester,
  ) async {
    final fixture = (await tester.runAsync(_LiveDependencyFixture.create))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.dispose);
    });
    await tester.runAsync(() async {
      await fixture.repository.createAll([
        _collectionQueryRecord(
          id: 'issue-214-home',
          title: 'Home Studio Work',
          artist: 'A. Collector',
          notes: 'Multi-group favorite.',
          location: 'Home',
          state: ArtworkRecordState.verifiedByYou,
        ),
        _collectionQueryRecord(
          id: 'issue-214-vault',
          title: 'Vault Loan Work',
          artist: 'B. Collector',
          notes: 'Loan record.',
          location: 'Vault',
          state: ArtworkRecordState.verifiedByYou,
        ),
        _collectionQueryRecord(
          id: 'issue-214-gallery',
          title: 'Gallery Studio Work',
          artist: 'C. Collector',
          notes: 'Studio record.',
          location: 'Gallery',
          state: ArtworkRecordState.verifiedByYou,
        ),
      ]);
      await fixture.repository.createGroup(id: 'studio', name: 'Studio');
      await fixture.repository.createGroup(id: 'loan', name: 'Loan');
      await fixture.repository.replaceArtworkGroupMemberships(
        artworkId: 'issue-214-home',
        groupIds: {'studio', 'loan'},
      );
      await fixture.repository.setFavorite(
        artworkId: 'issue-214-home',
        isFavorite: true,
      );
      await fixture.repository.replaceArtworkGroupMemberships(
        artworkId: 'issue-214-vault',
        groupIds: {'loan'},
      );
      await fixture.repository.replaceArtworkGroupMemberships(
        artworkId: 'issue-214-gallery',
        groupIds: {'studio'},
      );
    });
    final dependencies = fixture.dependenciesWithFlags(
      featureFlags: const AppFeatureFlags(groupingsEnabled: true),
    );
    final boundaryKey = GlobalKey();
    await _configureMobileViewport(tester);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: ArchivaleApp(
          key: const ValueKey('issue-214-no-results-route'),
          initialRoute: AppRoutes.collection,
          dependencies: dependencies,
        ),
      ),
    );
    await pumpLiveData(tester);
    await tester.tap(find.byKey(const ValueKey('collection-filter-toggle')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('group-filter-studio')));
    await pumpLiveData(tester);
    await tester.tap(find.byKey(const ValueKey('group-filter-loan')));
    await pumpLiveData(tester);
    await pumpLiveData(tester);
    expect(
      await tester
          .runAsync(
            () => fixture.repository.queryCollection(
              query: const ArtworkCollectionQuery(
                selectedGroupIds: {'studio', 'loan'},
              ),
            ),
          )
          .then(
            (snapshot) => snapshot!.entries.map((entry) => entry.record.id),
          ),
      containsAll(['issue-214-home', 'issue-214-vault', 'issue-214-gallery']),
    );
    await tester.tap(find.byKey(const ValueKey('favorites-filter')));
    await pumpLiveData(tester);
    expect(
      await tester
          .runAsync(
            () => fixture.repository.queryCollection(
              query: const ArtworkCollectionQuery(
                selectedGroupIds: {'studio', 'loan'},
                favoritesOnly: true,
              ),
            ),
          )
          .then(
            (snapshot) => snapshot!.entries.map((entry) => entry.record.id),
          ),
      ['issue-214-home'],
    );
    await captureBoundaryToArtifacts(
      tester,
      boundaryKey,
      'issue-214/workflow-mobile-favorite-or.png',
      resetAfterCapture: false,
    );
    await tester.scrollUntilVisible(
      find.text('Home Studio Work'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Home Studio Work'), findsOneWidget);
    expect(find.text('Vault Loan Work'), findsNothing);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: ArchivaleApp(
          key: const ValueKey('issue-214-location-composition-route'),
          initialRoute: AppRoutes.collection,
          dependencies: dependencies,
        ),
      ),
    );
    await pumpLiveData(tester);
    await tester.tap(find.byKey(const ValueKey('collection-filter-toggle')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('group-filter-studio')));
    await pumpLiveData(tester);
    await tester.tap(find.text('Vault'));
    await pumpLiveData(tester);
    expect(
      await tester
          .runAsync(
            () => fixture.repository.queryCollection(
              query: const ArtworkCollectionQuery(
                locations: {'Vault'},
                selectedGroupIds: {'studio'},
              ),
            ),
          )
          .then((snapshot) => snapshot!.entries),
      isEmpty,
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
    await tester.pump();
    expect(find.text('No matching artworks'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('No matching artworks'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.byKey(const ValueKey('collection-no-results-clear')),
      findsOneWidget,
    );
    await captureBoundaryToArtifacts(
      tester,
      boundaryKey,
      'issue-214/workflow-mobile-location-no-results.png',
      resetAfterCapture: false,
    );
    await tester.tap(find.byKey(const ValueKey('collection-no-results-clear')));
    await pumpLiveData(tester);
    expect(
      await tester
          .runAsync(() => fixture.repository.queryCollection())
          .then((snapshot) => snapshot!.entries),
      hasLength(3),
    );

    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: ArchivaleApp(
          key: const ValueKey('issue-214-groups-route'),
          initialRoute: AppRoutes.collectionGroups,
          dependencies: dependencies,
        ),
      ),
    );
    await pumpLiveData(tester);
    await tester.tap(find.byKey(const ValueKey('create-group-action')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await pumpLiveData(tester);
    expect(find.text('A group name is required.'), findsOneWidget);
    await tester.tap(find.byTooltip('Rename group').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Studio Local');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await pumpLiveData(tester);
    expect(find.text('Studio Local'), findsOneWidget);
    await tester.tap(find.byTooltip('Move group earlier').last);
    await pumpLiveData(tester);
    expect(
      await tester.runAsync(
        () => fixture.repository.listGroups().then(
          (groups) => groups.map((group) => group.id).toList(),
        ),
      ),
      ['loan', 'studio'],
    );
    await tester.tap(find.byTooltip('Delete group').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await pumpLiveData(tester);
    expect(
      await tester.runAsync(
        () => fixture.repository.groupIdsForArtwork('issue-214-home'),
      ),
      {'loan'},
    );
    expect(
      await tester.runAsync(
        () => fixture.repository.isFavorite('issue-214-home'),
      ),
      isTrue,
    );
    await captureBoundaryToArtifacts(
      tester,
      boundaryKey,
      'issue-214/workflow-mobile-management.png',
      resetAfterCapture: false,
    );

    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pump();
    await captureBoundaryToArtifacts(
      tester,
      boundaryKey,
      'issue-214/workflow-desktop-management.png',
      resetAfterCapture: false,
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: ArchivaleApp(
          key: const ValueKey('issue-214-export-route'),
          initialRoute: AppRoutes.settingsExport,
          dependencies: dependencies,
        ),
      ),
    );
    await pumpLiveData(tester);
    expect(find.text('Collection archive ZIP'), findsOneWidget);
    await captureBoundaryToArtifacts(
      tester,
      boundaryKey,
      'issue-214/workflow-desktop-export-successor.png',
    );
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
      routeName: AppRoutes.collection,
      themeMode: ThemeMode.dark,
      fileName: 'dark_collection.png',
    );
    await captureVisualEvidence(
      tester,
      routeName: AppRoutes.artworkDraft('sample-001'),
      themeMode: ThemeMode.dark,
      fileName: 'dark_draft_review.png',
    );
    await captureVisualEvidence(
      tester,
      routeName: AppRoutes.artworkReportPreview('sample-001'),
      themeMode: ThemeMode.dark,
      fileName: 'dark_report_preview.png',
    );
    await captureVisualEvidence(
      tester,
      routeName: AppRoutes.settingsExport,
      themeMode: ThemeMode.dark,
      fileName: 'dark_export_preview.png',
    );
    await captureVisualEvidence(
      tester,
      routeName: AppRoutes.collectionSettings,
      themeMode: ThemeMode.dark,
      fileName: 'dark_settings.png',
    );
  });

  testWidgets('visual evidence covers issue 211 collection query states', (
    WidgetTester tester,
  ) async {
    for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
      final themeName = themeMode == ThemeMode.light ? 'light' : 'dark';
      for (final state in _Issue211CollectionVisualState.values) {
        final stateName = switch (state) {
          _Issue211CollectionVisualState.populated => 'populated',
          _Issue211CollectionVisualState.composed => 'composed',
          _Issue211CollectionVisualState.noResults => 'no-results',
          _Issue211CollectionVisualState.trueEmpty => 'true-empty',
        };
        await _captureIssue211CollectionVisualEvidence(
          tester,
          themeMode: themeMode,
          state: state,
          fileName: 'issue-211-$stateName-$themeName.png',
        );
      }
    }
  });

  testWidgets(
    'documents screen renders injected controls and unavailable recovery',
    (WidgetTester tester) async {
      final fixture = await tester.runAsync(_LiveDependencyFixture.create);
      final liveFixture = fixture!;
      addTearDown(() async => tester.runAsync(liveFixture.dispose));
      final source = (await tester.runAsync(
        () => liveFixture.writePdfSource('receipt.pdf'),
      ))!;
      final picker = _SingleDocumentPicker(source);
      final viewer = _RecordingAttachmentViewer();
      await tester.runAsync(() async {
        await liveFixture.repository.upsert(
          _placeholderDraftRecord(id: 'sample-001'),
        );
        final attachment = await liveFixture.attachmentStore
            .saveImportedAttachment(
              artworkId: 'sample-001',
              attachmentId: 'document-001',
              sourceFile: source,
              originalFileName: 'receipt.pdf',
              mimeType: 'application/pdf',
              type: AttachmentType.receipt,
              source: ArtworkFieldSource.userConfirmed,
              importedAt: DateTime.utc(2026, 7, 10, 16),
            );
        await liveFixture.repository.addAttachment(attachment);
        await liveFixture.repository.updateAttachmentLifecycle(
          attachmentId: attachment.id,
          lifecycleStatus: AttachmentLifecycleStatus.unavailable,
          updatedAt: DateTime.utc(2026, 7, 10, 16, 1),
        );
      });

      await tester.pumpWidget(
        AppDependencyScope(
          dependencies: liveFixture.dependenciesWithFlags(
            supportingDocumentPicker: picker,
            attachmentViewer: viewer,
          ),
          child: MaterialApp(home: DocumentsScreen(artwork: prototypeArtwork)),
        ),
      );
      await pumpLiveData(tester);

      final attachButton = find.text('Attach supporting document');
      final dependencies = AppDependencyScope.of(tester.element(attachButton));
      expect(identical(dependencies.supportingDocumentPicker, picker), isTrue);
      expect(identical(dependencies.attachmentViewer, viewer), isTrue);
      expect(find.text('receipt.pdf'), findsOneWidget);
      expect(
        find.text(
          'Saved document unavailable. Replace it to restore this record.',
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Replace document'), findsOneWidget);
      expect(find.byTooltip('Remove document'), findsOneWidget);
    },
  );

  testWidgets(
    'supporting document workflow attaches, opens, replaces, removes, and recovers',
    (WidgetTester tester) async {
      final fixture = await tester.runAsync(_LiveDependencyFixture.create);
      final liveFixture = fixture!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(liveFixture.dispose);
      });

      const artworkId = 'sample-001';
      final originalSource = await tester.runAsync(
        () => liveFixture.writePdfSource(
          '2026-07-10-long-supporting-receipt-for-the-archivale-collection.pdf',
        ),
      );
      final replacementSource = await tester.runAsync(
        () => liveFixture.writePdfSource('corrected-receipt.pdf'),
      );
      final picker = _QueuedDocumentPicker([
        originalSource!,
        replacementSource!,
        const SupportingDocumentPickerException(),
      ]);
      final viewer = _RecordingAttachmentViewer();
      await tester.runAsync(() async {
        await liveFixture.repository.upsert(
          _artworkRecord(
            id: artworkId,
            title: 'Issue 179 Document Fixture',
            state: ArtworkRecordState.verifiedByYou,
            source: ArtworkFieldSource.userConfirmed,
          ),
        );
      });

      await _configureMobileViewport(tester);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: ArchivaleApp(
            initialRoute: AppRoutes.artworkDocuments(artworkId),
            dependencies: liveFixture.dependenciesWithFlags(
              supportingDocumentPicker: picker,
              attachmentViewer: viewer,
            ),
          ),
        ),
      );
      await pumpLiveData(tester);

      await waitForFinder(tester, find.text('Attach supporting document'));
      await pressAsyncButton(
        tester,
        find.widgetWithText(FilledButton, 'Attach supporting document'),
      );
      await waitForFinder(
        tester,
        find.text(
          '2026-07-10-long-supporting-receipt-for-the-archivale-collection.pdf',
        ),
      );
      expect(find.byTooltip('Open document'), findsOneWidget);
      expect(find.byTooltip('Replace document'), findsOneWidget);
      expect(find.byTooltip('Remove document'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      await warmBoundaryRaster(tester, boundaryKey);
      await captureBoundaryToArtifacts(
        tester,
        boundaryKey,
        'issue-179-attached-pdf-mobile.png',
        resetAfterCapture: false,
      );

      await pressAsyncButton(
        tester,
        find.widgetWithIcon(IconButton, Icons.open_in_new),
      );
      expect(viewer.openedUris, hasLength(1));
      expect(viewer.openedUris.single.isScheme('file'), isTrue);

      await pressAsyncButton(
        tester,
        find.widgetWithIcon(IconButton, Icons.swap_horiz),
      );
      await waitForFinder(tester, find.text('corrected-receipt.pdf'));
      expect(
        find.text(
          '2026-07-10-long-supporting-receipt-for-the-archivale-collection.pdf',
        ),
        findsNothing,
      );

      final replacement = await tester.runAsync(
        () async =>
            (await liveFixture.repository.attachmentsForArtwork(
              artworkId,
            )).singleWhere(
              (attachment) =>
                  attachment.lifecycleStatus ==
                  AttachmentLifecycleStatus.active,
            ),
      );
      await tester.runAsync(
        () => liveFixture.attachmentStore.discardPayload(replacement!),
      );
      await pressAsyncButton(
        tester,
        find.widgetWithIcon(IconButton, Icons.open_in_new),
      );
      await waitForFinder(tester, find.text('Document needs attention'));
      expect(
        find.text('The saved document file is unavailable.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Saved document unavailable. Replace it to restore this record.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      await captureBoundaryToArtifacts(
        tester,
        boundaryKey,
        'issue-179-unavailable-recovery-mobile.png',
        resetAfterCapture: false,
      );

      await pressAsyncButton(
        tester,
        find.widgetWithIcon(IconButton, Icons.delete_outline),
      );
      await waitForFinder(tester, find.text('Remove supporting document?'));
      expect(
        find.text(
          'This removes it from the active record and future archives. The prototype retains its private bytes until a separate data-erasure feature is available.',
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      await captureBoundaryToArtifacts(
        tester,
        boundaryKey,
        'issue-179-remove-confirmation-mobile.png',
        resetAfterCapture: false,
      );
      await pressAsyncButton(
        tester,
        find.widgetWithText(FilledButton, 'Remove'),
      );
      await waitForFinder(tester, find.text('No supporting documents yet'));

      await pressAsyncButton(
        tester,
        find.widgetWithText(FilledButton, 'Attach supporting document'),
      );
      await waitForFinder(tester, find.text('Document needs attention'));
      expect(
        find.text(
          'Could not open the system document picker. Try again later.',
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      await captureBoundaryToArtifacts(
        tester,
        boundaryKey,
        'issue-179-picker-error-mobile.png',
      );
    },
  );

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
      fileName: 'issue-109-csv-entry-mobile.png',
      ensureVisibleFinder: find.text('Import CSV', skipOffstage: false),
    );
    await captureCsvImportMappingVisualEvidence(
      tester,
      dependencies: fixture.dependencies,
      csvPath: visualCsvFile.path,
      fileName: 'issue-109-csv-mapping-mobile.png',
    );
    await captureCsvImportPreviewVisualEvidence(
      tester,
      dependencies: fixture.dependencies,
      csvPath: visualCsvFile.path,
      fileName: 'issue-109-csv-preview-warning-duplicate-mobile.png',
      ensureVisibleFinder: find.text(
        'Possible duplicate: 1',
        skipOffstage: false,
      ),
    );
    await captureCsvImportCancelVisualEvidence(
      tester,
      dependencies: fixture.dependencies,
      csvPath: visualCsvFile.path,
      fileName: 'issue-109-csv-cancel-no-write-mobile.png',
    );
    await captureCsvImportSuccessVisualEvidence(
      tester,
      dependencies: fixture.dependenciesWithFlags(
        csvImportFilePicker: _SingleCsvPicker(visualCsvFile),
      ),
      successFileName: 'issue-109-csv-success-summary-mobile.png',
      importedDraftFileName: 'issue-109-imported-draft-mobile.png',
    );
  });

  testWidgets('visual evidence captures onboarding first-run surfaces', (
    WidgetTester tester,
  ) async {
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.splash,
      fileName: 'issue-164-splash-onboarding-copy.png',
      ensureVisibleFinder: find.text('Private collection records'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.onboarding,
      fileName: 'issue-164-onboarding-copy.png',
      ensureVisibleFinder: find.text('Photograph artwork'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.onboardingPrivacy,
      fileName: 'issue-164-onboarding-privacy-copy.png',
      ensureVisibleFinder: find.text('Privacy and storage'),
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
        'Attach supporting document',
        skipOffstage: false,
      ),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkSupportingPhotoImport('supporting-visual'),
      dependencies: fixture.dependencies,
      fileName: 'issue-113-supporting-intake-mobile.png',
      ensureVisibleFinder: find.text(
        'Choose a supporting photo',
        skipOffstage: false,
      ),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collection,
      dependencies: fixture.dependencies,
      fileName: 'issue-113-saved-list-mobile.png',
      ensureVisibleFinder: find.text(
        '1 supporting record added.',
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
        'Add supporting records next',
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
        'Attach supporting document',
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

  testWidgets('visual evidence covers issue 170 supporting records copy', (
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
          id: 'issue-170-supporting-record',
          title: 'Issue 170 Supporting Record',
          state: ArtworkRecordState.verifiedByYou,
          source: ArtworkFieldSource.userConfirmed,
        ),
      );
      await fixture.addPrimaryImage(artworkId: 'issue-170-supporting-record');
    });

    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkDocuments('issue-170-supporting-record'),
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-170-documents-light.png',
      ensureVisibleFinder: find.text('Attach supporting document'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkDocuments('issue-170-supporting-record'),
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.dark,
      fileName: 'issue-170-documents-dark.png',
      ensureVisibleFinder: find.text('Attach supporting document'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkSupportingPhotoImport(
        'issue-170-supporting-record',
      ),
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-170-supporting-photo-import-light.png',
      ensureVisibleFinder: find.text('Saved with this artwork'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkSupportingPhotoCapture(
        'issue-170-supporting-record',
      ),
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-170-supporting-photo-capture-light.png',
      ensureVisibleFinder: find.text('Saved with this artwork'),
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
      ensureVisibleFinder: find.text('Save confirmed details'),
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
      routeName: AppRoutes.collectionAdd,
      fileName: 'issue-166-00-add-artwork-entry.png',
      ensureVisibleFinder: find.widgetWithText(
        FilledButton,
        'Photograph artwork',
      ),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.capture,
      dependencies: fixture.dependencies,
      fileName: 'issue-166-00a-capture-entry.png',
      ensureVisibleFinder: find.text('Open camera'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.import,
      dependencies: fixture.dependencies,
      fileName: 'issue-166-01-import-entry.png',
      ensureVisibleFinder: find.widgetWithText(
        FilledButton,
        'Choose artwork photo',
      ),
    );
    await captureImportActionVisualEvidence(
      tester,
      dependencies: fixture.dependencies,
      actionLabel: 'Choose artwork photo',
      settledState: find.text('No photo selected'),
      fileName: 'issue-166-02-import-cancelled.png',
    );
    await captureImportActionVisualEvidence(
      tester,
      dependencies: fixture.dependencies,
      actionLabel: 'Recover last import',
      settledState: find.text('Could not start this record'),
      fileName: 'issue-166-03-recover-unavailable.png',
    );
  });

  testWidgets('collection shell renders and can open add artwork', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const ArchivaleApp(initialRoute: AppRoutes.collection),
    );
    await pumpLiveData(tester);

    expect(find.text('Collection'), findsWidgets);
    expect(find.text('Needs review'), findsOneWidget);
    expect(find.text('Reports'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('No artworks yet'), findsOneWidget);
    expect(find.text('Blue Interior Study'), findsNothing);
    expect(find.text('Import CSV'), findsOneWidget);

    await tapVisible(tester, find.widgetWithText(FilledButton, 'Add artwork'));

    expect(find.text('Add artwork'), findsWidgets);
    expect(find.text('Photograph artwork'), findsOneWidget);
    expect(find.text('Choose artwork photo'), findsOneWidget);
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

  testWidgets('collection controls compose, sort, show no results, and clear', (
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
      await fixture.repository.createAll([
        _collectionQueryRecord(
          id: 'harbor',
          title: 'Harbor Study',
          artist: 'Zed Artist',
          notes: 'Needle note',
          location: 'Main Hall',
          state: ArtworkRecordState.missingDocuments,
        ),
        _collectionQueryRecord(
          id: 'alpha',
          title: 'Alpha Work',
          artist: 'Aster Artist',
          notes: 'Needle note',
          location: 'Archive',
          state: ArtworkRecordState.missingDocuments,
        ),
        _collectionQueryRecord(
          id: 'sold',
          title: 'Sold Needle',
          artist: 'Past Artist',
          notes: '',
          location: 'Main Hall',
          state: ArtworkRecordState.missingDocuments,
          lifecycleStatus: ArtworkLifecycleStatus.sold,
        ),
      ]);
    });
    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.collection,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(
      find.byKey(const ValueKey('collection-search-field')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('collection-sort-control')),
      findsOneWidget,
    );
    expect(find.text('Filters'), findsOneWidget);

    final sort = tester.widget<DropdownButtonFormField<ArtworkCollectionSort>>(
      find.byKey(const ValueKey('collection-sort-control')),
    );
    sort.onChanged!(ArtworkCollectionSort.title);
    await pumpLiveData(tester);
    expect(
      tester
          .widget<DropdownButtonFormField<ArtworkCollectionSort>>(
            find.byKey(const ValueKey('collection-sort-control')),
          )
          .initialValue,
      ArtworkCollectionSort.title,
    );

    await enterVisibleText(
      tester,
      find.byKey(const ValueKey('collection-search-field')),
      '  NEEDLE ',
    );
    await pumpLiveData(tester);
    await tapVisible(
      tester,
      find.byKey(const ValueKey('collection-filter-toggle')),
    );
    await tapVisible(tester, find.widgetWithText(FilterChip, 'Main Hall'));
    await tapVisible(
      tester,
      find.byKey(const ValueKey('missing-supporting-filter')),
    );
    await pumpLiveData(tester);

    expect(find.text('Filters 2'), findsOneWidget);
    expect(find.text('Harbor Study'), findsOneWidget);
    expect(find.text('Alpha Work'), findsNothing);
    expect(find.text('Sold Needle'), findsNothing);

    await tapVisible(tester, find.widgetWithText(FilterChip, 'Sold'));
    expect(find.text('No matching artworks'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('collection-no-results-clear')),
      findsOneWidget,
    );

    await tapVisible(
      tester,
      find.byKey(const ValueKey('collection-no-results-clear')),
    );
    expect(find.text('No matching artworks'), findsNothing);
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('collection-search-field')),
      find.byType(ListView).first,
      const Offset(0, 300),
    );
    expect(find.text('Filters'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('collection-search-field')),
          )
          .controller
          ?.text,
      isEmpty,
    );
    for (final title in ['Alpha Work', 'Harbor Study', 'Sold Needle']) {
      await tester.dragUntilVisible(
        find.text(title),
        find.byType(ListView).first,
        const Offset(0, -300),
      );
      expect(find.text(title), findsOneWidget);
    }
  });

  testWidgets('collection query is session-local across repository reopen', (
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
      await fixture.repository.create(
        _collectionQueryRecord(
          id: 'persisted-query-record',
          title: 'Persisted Collection Record',
          artist: 'Artist',
          notes: '',
          location: 'Studio',
          state: ArtworkRecordState.verifiedByYou,
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
    await enterVisibleText(
      tester,
      find.byKey(const ValueKey('collection-search-field')),
      'does not match',
    );
    await pumpLiveData(tester);
    expect(find.text('No matching artworks'), findsOneWidget);

    await tester.runAsync(fixture.reopenRepository);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.collection,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Persisted Collection Record'), findsOneWidget);
    expect(find.text('No matching artworks'), findsNothing);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('collection-search-field')),
          )
          .controller
          ?.text,
      isEmpty,
    );
  });

  testWidgets('empty collection stays distinct from query no-results', (
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
        initialRoute: AppRoutes.collection,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('No artworks yet'), findsOneWidget);
    expect(find.text('No matching artworks'), findsNothing);
    expect(find.byKey(const ValueKey('collection-search-field')), findsNothing);
  });

  testWidgets('free plan gates new artwork growth without hiding records', (
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
      for (var index = 1; index <= 5; index += 1) {
        await fixture.repository.upsert(
          _artworkRecord(
            id: 'free-limit-$index',
            title: 'Free Limit Artwork $index',
            state: ArtworkRecordState.verifiedByYou,
            source: ArtworkFieldSource.userConfirmed,
          ),
        );
      }
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.collection,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Free Limit Artwork 1'), findsOneWidget);
    expect(
      find.textContaining('Free plan: 5 of 5 active records'),
      findsOneWidget,
    );
    await tester.dragUntilVisible(
      find.text('Free plan is at capacity'),
      find.byType(ListView).first,
      const Offset(0, -300),
    );
    await tester.pump();

    expect(find.text('Free plan is at capacity'), findsOneWidget);
    expect(
      find.textContaining(
        'Starter plan can provide room for up to 50 active records',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Archivale AI research drafts each month'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Plan management is not configured in this app session.',
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Add artwork'), findsNothing);
    expect(find.text('Import CSV'), findsNothing);
  });

  testWidgets('direct add route respects the free active-artwork cap', (
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
      for (var index = 1; index <= 5; index += 1) {
        await fixture.repository.upsert(
          _artworkRecord(
            id: 'direct-free-limit-$index',
            title: 'Direct Free Limit Artwork $index',
            state: ArtworkRecordState.verifiedByYou,
            source: ArtworkFieldSource.userConfirmed,
          ),
        );
      }
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.collectionAdd,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Add artwork'), findsWidgets);
    expect(find.text('Free plan is at capacity'), findsOneWidget);
    expect(find.text('Photograph artwork'), findsNothing);
    expect(find.text('Choose artwork photo'), findsNothing);
  });

  testWidgets('free plan ignores retained inactive records for add gates', (
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
      for (var index = 1; index <= 4; index += 1) {
        await fixture.repository.upsert(
          _artworkRecord(
            id: 'active-free-$index',
            title: 'Active Free Artwork $index',
            state: ArtworkRecordState.verifiedByYou,
            source: ArtworkFieldSource.userConfirmed,
          ),
        );
      }
      await fixture.repository.upsert(
        _artworkRecord(
          id: 'removed-free-record',
          title: 'Removed Free Record',
          state: ArtworkRecordState.verifiedByYou,
          lifecycleStatus: ArtworkLifecycleStatus.removed,
          source: ArtworkFieldSource.userConfirmed,
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

    expect(
      find.textContaining('Free plan: 4 of 5 active records'),
      findsOneWidget,
    );
    await tester.dragUntilVisible(
      find.text('Removed Free Record'),
      find.byType(ListView).first,
      const Offset(0, -300),
    );
    await tester.pump();
    expect(find.text('Removed Free Record'), findsOneWidget);
    await tester.dragUntilVisible(
      find.widgetWithText(FilledButton, 'Add artwork'),
      find.byType(ListView).first,
      const Offset(0, -300),
    );
    await tester.pump();
    expect(find.widgetWithText(FilledButton, 'Add artwork'), findsOneWidget);

    await tapVisible(tester, find.widgetWithText(FilledButton, 'Add artwork'));

    expect(find.text('Photograph artwork'), findsOneWidget);
    expect(find.text('Choose artwork photo'), findsOneWidget);
    expect(find.text('Free plan is at capacity'), findsNothing);
  });

  testWidgets(
    'direct import rechecks plan before writing a stale sixth record',
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
        for (var index = 1; index <= 4; index += 1) {
          await fixture.repository.upsert(
            _artworkRecord(
              id: 'stale-free-$index',
              title: 'Stale Free Artwork $index',
              state: ArtworkRecordState.verifiedByYou,
              source: ArtworkFieldSource.userConfirmed,
            ),
          );
        }
      });
      final sourceImage = await tester.runAsync(
        () => fixture.writePngSource('stale-import.png'),
      );

      await tester.pumpWidget(
        ArchivaleApp(
          initialRoute: AppRoutes.import,
          dependencies: fixture.dependenciesWithPicker(
            _SingleImagePicker(sourceImage!),
          ),
        ),
      );
      await pumpLiveData(tester);

      expect(
        find.widgetWithText(FilledButton, 'Choose artwork photo'),
        findsOneWidget,
      );

      await tester.runAsync(() async {
        await fixture.repository.upsert(
          _artworkRecord(
            id: 'stale-free-fifth',
            title: 'Stale Free Fifth Artwork',
            state: ArtworkRecordState.verifiedByYou,
            source: ArtworkFieldSource.userConfirmed,
          ),
        );
      });

      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, 'Choose artwork photo'),
      );
      await pumpLiveData(tester);

      expect(find.text('Free plan is at capacity'), findsOneWidget);
      expect(find.text('Artwork photo added'), findsNothing);

      final records = await tester.runAsync(fixture.repository.list);
      expect(records, hasLength(5));
    },
  );

  testWidgets('reports tab summarizes local records instead of sample artwork', (
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
          id: 'local-report-record',
          title: 'Untitled artwork',
          state: ArtworkRecordState.verifiedByYou,
          source: ArtworkFieldSource.userConfirmed,
        ),
      );
      await fixture.addPrimaryImage(artworkId: 'local-report-record');
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.collectionReport,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Reports'), findsWidgets);
    expect(find.text('Preview artwork report'), findsOneWidget);
    expect(find.text('Preview record export'), findsNothing);

    await tapVisible(tester, find.text('Preview artwork report'));
    await pumpLiveData(tester);

    expect(find.text('Report preview'), findsWidgets);
    expect(
      find.text(
        'Ready a clear record for insurance conversations, estate organization, and personal files.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Report date:'), findsOneWidget);
    expect(find.text('Report date: July 3, 2026'), findsNothing);
  });

  testWidgets('reports tab gates report actions when no local records exist', (
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
        initialRoute: AppRoutes.collectionReport,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('No local records available'), findsOneWidget);
    expect(find.text('Preview artwork report'), findsNothing);
    expect(find.text('Preview record export'), findsNothing);
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

      expect(find.text('Bring in your spreadsheet'), findsOneWidget);
      expect(find.text('Private records stay on this device'), findsOneWidget);
      expect(find.text('Review everything before it is added'), findsOneWidget);
      expect(find.textContaining('possible duplicates'), findsOneWidget);
      expect(find.text('Choose spreadsheet'), findsOneWidget);
      expect(find.text('Load from path'), findsOneWidget);
      expect(find.text('Choose from system picker'), findsNothing);

      await enterVisibleText(
        tester,
        find.byKey(const ValueKey('csv-test-harness-path-field')),
        csvFile!.path,
      );
      await pressAsyncButton(
        tester,
        find.widgetWithText(OutlinedButton, 'Load from path'),
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

      expect(find.text('Preview your import'), findsOneWidget);
      expect(find.text('Ready to add: 1'), findsOneWidget);
      expect(find.text('Needs review: 1'), findsOneWidget);
      expect(find.text('Possible duplicate: 1'), findsOneWidget);
      expect(find.text('Needs more information: 1'), findsOneWidget);
      expect(find.text('Leave out'), findsOneWidget);
      expect(find.text('Add anyway'), findsOneWidget);

      await tapVisible(tester, find.text('Start over'));

      final recordsAfterCancel = await tester.runAsync(fixture.repository.list);
      expect(recordsAfterCancel!.map((record) => record.id), ['existing-001']);
      expect(find.text('Choose spreadsheet'), findsOneWidget);
      expect(find.text('Preview your import'), findsNothing);
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
        find.widgetWithText(FilledButton, 'Choose spreadsheet'),
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
      await tapVisible(tester, find.text('Add anyway'));
      await pressAsyncButton(
        tester,
        find.widgetWithText(FilledButton, 'Add to collection'),
      );

      expect(find.text('Import ready for review'), findsOneWidget);
      expect(find.text('Records added: 3'), findsOneWidget);
      expect(find.text('Possible duplicates left out: 0'), findsOneWidget);
      expect(find.text('Added with details to review: 1'), findsOneWidget);
      expect(find.text('Rows not added yet: 1'), findsOneWidget);

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
      final freshHarborRecord = recordsAfterImport
          .where(
            (record) =>
                record.field(ArtworkFieldKeys.title)?.value == 'Fresh Harbor',
          )
          .single;
      expect(freshHarborRecord.recordState, ArtworkRecordState.needsReview);
      expect(freshHarborRecord.primaryImageAttachmentId, isNull);
      expect(
        freshHarborRecord.field(ArtworkFieldKeys.title)?.source,
        ArtworkFieldSource.documentExtracted,
      );
      expect(
        recordsAfterImport.any(
          (record) =>
              record.field(ArtworkFieldKeys.title)?.value == 'Blue Interior' &&
              record.id != 'existing-001',
        ),
        isTrue,
      );

      await tapVisible(tester, find.text('Open first record'));
      await pumpLiveData(tester);

      expect(find.text('Draft review'), findsWidgets);
      expect(find.text('Local draft. Please confirm.'), findsOneWidget);
      expect(find.text('Fresh Harbor'), findsWidgets);
      expect(find.text('Primary image preview unavailable'), findsOneWidget);
      expect(find.text('Add evidence photos next'), findsOneWidget);
    },
  );

  testWidgets('csv import blocks writes that exceed the free artwork cap', (
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
      for (var index = 1; index <= 4; index += 1) {
        await fixture.repository.upsert(
          _artworkRecord(
            id: 'csv-free-limit-$index',
            title: 'CSV Free Limit Artwork $index',
            state: ArtworkRecordState.verifiedByYou,
            source: ArtworkFieldSource.userConfirmed,
          ),
        );
      }
    });

    final csvFile = await tester.runAsync(
      () => fixture.writeTextSource('over-limit-import.csv', _csvImportCsv),
    );

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.collectionImportCsv,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    await enterVisibleText(
      tester,
      find.byKey(const ValueKey('csv-test-harness-path-field')),
      csvFile!.path,
    );
    await pressAsyncButton(
      tester,
      find.widgetWithText(OutlinedButton, 'Load from path'),
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

    expect(find.text('Collection capacity before import'), findsOneWidget);
    expect(
      find.textContaining(
        'This import would bring this plan from 4 to 7 active records',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Starter plan can provide'), findsOneWidget);
    expect(
      find.textContaining('Archivale AI research drafts each month'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Plan management is not configured in this app session.',
      ),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(FilledButton, 'Add to collection'),
      findsNothing,
    );

    final recordsAfterBlockedImport = await tester.runAsync(
      fixture.repository.list,
    );
    expect(recordsAfterBlockedImport, hasLength(4));
  });

  testWidgets('csv import counts only active existing records for plan gates', (
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
      for (var index = 1; index <= 4; index += 1) {
        await fixture.repository.upsert(
          _artworkRecord(
            id: 'csv-active-free-$index',
            title: 'CSV Active Free Artwork $index',
            state: ArtworkRecordState.verifiedByYou,
            source: ArtworkFieldSource.userConfirmed,
          ),
        );
      }
      await fixture.repository.upsert(
        _artworkRecord(
          id: 'csv-sold-free-record',
          title: 'CSV Sold Free Record',
          state: ArtworkRecordState.verifiedByYou,
          lifecycleStatus: ArtworkLifecycleStatus.sold,
          source: ArtworkFieldSource.userConfirmed,
        ),
      );
    });

    final csvFile = await tester.runAsync(
      () => fixture.writeTextSource(
        'one-active-import.csv',
        'Work Name\nOne More Active Artwork\n',
      ),
    );

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.collectionImportCsv,
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    await enterVisibleText(
      tester,
      find.byKey(const ValueKey('csv-test-harness-path-field')),
      csvFile!.path,
    );
    await pressAsyncButton(
      tester,
      find.widgetWithText(OutlinedButton, 'Load from path'),
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

    expect(find.text('Collection capacity before import'), findsNothing);
    await pressAsyncButton(
      tester,
      find.widgetWithText(FilledButton, 'Add to collection'),
    );

    await waitForFinder(tester, find.text('Import ready for review'));
    expect(find.text('Import ready for review'), findsOneWidget);
    final records = await tester.runAsync(fixture.repository.list);
    expect(records, hasLength(6));
    expect(
      records!
          .where(
            (record) => record.lifecycleStatus == ArtworkLifecycleStatus.active,
          )
          .length,
      5,
    );
  });

  testWidgets('visual evidence covers billing upgrade copy states', (
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
      for (var index = 1; index <= 5; index += 1) {
        await fixture.repository.upsert(
          _artworkRecord(
            id: 'billing-visual-$index',
            title: 'Billing Visual Artwork $index',
            state: ArtworkRecordState.verifiedByYou,
            source: ArtworkFieldSource.userConfirmed,
          ),
        );
      }
    });

    await captureCollectionLimitVisualEvidence(
      tester,
      dependencies: fixture.dependencies,
      fileName: 'issue-173-01-collection-capacity-light.png',
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collectionAdd,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-173-02-add-artwork-capacity-light.png',
      ensureVisibleFinder: find.text('Free plan is at capacity'),
    );

    final csvFile = await tester.runAsync(
      () => fixture.writeTextSource('billing-limit-import.csv', _csvImportCsv),
    );
    await captureCsvImportPreviewVisualEvidence(
      tester,
      dependencies: fixture.dependencies,
      csvPath: csvFile!.path,
      fileName: 'issue-173-03-csv-capacity-light.png',
      ensureVisibleFinder: find.text('Collection capacity before import'),
    );
  });

  testWidgets('settings plan status covers billing status variants', (
    WidgetTester tester,
  ) async {
    final fixture = await tester.runAsync(
      () async => _LiveDependencyFixture.create(),
    );
    final testFixture = fixture!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(testFixture.dispose);
    });

    Future<void> verifyVariant({
      required EntitlementBillingStatus billingStatus,
      required String expectedCopy,
      required String fileName,
    }) async {
      await _configureMobileViewport(tester);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: ArchivaleApp(
            initialRoute: AppRoutes.collectionSettings,
            dependencies: testFixture.dependenciesWithFlags(
              entitlementService: StaticEntitlementService(
                state: EntitlementState(
                  plan: EntitlementPlans.starter,
                  billingStatus: billingStatus,
                ),
              ),
            ),
          ),
        ),
      );
      await pumpLiveData(tester);
      await tester.ensureVisible(find.text('Starter plan'));
      await tester.pump();

      expect(find.text('Starter plan'), findsOneWidget);
      expect(
        find.textContaining('Archivale AI research drafts each month'),
        findsOneWidget,
      );
      expect(find.textContaining(expectedCopy), findsOneWidget);
      await captureBoundaryToArtifacts(tester, boundaryKey, fileName);
    }

    await verifyVariant(
      billingStatus: EntitlementBillingStatus.available,
      expectedCopy: 'Review your plan, restore purchases',
      fileName: 'issue-173-04-settings-plan-available-light.png',
    );
    await verifyVariant(
      billingStatus: EntitlementBillingStatus.unavailable,
      expectedCopy: 'Plan changes are unavailable on this device right now.',
      fileName: 'issue-173-05-settings-plan-unavailable-light.png',
    );
    await verifyVariant(
      billingStatus: EntitlementBillingStatus.notConfigured,
      expectedCopy: 'Plan management is not configured in this app session.',
      fileName: 'issue-173-06-settings-plan-not-configured-light.png',
    );
  });

  testWidgets('captures issue 193 billing mobile states', (tester) async {
    final fixture = await tester.runAsync(_LiveDependencyFixture.create);
    final testFixture = fixture!;
    addTearDown(() async => tester.runAsync(testFixture.dispose));
    final billing = _FakeBillingManagementService(
      productsValue: const [
        PlayProduct(
          id: 'archivale_starter_monthly',
          title: 'Starter monthly',
          description: 'Up to 50 active artworks',
          price: 'NOK 35.00',
        ),
      ],
    );

    Future<void> captureState({
      required EntitlementState state,
      required String fileName,
      bool resetAfterCapture = true,
    }) async {
      billing.state = state;
      final boundaryKey = GlobalKey();
      await _configureMobileViewport(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: ArchivaleApp(
            key: ValueKey(fileName),
            initialRoute: AppRoutes.billing,
            dependencies: testFixture.dependenciesWithFlags(
              entitlementService: billing,
              billingManagementService: billing,
            ),
          ),
        ),
      );
      await pumpLiveData(tester);
      final billingScrollable = find.descendant(
        of: find.byKey(const ValueKey('billing-plan-scrollable')),
        matching: find.byType(Scrollable),
      );
      expect(billingScrollable, findsOneWidget);
      tester.state<ScrollableState>(billingScrollable).position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(billingScrollable).position.pixels,
        0,
      );
      await captureBoundaryToArtifacts(
        tester,
        boundaryKey,
        fileName,
        resetAfterCapture: resetAfterCapture,
      );
    }

    await captureState(
      state: const EntitlementState(
        plan: EntitlementPlans.free,
        billingStatus: EntitlementBillingStatus.available,
      ),
      fileName: 'issue-193-01-plan-localized-price-mobile.png',
      resetAfterCapture: false,
    );
    await tester.scrollUntilVisible(find.text('Choose plan'), 300);
    await tester.tap(find.widgetWithText(FilledButton, 'Choose plan'));
    await tester.pumpAndSettle();
    final disclosureKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: disclosureKey,
        child: ArchivaleApp(
          initialRoute: AppRoutes.billing,
          dependencies: testFixture.dependenciesWithFlags(
            entitlementService: billing,
            billingManagementService: billing,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Reopen after rebuilding into the screenshot boundary.
    await tester.scrollUntilVisible(find.text('Choose plan'), 300);
    await tester.tap(find.widgetWithText(FilledButton, 'Choose plan'));
    await tester.pumpAndSettle();
    await captureBoundaryToArtifacts(
      tester,
      disclosureKey,
      'issue-193-02-disclosure-mobile.png',
      resetAfterCapture: false,
    );

    for (final entry in <(EntitlementState, String)>[
      (
        const EntitlementState(
          plan: EntitlementPlans.starter,
          billingStatus: EntitlementBillingStatus.available,
          lifecycle: EntitlementLifecycle.grace,
        ),
        'issue-193-03-grace-mobile.png',
      ),
      (
        const EntitlementState(
          plan: EntitlementPlans.starter,
          billingStatus: EntitlementBillingStatus.available,
          lifecycle: EntitlementLifecycle.canceledThroughExpiry,
        ),
        'issue-193-04-canceled-mobile.png',
      ),
      (
        const EntitlementState(
          plan: EntitlementPlans.free,
          billingStatus: EntitlementBillingStatus.unavailable,
          lifecycle: EntitlementLifecycle.expired,
        ),
        'issue-193-05-expired-unavailable-mobile.png',
      ),
    ]) {
      await captureState(state: entry.$1, fileName: entry.$2);
    }
  });

  for (final entry in <(EntitlementState, String)>[
    (
      const EntitlementState(
        plan: EntitlementPlans.free,
        billingStatus: EntitlementBillingStatus.available,
        presentation: EntitlementPresentation.playPending,
      ),
      'issue-193-06-pending-mobile.png',
    ),
    (
      const EntitlementState(
        plan: EntitlementPlans.free,
        billingStatus: EntitlementBillingStatus.available,
        presentation: EntitlementPresentation.restoring,
      ),
      'issue-193-08-restoring-mobile.png',
    ),
    (
      const EntitlementState(
        plan: EntitlementPlans.free,
        billingStatus: EntitlementBillingStatus.available,
        presentation: EntitlementPresentation.refreshing,
      ),
      'issue-193-09-refreshing-mobile.png',
    ),
    (
      const EntitlementState(
        plan: EntitlementPlans.free,
        billingStatus: EntitlementBillingStatus.unavailable,
      ),
      'issue-193-10-account-change-fallback-mobile.png',
    ),
    (
      const EntitlementState(
        plan: EntitlementPlans.free,
        billingStatus: EntitlementBillingStatus.available,
      ),
      'issue-193-11-restart-foreground-fallback-mobile.png',
    ),
  ]) {
    testWidgets('captures ${entry.$2}', (tester) async {
      await _captureIssue193BillingState(tester, entry.$1, entry.$2);
    });
  }

  testWidgets('captures issue-193-07-verifying-mobile.png', (tester) async {
    await _captureIssue193BillingState(
      tester,
      const EntitlementState(
        plan: EntitlementPlans.free,
        billingStatus: EntitlementBillingStatus.available,
      ),
      'issue-193-07-verifying-mobile.png',
      showVerifyingFlow: true,
    );
  });

  testWidgets(
    'captures pending billing state with a complete disabled purchase choice',
    (tester) async {
      await _captureIssue193BillingState(
        tester,
        const EntitlementState(
          plan: EntitlementPlans.free,
          billingStatus: EntitlementBillingStatus.available,
          presentation: EntitlementPresentation.playPending,
        ),
        'issue-193-12-pending-disabled-choice-mobile.png',
        showDisabledPurchaseChoice: true,
      );
    },
  );

  testWidgets('captures recovery exhausted billing state', (tester) async {
    await _captureIssue193BillingState(
      tester,
      const EntitlementState(
        plan: EntitlementPlans.free,
        billingStatus: EntitlementBillingStatus.available,
        presentation: EntitlementPresentation.recoveryExhausted,
      ),
      'issue-193-13-recovery-exhausted-mobile.png',
    );
  });

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
      const Locale('en'): ['Collection', 'Needs review', 'Reports', 'Settings'],
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
    await pumpLiveData(tester);

    await tapVisible(tester, find.widgetWithText(FilledButton, 'Add artwork'));
    await tapVisible(tester, find.text('Choose artwork photo').last);
    expect(find.text('Artwork photo added'), findsOneWidget);
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
      find.text(
        '3 of 8 core fields are confirmed by you or supported by document review.',
      ),
      findsOneWidget,
    );

    await tapVisible(tester, find.text('Add supporting records'));
    expect(find.text('Documents'), findsWidgets);
    expect(find.text('gallery-receipt-2025.pdf'), findsOneWidget);
    expect(find.text('Original document attachments'), findsOneWidget);
    expect(find.text('No supporting documents yet'), findsNothing);

    await tapVisible(
      tester,
      find.widgetWithText(OutlinedButton, 'Report preview').last,
    );
    expect(
      find.text(
        'Ready a clear record for insurance conversations, estate organization, and personal files.',
      ),
      findsOneWidget,
    );
    expect(find.text('Purchase price: USD 1,800.'), findsOneWidget);
    expect(
      find.text('User-provided insurance value: USD 2,400.'),
      findsOneWidget,
    );

    expect(find.text('Preview record export'), findsNothing);
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
    await pumpLiveData(tester);

    expect(
      find.widgetWithText(FilledButton, 'Choose artwork photo'),
      findsOneWidget,
    );
    expect(find.text('Evidence photo checklist'), findsOneWidget);
    expect(find.text('Choose artwork photo'), findsWidgets);
    expect(find.text('Recover last import'), findsOneWidget);
    expect(find.text('Upload-failure state'), findsNothing);

    await tapVisible(tester, find.text('Recover last import'));
    await pumpLiveData(tester);

    expect(find.text('Could not start this record'), findsOneWidget);
    expect(
      find.textContaining('No previous import was found.'),
      findsOneWidget,
    );
    expect(find.text('Evidence photo checklist'), findsOneWidget);
    expect(find.textContaining('prints or lithographs'), findsOneWidget);
    expect(find.textContaining('Receipts, certificates'), findsOneWidget);
    expect(find.text('Choose artwork photo'), findsWidgets);
    expect(find.text('Recover last import'), findsOneWidget);
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
    await pumpLiveData(tester);

    await tapVisible(
      tester,
      find.widgetWithText(FilledButton, 'Choose artwork photo'),
    );
    await pumpLiveData(tester);

    expect(find.text('No photo selected'), findsOneWidget);
    expect(find.textContaining('Photo import was cancelled.'), findsOneWidget);
    expect(find.text('Could not start this record'), findsNothing);
    expect(find.text('Choose artwork photo'), findsWidgets);
    expect(find.text('Recover last import'), findsOneWidget);
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
    await pumpLiveData(tester);

    await chooseArtworkPhotoForTest(tester);

    expect(find.text('Artwork photo added'), findsOneWidget);
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
      expect(find.text('No supporting documents yet'), findsOneWidget);
      expect(find.text('Attach supporting document'), findsOneWidget);
      expect(find.text('Import supporting photo'), findsOneWidget);

      await tapVisible(tester, find.text('Import supporting photo'));
      await pumpLiveData(tester);
      expect(find.text('Import supporting photo'), findsWidgets);
      expect(find.text('Supporting UI Artwork'), findsWidgets);
      expect(find.text('Saved with this artwork'), findsOneWidget);

      await pressAsyncButton(
        tester,
        find.widgetWithText(FilledButton, 'Choose a supporting photo'),
      );

      expect(find.text('Supporting photo imported'), findsOneWidget);
      expect(
        find.text(
          'Added to this artwork as a supporting record. Your main artwork image is unchanged.',
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
      expect(find.text('No supporting documents yet'), findsNothing);

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
      expect(find.text('1 supporting record added.'), findsOneWidget);

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
    await pumpLiveData(tester);

    expect(find.text('Add supporting records next'), findsOneWidget);
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
    await waitForFinder(tester, find.text('Attach supporting document'));

    expect(find.text('No supporting documents yet'), findsOneWidget);
    expect(find.text('Attach supporting document'), findsOneWidget);
    expect(find.text('Import supporting photo'), findsOneWidget);
    expect(find.text('Add paper records as photos for now'), findsNothing);
    expect(find.text('Attachment needs attention'), findsNothing);
    expect(find.text('Attach document'), findsNothing);
  });

  testWidgets('downloadable on-device AI lets the user download and retry', (
    WidgetTester tester,
  ) async {
    final provider = _DownloadFlowAiDraftProvider();
    final testDependencies = await tester.runAsync(
      () async =>
          _LiveDependencyFixture.create(onDeviceAiDraftProvider: provider),
    );
    final fixture = testDependencies!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.dispose);
    });

    final sourceImage = await tester.runAsync(
      () => fixture.writePngSource('picker-downloadable-primary.png'),
    );

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.import,
        dependencies: fixture.dependenciesWithPicker(
          _SingleImagePicker(sourceImage!),
        ),
      ),
    );
    await pumpLiveData(tester);

    await chooseArtworkPhotoForTest(tester);

    await waitForFinder(tester, find.text('On-device AI download ready'));
    expect(find.text('Download on-device AI'), findsOneWidget);
    expect(find.textContaining('No photo was sent online'), findsOneWidget);

    await pressAsyncButton(
      tester,
      find.widgetWithText(FilledButton, 'Download on-device AI'),
    );
    await pumpLiveData(tester);

    expect(find.text('On-device AI downloading'), findsOneWidget);
    expect(find.text('Check again'), findsOneWidget);

    await pressAsyncButton(
      tester,
      find.widgetWithText(FilledButton, 'Check again'),
    );
    await pumpLiveData(tester);

    expect(find.text('Private AI draft saved'), findsOneWidget);
    expect(provider.createDraftCount, 1);
  });

  testWidgets('download failure copy stays sanitized and retryable', (
    WidgetTester tester,
  ) async {
    final provider = _DownloadFailureAiDraftProvider();
    final testDependencies = await tester.runAsync(
      () async =>
          _LiveDependencyFixture.create(onDeviceAiDraftProvider: provider),
    );
    final fixture = testDependencies!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.dispose);
    });

    final sourceImage = await tester.runAsync(
      () => fixture.writePngSource('picker-download-failure-primary.png'),
    );

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.import,
        dependencies: fixture.dependenciesWithPicker(
          _SingleImagePicker(sourceImage!),
        ),
      ),
    );
    await pumpLiveData(tester);

    await chooseArtworkPhotoForTest(tester);

    await pressAsyncButton(
      tester,
      find.widgetWithText(FilledButton, 'Download on-device AI'),
    );
    await pumpLiveData(tester);

    expect(find.text('On-device AI download failed'), findsOneWidget);
    expect(find.text('Retry download'), findsOneWidget);
    expect(find.textContaining('Portrait of Ada'), findsNothing);
    expect(find.textContaining('/data/user/0/'), findsNothing);
  });

  testWidgets('captures issue 136 on-device AI portrait visual states', (
    WidgetTester tester,
  ) async {
    await _captureIssue136OnDeviceAiImportState(
      tester,
      provider: const _StaticCapabilityAiDraftProvider(
        capability: OnDeviceAiCapability(
          availability: OnDeviceAiAvailability.downloadable,
          deviceModel: 'Pixel test device',
          message: 'Gemini Nano support is downloadable but not ready yet.',
        ),
      ),
      expectedTitle: 'On-device AI download ready',
      fileName: 'issue-136-aicore-download/download-ready-mobile.png',
    );

    await _captureIssue136OnDeviceAiImportState(
      tester,
      provider: const _StaticCapabilityAiDraftProvider(
        capability: OnDeviceAiCapability(
          availability: OnDeviceAiAvailability.downloading,
          deviceModel: 'Pixel test device',
          message:
              'Gemini Nano support is still downloading. Try again after it finishes.',
        ),
      ),
      expectedTitle: 'On-device AI downloading',
      fileName: 'issue-136-aicore-download/downloading-mobile.png',
    );

    await _captureIssue136OnDeviceAiImportState(
      tester,
      provider: const _StaticCapabilityAiDraftProvider(
        capability: OnDeviceAiCapability(
          availability: OnDeviceAiAvailability.downloadFailed,
          deviceModel: 'Pixel test device',
          message:
              'On-device AI download could not finish yet. Try again after checking AICore.',
        ),
      ),
      expectedTitle: 'On-device AI download failed',
      fileName: 'issue-136-aicore-download/download-failed-mobile.png',
    );

    await _captureIssue136OnDeviceAiImportState(
      tester,
      provider: const _CompletedAiDraftProvider(),
      expectedTitle: 'Private AI draft saved',
      fileName: 'issue-136-aicore-download/private-ai-draft-saved-mobile.png',
    );
  });
  testWidgets(
    'supporting photo busy state matches import and capture intake modes',
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
            id: 'supporting-busy-state',
            title: 'Supporting Busy State',
            state: ArtworkRecordState.verifiedByYou,
            source: ArtworkFieldSource.userConfirmed,
          ),
        );
        await fixture.addPrimaryImage(artworkId: 'supporting-busy-state');
      });

      final importPicker = _PendingImagePicker();
      await tester.pumpWidget(
        ArchivaleApp(
          initialRoute: AppRoutes.artworkSupportingPhotoImport(
            'supporting-busy-state',
          ),
          dependencies: fixture.dependenciesWithPicker(importPicker),
        ),
      );
      await pumpLiveData(tester);
      await waitForFinder(tester, find.text('Choose a supporting photo'));

      await tapVisible(tester, find.text('Choose a supporting photo'));
      await pumpLiveData(tester);

      expect(find.text('Opening photo picker'), findsOneWidget);
      expect(
        find.text(
          'Choose one photo to keep with this artwork as a supporting record.',
        ),
        findsOneWidget,
      );

      importPicker.complete(ArtworkImagePickMode.gallery, null);
      await pumpLiveData(tester);
      expect(find.text('Supporting photo cancelled'), findsOneWidget);

      final capturePicker = _PendingImagePicker();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        ArchivaleApp(
          initialRoute: AppRoutes.artworkSupportingPhotoCapture(
            'supporting-busy-state',
          ),
          dependencies: fixture.dependenciesWithPicker(capturePicker),
        ),
      );
      await pumpLiveData(tester);
      await waitForFinder(tester, find.text('Take a supporting photo'));

      await tapVisible(tester, find.text('Take a supporting photo'));
      await pumpLiveData(tester);

      expect(find.text('Opening camera'), findsOneWidget);
      expect(
        find.text(
          'Take one photo to keep with this artwork as a supporting record.',
        ),
        findsOneWidget,
      );
      expect(find.text('Opening photo picker'), findsNothing);

      capturePicker.complete(ArtworkImagePickMode.camera, null);
      await pumpLiveData(tester);
      expect(find.text('Supporting photo cancelled'), findsOneWidget);
    },
  );

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
    expect(find.text('Needs review'), findsWidgets);
    expect(find.text('No artworks yet'), findsNothing);
    expect(find.textContaining('details still need review'), findsOneWidget);
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
          state: ArtworkRecordState.missingDocuments,
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
    expect(find.text('Private collection records'), findsNothing);
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
    const relativePath =
        'artworks/missing-image/attachments/primary-missing-image/payload.png';

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
          relativePath: relativePath,
          fileName: 'private-secret-file.png',
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
    await pumpLiveData(tester);

    await tester.runAsync(() async {
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Choose artwork photo'),
      );
      button.onPressed!();
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await pumpLiveData(tester);

    expect(find.text('Artwork photo added'), findsOneWidget);
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
          state: ArtworkRecordState.missingDocuments,
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
    expect(find.text('Nothing needs review'), findsOneWidget);
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

      expect(find.text('Record status'), findsOneWidget);
      expect(
        find.text('This artwork counts as part of your current holdings.'),
        findsOneWidget,
      );

      await tapVisible(tester, find.widgetWithText(ActionChip, 'Sold'));
      await waitForFinder(
        tester,
        find.text('This record stays in your archive and is marked sold.'),
      );
      expect(
        find.text('This record stays in your archive and is marked sold.'),
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
      await waitForFinder(tester, find.text('Remove from current holdings?'));
      expect(find.text('Remove from current holdings?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await pumpReady(tester);
      saved = await tester.runAsync<ArtworkRecord?>(
        () => fixture.repository.get('lifecycle-ui'),
      );
      expect(saved?.lifecycleStatus, ArtworkLifecycleStatus.stolen);

      await tapVisible(tester, find.widgetWithText(ActionChip, 'Removed'));
      await waitForFinder(tester, find.text('Remove from current holdings?'));
      expect(find.text('Remove from current holdings?'), findsOneWidget);
      await tester.tap(find.text('Mark as removed'));
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
        find.textContaining('Marked removed; kept in your record history.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'free plan blocks lifecycle reactivation when active limit is reached',
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
        for (var index = 0; index < 5; index += 1) {
          await fixture.repository.upsert(
            _artworkRecord(
              id: 'lifecycle-active-free-$index',
              title: 'Lifecycle Active Free $index',
              state: ArtworkRecordState.verifiedByYou,
              source: ArtworkFieldSource.userConfirmed,
            ),
          );
        }
        await fixture.repository.upsert(
          _artworkRecord(
            id: 'lifecycle-sold-free',
            title: 'Lifecycle Sold Free',
            state: ArtworkRecordState.verifiedByYou,
            lifecycleStatus: ArtworkLifecycleStatus.sold,
            source: ArtworkFieldSource.userConfirmed,
          ),
        );
      });

      await tester.pumpWidget(
        ArchivaleApp(
          initialRoute: AppRoutes.artworkDetails('lifecycle-sold-free'),
          dependencies: fixture.dependencies,
        ),
      );
      await pumpLiveData(tester);

      await waitForFinder(tester, find.text('Record status'));
      await pumpLiveData(tester);
      expect(find.text('Record status'), findsOneWidget);
      await waitForFinder(
        tester,
        find.text(
          'This record stays in your archive and is marked sold.',
          skipOffstage: false,
        ),
        attempts: 60,
      );
      expect(find.widgetWithText(ActionChip, 'Active'), findsOneWidget);

      await tapVisible(tester, find.widgetWithText(ActionChip, 'Active'));
      await pumpLiveData(tester);

      final records = await tester.runAsync<List<ArtworkRecord>>(
        fixture.repository.list,
      );
      final savedRecords = records!;
      final activeCount = savedRecords
          .where(
            (record) => record.lifecycleStatus == ArtworkLifecycleStatus.active,
          )
          .length;
      final soldRecord = savedRecords.firstWhere(
        (record) => record.id == 'lifecycle-sold-free',
      );

      expect(activeCount, 5);
      expect(soldRecord.lifecycleStatus, ArtworkLifecycleStatus.sold);
      expect(
        find.textContaining(
          'This plan already holds all of its active records',
          skipOffstage: false,
        ),
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
      find.textContaining('not treated as an active artwork that needs review'),
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

    expect(find.text('Edit private record'), findsOneWidget);
    expect(find.text('Confirm the details you want to keep'), findsOneWidget);
    expect(find.text('Untitled artwork'), findsNothing);
    expect(find.text('Unknown'), findsNothing);
    expect(find.text('Needs review'), findsNothing);

    await tapVisible(tester, find.text('Save confirmed details'));
    await pumpLiveData(tester);

    final saved = await tester.runAsync(
      () => fixture.repository.get('placeholder-draft'),
    );
    expect(saved, isNotNull);
    expect(saved!.recordState, ArtworkRecordState.needsReview);
    expect(saved.field(ArtworkFieldKeys.title), isNull);
    expect(saved.field(ArtworkFieldKeys.conditionNotes), isNull);

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
      find.text(
        '0 of 8 core fields are confirmed by you or supported by document review.',
      ),
      findsOneWidget,
    );
    expect(find.text('Title pending review.'), findsWidgets);
    expect(find.text('Artist not yet confirmed.'), findsOneWidget);
    expect(find.text('Purchase price not recorded.'), findsOneWidget);
    expect(find.text('Untitled artwork'), findsNothing);
    expect(find.text('Not set'), findsNothing);
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
    await tapVisible(tester, find.text('Save confirmed details'));
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
    expect(saved.field(ArtworkFieldKeys.artist), isNull);

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
      find.text(
        '1 of 8 core fields are confirmed by you or supported by document review.',
      ),
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
    expect(find.text('Confirm the details you want to keep'), findsOneWidget);

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

    await tapVisible(tester, find.text('Save confirmed details'));
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
      find.text('Nothing else needs review for this record.'),
      findsOneWidget,
    );

    await tapVisible(tester, find.text('Open record'));
    await pumpLiveData(tester);

    expect(find.text('Verified by you'), findsWidgets);
    expect(find.text('Manual Confirmed Title'), findsWidgets);
    expect(find.text('Manual Artist'), findsOneWidget);
    expect(find.text('1998'), findsWidgets);
    expect(
      find.text(
        '8 of 8 core fields are confirmed by you or supported by document review.',
      ),
      findsOneWidget,
    );
    expect(find.text('NOK 12,000'), findsOneWidget);
    expect(find.text('User confirmed'), findsWidgets);

    await tapVisible(tester, find.text('Report preview'));
    await pumpLiveData(tester);

    expect(
      find.text(
        'Ready a clear record for insurance conversations, estate organization, and personal files.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('User-provided insurance value: NOK 12,000.'),
      findsOneWidget,
    );
  });

  testWidgets('edition stays review-needed until a manual save confirms it', (
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
          id: 'edition-review',
          title: 'Edition Study',
          state: ArtworkRecordState.verifiedByYou,
          source: ArtworkFieldSource.userConfirmed,
          overrides: {
            ArtworkFieldKeys.edition: const ArtworkFieldValue(
              value: '12/75',
              source: ArtworkFieldSource.documentExtracted,
              note: 'Imported from a CSV column and needs review.',
            ),
          },
        ),
      );
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkDetails('edition-review'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);
    expect(find.text('Edition'), findsOneWidget);
    expect(find.text('Document-extracted'), findsOneWidget);
    expect(
      find.text('Imported from a CSV column and needs review.'),
      findsOneWidget,
    );
    for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
      final themeName = themeMode == ThemeMode.light ? 'light' : 'dark';
      await captureArtifactForApp(
        tester,
        routeName: AppRoutes.artworkDetails('edition-review'),
        dependencies: fixture.dependencies,
        themeMode: themeMode,
        fileName: 'issue-212-edition-detail-$themeName.png',
        ensureVisibleFinder: find.text('Edition'),
        minimumTopClearance: 4,
      );
      await captureArtifactForApp(
        tester,
        routeName: AppRoutes.artworkEdit('edition-review'),
        dependencies: fixture.dependencies,
        themeMode: themeMode,
        fileName: 'issue-212-edition-edit-$themeName.png',
        ensureVisibleFinder: find.byKey(const ValueKey('artwork-edit-edition')),
        revealTopPadding: 80,
        minimumTopClearance: 4,
      );
      await captureArtifactForApp(
        tester,
        routeName: AppRoutes.artworkReportPreview('edition-review'),
        dependencies: fixture.dependencies,
        themeMode: themeMode,
        fileName: 'issue-212-edition-report-$themeName.png',
        ensureVisibleFinder: find.text('Report preview'),
        minimumTopClearance: 0,
      );
    }

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkDetails('edition-review'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    await tapVisible(tester, find.text('Report preview'));
    await pumpLiveData(tester);
    expect(
      find.text('Edition - document-extracted, needs review: 12/75.'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkEdit('edition-review'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);
    await tapVisible(tester, find.text('Save confirmed details'));
    await pumpLiveData(tester);

    final saved = await tester.runAsync(
      () => fixture.repository.get('edition-review'),
    );
    expect(
      saved?.field(ArtworkFieldKeys.edition)?.source,
      ArtworkFieldSource.userConfirmed,
    );
    expect(saved?.field(ArtworkFieldKeys.edition)?.lastConfirmedAt, isNotNull);

    for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
      final themeName = themeMode == ThemeMode.light ? 'light' : 'dark';
      await captureArtifactForApp(
        tester,
        routeName: AppRoutes.artworkDetails('edition-review'),
        dependencies: fixture.dependencies,
        themeMode: themeMode,
        fileName: 'issue-212-edition-confirmed-detail-$themeName.png',
        ensureVisibleFinder: find.text('Edition'),
        minimumTopClearance: 4,
      );
      await captureArtifactForApp(
        tester,
        routeName: AppRoutes.artworkReportPreview('edition-review'),
        dependencies: fixture.dependencies,
        themeMode: themeMode,
        fileName: 'issue-212-edition-confirmed-report-$themeName.png',
        ensureVisibleFinder: find.text('Report preview'),
        minimumTopClearance: 0,
      );
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkDetails('edition-review'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);
    expect(find.text('User confirmed'), findsWidgets);
    await tapVisible(tester, find.text('Report preview'));
    await pumpLiveData(tester);
    expect(find.text('Edition - User confirmed: 12/75.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkEdit('edition-review'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);
    await enterVisibleText(
      tester,
      find.byKey(const ValueKey('artwork-edit-edition')),
      '',
    );
    await tapVisible(tester, find.text('Save confirmed details'));
    await pumpLiveData(tester);
    final cleared = await tester.runAsync(
      () => fixture.repository.get('edition-review'),
    );
    expect(cleared?.field(ArtworkFieldKeys.edition), isNull);
    expect(cleared?.recordState, ArtworkRecordState.verifiedByYou);
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

      expect(find.text('Preview record export'), findsNothing);
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

    expect(find.text('Research this draft'), findsNothing);
    expect(find.text('Research consent'), findsNothing);
    expect(find.text('Source-backed candidates'), findsNothing);
    expect(find.text('Research unavailable'), findsOneWidget);
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

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: ArchivaleApp(
          initialRoute: AppRoutes.artworkDraft('research-draft'),
          dependencies: fixture.dependenciesWithFlags(
            featureFlags: const AppFeatureFlags(
              localResearchCapabilityEnabled: true,
            ),
          ),
        ),
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Research this draft'), findsOneWidget);
    expect(find.text('Source-backed candidates'), findsNothing);

    await tapVisible(tester, find.text('Research this draft'));

    expect(find.text('Research consent'), findsOneWidget);
    expect(find.text(researchConsentPayloadDisclosure), findsOneWidget);
    expect(find.text(researchConsentExternalServiceDisclosure), findsOneWidget);
    expect(researchConsentPayloadDisclosure, contains('EXIF-free derivative'));
    expect(
      researchConsentPayloadDisclosure,
      contains('title, artist, and search hints'),
    );
    for (final excluded in <String>[
      'notes',
      'private summaries',
      'artwork IDs',
      'filenames',
      'paths',
      'values',
      'locations',
      'documents',
    ]) {
      expect(researchConsentPayloadDisclosure, contains(excluded));
    }
    expect(
      researchConsentExternalServiceDisclosure,
      contains('third-party web sources'),
    );
    expect(
      researchConsentExternalServiceDisclosure,
      contains('their own retention policies'),
    );
    await tester.ensureVisible(find.text('Research consent'));
    await tester.pump();
    await captureBoundaryToArtifacts(
      tester,
      boundaryKey,
      'issue-168-ai-research-consent-mobile.png',
      resetAfterCapture: false,
    );

    await tapVisible(tester, find.text('Skip online research'));

    expect(find.text('Research this draft'), findsOneWidget);
    expect(find.text('Source-backed candidates'), findsNothing);

    await tapVisible(tester, find.text('Research this draft'));
    await tapVisible(tester, find.text('Start source-backed research'));
    await pumpLiveData(tester);
    await waitForFinder(tester, find.text('Source-backed candidates'));
    await tester.ensureVisible(find.text('Source-backed candidates'));
    await tester.pump();
    await captureBoundaryToArtifacts(
      tester,
      boundaryKey,
      'issue-168-ai-research-results-mobile.png',
      resetAfterCapture: false,
    );

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

  testWidgets('online research failure branch uses Archivale-facing copy', (
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
          id: 'research-failure-draft',
          title: 'Interior Study',
          state: ArtworkRecordState.needsReview,
        ),
      );
    });

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: ArchivaleApp(
          initialRoute: AppRoutes.artworkDraft('research-failure-draft'),
          dependencies: fixture.dependenciesWithFlags(
            featureFlags: const AppFeatureFlags(
              localResearchCapabilityEnabled: true,
            ),
            onlineResearchClient: _ThrowingResearchClient(
              ResearchConsentRequiredException(ResearchConsentState.declined),
            ),
          ),
        ),
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('Research this draft'), findsOneWidget);

    await tapVisible(tester, find.text('Research this draft'));
    await tapVisible(tester, find.text('Start source-backed research'));
    await pumpLiveData(tester);

    expect(find.text('Research unavailable'), findsOneWidget);
    expect(
      find.textContaining(
        'Research consent needs to be reviewed before Archivale can run source-backed research.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Online research'), findsNothing);

    await tester.ensureVisible(find.text('Research unavailable'));
    await tester.pump();
    await captureBoundaryToArtifacts(
      tester,
      boundaryKey,
      'issue-168-ai-research-failure-mobile.png',
      resetAfterCapture: false,
    );
  });

  testWidgets('issue 189 captures consent-gated broker research states', (
    WidgetTester tester,
  ) async {
    final fixture = await tester.runAsync(_LiveDependencyFixture.create);
    final testFixture = fixture!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(testFixture.dispose);
    });
    await _configureMobileViewport(tester);

    Future<void> captureState({
      required String id,
      required String fileName,
      required AppFeatureFlags flags,
      required Finder settledState,
      OnlineResearchClient? client,
      bool openConsent = false,
      bool startResearch = false,
      ThemeMode themeMode = ThemeMode.light,
    }) async {
      await tester.runAsync(
        () => testFixture.repository.upsert(
          _artworkRecord(
            id: id,
            title: 'Issue 189 research draft',
            state: ArtworkRecordState.needsReview,
          ),
        ),
      );
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: ArchivaleApp(
            key: ValueKey(fileName),
            initialRoute: AppRoutes.artworkDraft(id),
            themeMode: themeMode,
            dependencies: testFixture.dependenciesWithFlags(
              featureFlags: flags,
              onlineResearchClient: client,
            ),
          ),
        ),
      );
      await pumpLiveData(tester);
      if (openConsent || startResearch) {
        await tapVisible(tester, find.text('Research this draft'));
      }
      if (startResearch) {
        await tapVisible(tester, find.text('Start source-backed research'));
      }
      await waitForFinder(tester, settledState, attempts: 80);
      final panel = find.byKey(const ValueKey('online-research-panel'));
      await Scrollable.ensureVisible(
        tester.element(panel),
        alignment: 0,
        duration: Duration.zero,
      );
      await tester.pump();
      expect(
        tester.getTopLeft(panel).dy,
        inInclusiveRange(54, 58),
        reason: fileName,
      );
      expect(tester.takeException(), isNull, reason: fileName);
      await captureBoundaryToArtifacts(
        tester,
        key,
        fileName,
        resetAfterCapture: false,
      );
    }

    const enabled = AppFeatureFlags(localResearchCapabilityEnabled: true);
    await captureState(
      id: 'issue189-gated',
      fileName: 'issue-189-gated-unavailable-light.png',
      flags: const AppFeatureFlags(),
      settledState: find.text('Research unavailable'),
    );
    expect(find.text('Research unavailable'), findsOneWidget);
    await captureState(
      id: 'issue189-consent',
      fileName: 'issue-189-consent-light.png',
      flags: enabled,
      settledState: find.text('Research consent'),
      client: FixtureProfessionalSourceResearchClient(),
      openConsent: true,
    );
    expect(find.text('Research consent'), findsOneWidget);
    await captureState(
      id: 'issue189-loading',
      fileName: 'issue-189-loading-light.png',
      flags: enabled,
      settledState: find.text('Researching...'),
      client: _PendingResearchClient(),
      startResearch: true,
    );
    expect(find.text('Researching...'), findsOneWidget);
    for (final entry in <(String, String, String, bool)>[
      ('offline', 'offline', 'Research needs a connection.', false),
      ('identity_unavailable', 'identity', 'private connection', false),
      ('rate_limited', 'rate-limit', 'Research is busy right now.', true),
      ('request_in_flight', 'request-in-flight', 'already in progress', true),
      ('not_entitled', 'not-entitled', 'not included for this account', false),
      (
        'credits_exhausted',
        'credits-exhausted',
        'credits are unavailable',
        false,
      ),
      ('idempotency_conflict', 'conflict', 'cannot be retried', false),
      (
        'request_outcome_unknown',
        'outcome-unknown',
        'will not retry it',
        false,
      ),
      ('upstream_timeout', 'timeout', 'took too long to finish', false),
      (
        'invalid_broker_response',
        'invalid-response',
        'could not display a safe',
        false,
      ),
    ]) {
      await captureState(
        id: 'issue189-${entry.$1}',
        fileName: 'issue-189-${entry.$2}-light.png',
        flags: enabled,
        settledState: find.text('Research unavailable'),
        client: _ThrowingResearchClient(
          BrokerResearchFailureException.fromFailure(
            BrokerClientFailure(
              code: entry.$1,
              message: 'Test-safe fixed message.',
              retryable: entry.$4,
            ),
            requestId: '11111111-1111-4111-8111-111111111111',
          ),
        ),
        startResearch: true,
      );
      expect(find.textContaining(entry.$3), findsOneWidget);
      expect(find.text('Research unavailable'), findsOneWidget);
      switch (entry.$1) {
        case 'request_in_flight':
          expect(find.text('Retry same request'), findsOneWidget);
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Retry same request'),
                )
                .onPressed,
            isNotNull,
          );
        case 'offline':
        case 'identity_unavailable':
        case 'rate_limited':
        case 'upstream_timeout':
        case 'invalid_broker_response':
          expect(find.text('Try research again'), findsOneWidget);
        case 'not_entitled':
        case 'credits_exhausted':
          expect(find.text('Manage plan'), findsOneWidget);
          expect(find.text('Try research again'), findsNothing);
        case 'idempotency_conflict':
        case 'request_outcome_unknown':
          expect(find.text('Try research again'), findsNothing);
          expect(find.text('Retry same request'), findsNothing);
      }
    }
    await captureState(
      id: 'issue189-consent-stale',
      fileName: 'issue-189-consent-stale-light.png',
      flags: enabled,
      settledState: find.text('Research consent'),
      client: _ThrowingResearchClient(
        BrokerResearchFailureException.fromFailure(
          const BrokerClientFailure(
            code: 'consent_stale',
            message: 'Research consent must be refreshed.',
          ),
        ),
      ),
      startResearch: true,
    );
    expect(find.text('Research consent'), findsOneWidget);
    expect(find.text('Research unavailable'), findsNothing);
    await captureState(
      id: 'issue189-results',
      fileName: 'issue-189-cited-results-light.png',
      flags: enabled,
      settledState: find.text('Source-backed candidates'),
      client: FixtureProfessionalSourceResearchClient(),
      startResearch: true,
    );
    expect(find.text('Source-backed candidates'), findsOneWidget);
    expect(find.text('AI-suggested'), findsWidgets);
    await tester.pump(const Duration(milliseconds: 200));
    await captureState(
      id: 'issue189-dark-gated',
      fileName: 'issue-189-gated-unavailable-dark.png',
      flags: const AppFeatureFlags(),
      settledState: find.text('Research unavailable'),
      themeMode: ThemeMode.dark,
    );
    await captureState(
      id: 'issue189-dark-results',
      fileName: 'issue-189-cited-results-dark.png',
      flags: enabled,
      settledState: find.text('Source-backed candidates'),
      client: FixtureProfessionalSourceResearchClient(),
      startResearch: true,
      themeMode: ThemeMode.dark,
    );
    await captureState(
      id: 'issue189-dark-consent',
      fileName: 'issue-189-consent-dark.png',
      flags: enabled,
      settledState: find.text('Research consent'),
      client: FixtureProfessionalSourceResearchClient(),
      openConsent: true,
      themeMode: ThemeMode.dark,
    );
    await captureState(
      id: 'issue189-dark-loading',
      fileName: 'issue-189-loading-dark.png',
      flags: enabled,
      settledState: find.text('Researching...'),
      client: _PendingResearchClient(),
      startResearch: true,
      themeMode: ThemeMode.dark,
    );
    await captureState(
      id: 'issue189-dark-request-in-flight',
      fileName: 'issue-189-request-in-flight-dark.png',
      flags: enabled,
      settledState: find.text('Research unavailable'),
      client: _ThrowingResearchClient(
        BrokerResearchFailureException.fromFailure(
          const BrokerClientFailure(
            code: 'request_in_flight',
            message: 'A research request is already in progress.',
            retryable: true,
          ),
          requestId: '11111111-1111-4111-8111-111111111111',
        ),
      ),
      startResearch: true,
      themeMode: ThemeMode.dark,
    );
    await captureState(
      id: 'issue189-dark-conflict',
      fileName: 'issue-189-conflict-dark.png',
      flags: enabled,
      settledState: find.text('Research unavailable'),
      client: _ThrowingResearchClient(
        BrokerResearchFailureException.fromFailure(
          const BrokerClientFailure(
            code: 'idempotency_conflict',
            message: 'The request conflicts.',
          ),
        ),
      ),
      startResearch: true,
      themeMode: ThemeMode.dark,
    );
  });

  testWidgets(
    'same-request retry reuses the confirmed consent without recreating it',
    (WidgetTester tester) async {
      final fixture = await tester.runAsync(_LiveDependencyFixture.create);
      final testFixture = fixture!;
      final client = _RetrySequenceResearchClient();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(testFixture.dispose);
      });
      await tester.runAsync(
        () => testFixture.repository.upsert(
          _artworkRecord(
            id: 'issue189-retry-consent',
            title: 'Retry consent draft',
            state: ArtworkRecordState.needsReview,
          ),
        ),
      );
      await tester.pumpWidget(
        ArchivaleApp(
          initialRoute: AppRoutes.artworkDraft('issue189-retry-consent'),
          dependencies: testFixture.dependenciesWithFlags(
            featureFlags: const AppFeatureFlags(
              localResearchCapabilityEnabled: true,
            ),
            onlineResearchClient: client,
          ),
        ),
      );
      await pumpLiveData(tester);
      await tapVisible(tester, find.text('Research this draft'));
      await tapVisible(tester, find.text('Start source-backed research'));
      await pumpLiveData(tester);

      expect(find.text('Retry same request'), findsOneWidget);
      await tapVisible(tester, find.text('Retry same request'));
      await pumpLiveData(tester);

      expect(client.researchCalls, 1);
      expect(client.retryCalls, 1);
      expect(
        identical(
          client.initialRequest!.brokerConsent,
          client.retryRequest!.brokerConsent,
        ),
        isTrue,
      );
      expect(find.text('Source-backed candidates'), findsOneWidget);
    },
  );

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
      await tester.pumpWidget(
        ArchivaleApp(key: ValueKey(route), initialRoute: route),
      );
      await pumpReady(tester);

      expect(find.text('Settings'), findsWidgets);
      expect(find.text('Review privacy'), findsOneWidget);
      expect(find.text('Review storage'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Review backup'), 200);
      await tester.pump();
      expect(find.text('Review backup'), findsOneWidget);
      expect(find.text('Export entire collection'), findsOneWidget);
      expect(find.text('No artworks yet'), findsNothing);
    }
  });

  testWidgets('legacy per-artwork export route stays unavailable', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const ArchivaleApp(initialRoute: '/artwork/sample-001/export'),
    );
    await pumpReady(tester);

    expect(find.text('Route not found'), findsOneWidget);
    expect(find.text('Collection archive ZIP'), findsNothing);
    expect(find.text('Generate archive'), findsNothing);
  });

  testWidgets('settings home keeps trust hub heading copy', (
    WidgetTester tester,
  ) async {
    await _configureMobileViewport(tester);
    await tester.pumpWidget(
      ArchivaleApp(initialRoute: AppRoutes.collectionSettings),
    );
    await pumpReady(tester);

    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Privacy, storage, backup, and exports'), findsOneWidget);
    expect(
      find.text(
        'Choose how your records stay private, where they are kept, and when to save a second copy.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('settings trust routes keep collector-facing copy', (
    WidgetTester tester,
  ) async {
    final routeAssertions = <String, List<String>>{
      AppRoutes.settingsPrivacy: [
        'Privacy',
        'Private by default',
        'You confirm the facts',
        'Backup stays in your account',
      ],
      AppRoutes.settingsStorage: [
        'Storage',
        'Keep records close at hand',
        'One record, one place',
        'Delete local data with care',
      ],
      AppRoutes.settingsBackup: [
        'Backup',
        'Keep a second copy you control',
        'Not connected yet',
        'Disconnect backup',
      ],
    };

    const bannedTerms = [
      'Firebase',
      'backend',
      'local DB',
      'deploy',
      'Remote Config',
      'broker',
      'provider',
    ];

    for (final entry in routeAssertions.entries) {
      await tester.pumpWidget(ArchivaleApp(initialRoute: entry.key));
      await pumpReady(tester);
      expect(find.text(entry.value.first), findsOneWidget);
      expect(find.text(entry.value[1]), findsOneWidget);
      await tester.scrollUntilVisible(find.text(entry.value.last), 200);
      await tester.pump();
      for (final copy in entry.value.skip(2)) {
        expect(find.text(copy), findsOneWidget);
      }
      for (final bannedTerm in bannedTerms) {
        expect(find.textContaining(bannedTerm), findsNothing);
      }

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets('visual evidence covers issue 165 collection tab copy states', (
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
          id: 'issue-165-report-record',
          title: 'North Wall Landscape',
          state: ArtworkRecordState.verifiedByYou,
          source: ArtworkFieldSource.userConfirmed,
        ),
      );
      await fixture.addSupportingPhoto(
        artworkId: 'issue-165-report-record',
        fileName: 'issue-165-supporting-photo.png',
      );
      await fixture.repository.upsert(
        _artworkRecord(
          id: 'issue-165-review-record',
          title: 'Studio Portrait',
          state: ArtworkRecordState.needsReview,
        ),
      );
    });

    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collection,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-165-collection-light.png',
      ensureVisibleFinder: find.text('North Wall Landscape'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collectionIncomplete,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-165-needs-review-light.png',
      ensureVisibleFinder: find.text('Studio Portrait needs review'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collectionReport,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-165-reports-light.png',
      ensureVisibleFinder: find.text('Preview artwork report'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collectionSettings,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-165-settings-light.png',
      ensureVisibleFinder: find.text('Review privacy'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collection,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.dark,
      fileName: 'issue-165-collection-dark.png',
      ensureVisibleFinder: find.text('North Wall Landscape'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collectionIncomplete,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.dark,
      fileName: 'issue-165-needs-review-dark.png',
      ensureVisibleFinder: find.text('Studio Portrait needs review'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collectionReport,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.dark,
      fileName: 'issue-165-reports-dark.png',
      ensureVisibleFinder: find.text('Preview artwork report'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collectionSettings,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.dark,
      fileName: 'issue-165-settings-dark.png',
      ensureVisibleFinder: find.text('Review privacy'),
    );
  });

  testWidgets('visual evidence covers issue 169 artwork detail and edit copy', (
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
          id: 'issue-169-detail-record',
          title: 'Issue 169 Detail Record',
          state: ArtworkRecordState.needsReview,
          source: ArtworkFieldSource.userConfirmed,
          missingFieldKeys: {
            ArtworkFieldKeys.title,
            ArtworkFieldKeys.currentLocation,
            ArtworkFieldKeys.conditionNotes,
            ArtworkFieldKeys.insuranceValue,
          },
        ),
      );
      await fixture.addPrimaryImage(artworkId: 'issue-169-detail-record');
      await fixture.addSupportingPhoto(
        artworkId: 'issue-169-detail-record',
        fileName: 'issue-169-supporting-photo.png',
      );
      await fixture.repository.upsert(
        _placeholderDraftRecord(id: 'issue-169-edit-record'),
      );
      await fixture.addPrimaryImage(artworkId: 'issue-169-edit-record');
    });

    await tester.pumpWidget(
      ArchivaleApp(
        initialRoute: AppRoutes.artworkDetails('issue-169-detail-record'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);
    expect(find.text('Untitled artwork'), findsNothing);
    expect(find.text('Not set'), findsNothing);
    expect(find.text('Title pending review.'), findsWidgets);
    expect(find.text('Insurance value pending review.'), findsOneWidget);

    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkDetails('issue-169-detail-record'),
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-169-details-light.png',
      ensureVisibleFinder: find.text('Record review'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkDetails('issue-169-detail-record'),
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.dark,
      fileName: 'issue-169-details-dark.png',
      ensureVisibleFinder: find.text('Record review'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkEdit('issue-169-edit-record'),
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-169-edit-light.png',
      ensureVisibleFinder: find.text('Confirm the details you want to keep'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkEdit('issue-169-edit-record'),
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.dark,
      fileName: 'issue-169-edit-dark.png',
      ensureVisibleFinder: find.text('Confirm the details you want to keep'),
    );
  });

  testWidgets('visual evidence covers issue 171 report export routes', (
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
          id: 'issue-131-report-record',
          title: 'Issue 131 Local Record',
          state: ArtworkRecordState.verifiedByYou,
          source: ArtworkFieldSource.userConfirmed,
        ),
      );
      await fixture.addPrimaryImage(artworkId: 'issue-131-report-record');
      await fixture.addSupportingPhoto(
        artworkId: 'issue-131-report-record',
        fileName: 'issue-131-receipt.png',
      );
    });

    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collectionReport,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-171-reports-light.png',
      ensureVisibleFinder: find.text('Issue 131 Local Record'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkReportPreview('issue-131-report-record'),
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-171-report-preview-light.png',
      ensureVisibleFinder: find.text('What the report includes'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.settingsExport,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-171-settings-export-light.png',
      ensureVisibleFinder: find.text('Export your entire collection'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collectionReport,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.dark,
      fileName: 'issue-171-reports-dark.png',
      ensureVisibleFinder: find.text('Issue 131 Local Record'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.artworkReportPreview('issue-131-report-record'),
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.dark,
      fileName: 'issue-171-report-preview-dark.png',
      ensureVisibleFinder: find.text('What the report includes'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.settingsExport,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.dark,
      fileName: 'issue-171-settings-export-dark.png',
      ensureVisibleFinder: find.text('Export your entire collection'),
    );
  });

  testWidgets('visual evidence covers issue 178 real export actions', (
    WidgetTester tester,
  ) async {
    final fixture = (await tester.runAsync(_LiveDependencyFixture.create))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.dispose);
    });
    await tester.runAsync(() async {
      await fixture.repository.create(
        _artworkRecord(
          id: 'issue-178-export-record',
          title: 'Private Export Record',
          state: ArtworkRecordState.verifiedByYou,
          source: ArtworkFieldSource.userConfirmed,
        ),
      );
    });
    for (final themeMode in [ThemeMode.light, ThemeMode.dark]) {
      final themeName = themeMode == ThemeMode.light ? 'light' : 'dark';
      await captureArtifactForApp(
        tester,
        routeName: AppRoutes.artworkReportPreview('issue-178-export-record'),
        dependencies: fixture.dependencies,
        themeMode: themeMode,
        fileName: 'issue-178-report-actions-$themeName.png',
        ensureVisibleFinder: find.text('Collector report PDF'),
      );
      await captureArtifactForApp(
        tester,
        routeName: AppRoutes.settingsExport,
        dependencies: fixture.dependencies,
        themeMode: themeMode,
        fileName: 'issue-178-archive-actions-$themeName.png',
        ensureVisibleFinder: find.text('Collection archive ZIP'),
      );
    }
  });

  testWidgets('visual evidence covers issue 172 settings trust routes', (
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
      routeName: AppRoutes.collectionSettings,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-172-settings-home-light.png',
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.settingsPrivacy,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-172-settings-privacy-light.png',
      ensureVisibleFinder: find.text('You confirm the facts'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.settingsStorage,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-172-settings-storage-light.png',
      ensureVisibleFinder: find.text('One record, one place'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.settingsBackup,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.light,
      fileName: 'issue-172-settings-backup-light.png',
      ensureVisibleFinder: find.text('Not connected yet'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.collectionSettings,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.dark,
      fileName: 'issue-172-settings-home-dark.png',
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.settingsPrivacy,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.dark,
      fileName: 'issue-172-settings-privacy-dark.png',
      ensureVisibleFinder: find.text('You confirm the facts'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.settingsStorage,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.dark,
      fileName: 'issue-172-settings-storage-dark.png',
      ensureVisibleFinder: find.text('One record, one place'),
    );
    await captureArtifactForApp(
      tester,
      routeName: AppRoutes.settingsBackup,
      dependencies: fixture.dependencies,
      themeMode: ThemeMode.dark,
      fileName: 'issue-172-settings-backup-dark.png',
      ensureVisibleFinder: find.text('Not connected yet'),
    );
  });
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await pumpLiveData(tester);
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
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
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

Future<void> chooseArtworkPhotoForTest(WidgetTester tester) async {
  final finder = find.widgetWithText(FilledButton, 'Choose artwork photo');
  await waitForFinder(tester, finder, attempts: 80);
  await tester.runAsync(() async {
    final button = tester.widget<FilledButton>(finder);
    button.onPressed!();
    await Future<void>.delayed(const Duration(seconds: 1));
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

Future<void> _captureIssue211CollectionVisualEvidence(
  WidgetTester tester, {
  required ThemeMode themeMode,
  required _Issue211CollectionVisualState state,
  required String fileName,
}) async {
  await _configureMobileViewport(tester);
  final fixture = await tester.runAsync(_LiveDependencyFixture.create);
  final liveFixture = fixture!;
  try {
    if (state != _Issue211CollectionVisualState.trueEmpty) {
      await tester.runAsync(() async {
        await liveFixture.repository.createAll([
          _collectionQueryRecord(
            id: 'visual-harbor',
            title: 'Harbor Study',
            artist: 'Ingrid Vale',
            notes: 'Framed after the Oslo studio visit.',
            location: 'Main Hall',
            state: ArtworkRecordState.missingDocuments,
          ),
          _collectionQueryRecord(
            id: 'visual-blue',
            title: 'Blue Interior',
            artist: 'A. Maker',
            notes: 'Collector note for the archive.',
            location: 'Archive',
            state: ArtworkRecordState.verifiedByYou,
          ),
        ]);
      });
    }

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: ArchivaleApp(
          initialRoute: AppRoutes.collection,
          themeMode: themeMode,
          dependencies: liveFixture.dependencies,
        ),
      ),
    );
    await pumpLiveData(tester);

    if (state == _Issue211CollectionVisualState.composed ||
        state == _Issue211CollectionVisualState.noResults) {
      await enterVisibleText(
        tester,
        find.byKey(const ValueKey('collection-search-field')),
        state == _Issue211CollectionVisualState.noResults
            ? 'No matching collector text'
            : 'Harbor',
      );
      await pumpLiveData(tester);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('collection-filter-toggle')),
      );
      await tapVisible(tester, find.widgetWithText(FilterChip, 'Main Hall'));
      if (state == _Issue211CollectionVisualState.composed) {
        await tapVisible(
          tester,
          find.byKey(const ValueKey('missing-supporting-filter')),
        );
      }
      await tapVisible(
        tester,
        find.byKey(const ValueKey('collection-filter-toggle')),
      );
      await tester.drag(find.byType(ListView).first, const Offset(0, 2000));
      await tester.pump();
    }

    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    boundary.markNeedsPaint();
    await tester.pump();
    final bytes = await tester.runAsync<Uint8List>(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return byteData!.buffer.asUint8List();
    });
    final outputDirectory = Directory(p.join('artifacts', 'visual'));
    outputDirectory.createSync(recursive: true);
    File(p.join(outputDirectory.path, fileName)).writeAsBytesSync(bytes!);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(liveFixture.dispose);
  }
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
  await pumpLiveData(tester);

  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync<Uint8List>(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData!.buffer.asUint8List();
  });

  final outputDirectory = Directory(
    p.join('.dart_tool', 'issue132_visual_evidence'),
  );
  outputDirectory.createSync(recursive: true);
  final screenshotFile = File(p.join(outputDirectory.path, fileName));
  screenshotFile.writeAsBytesSync(bytes!);

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

Future<void> _captureIssue193BillingState(
  WidgetTester tester,
  EntitlementState state,
  String fileName, {
  bool showDisabledPurchaseChoice = false,
  bool showVerifyingFlow = false,
}) async {
  final fixture = await tester.runAsync(_LiveDependencyFixture.create);
  final testFixture = fixture!;
  addTearDown(() async => tester.runAsync(testFixture.dispose));
  final billing = _FakeBillingManagementService(
    productsValue: const [
      PlayProduct(
        id: 'archivale_starter_monthly',
        title: 'Starter monthly',
        description: 'Up to 50 active artworks',
        price: 'NOK 35.00',
      ),
    ],
  )..state = state;
  final boundaryKey = GlobalKey();
  await _configureMobileViewport(tester);
  Widget buildBillingApp() => RepaintBoundary(
    key: boundaryKey,
    child: ArchivaleApp(
      key: ValueKey('issue-193-$fileName'),
      initialRoute: AppRoutes.billing,
      dependencies: testFixture.dependenciesWithFlags(
        entitlementService: billing,
        billingManagementService: billing,
      ),
    ),
  );
  await tester.pumpWidget(buildBillingApp());
  await pumpLiveData(tester);
  await tester.pumpWidget(buildBillingApp());
  await tester.pumpAndSettle();
  final billingScrollable = find.descendant(
    of: find.byKey(const ValueKey('billing-plan-scrollable')),
    matching: find.byType(Scrollable),
  );
  expect(billingScrollable, findsOneWidget);
  if (showVerifyingFlow) {
    final purchaseChoice = find.widgetWithText(FilledButton, 'Choose plan');
    await tester.scrollUntilVisible(purchaseChoice, 300);
    await tester.tap(purchaseChoice);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Verifying subscription'), findsOneWidget);
  }
  final position = tester.state<ScrollableState>(billingScrollable).position;
  position.jumpTo(0);
  await tester.pump();
  position.jumpTo(1);
  await tester.pump();
  position.jumpTo(0);
  await tester.pumpAndSettle();
  expect(position.pixels, 0);
  expect(find.text('Plan and billing'), findsOneWidget);
  expect(find.text('Free plan'), findsOneWidget);
  if (showDisabledPurchaseChoice) {
    expect(find.text('Purchase pending'), findsOneWidget);
    final purchaseChoice = find.widgetWithText(FilledButton, 'Choose plan');
    await tester.scrollUntilVisible(purchaseChoice, 300);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(purchaseChoice).onPressed, isNull);
    expect(tester.getRect(purchaseChoice).bottom, lessThanOrEqualTo(852));
  }
  await captureBoundaryToArtifacts(tester, boundaryKey, fileName);
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
  double revealTopPadding = 0,
  double? minimumTopClearance,
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
    await waitForFinder(tester, ensureVisibleFinder);
    await tester.ensureVisible(ensureVisibleFinder.first);
    await tester.pump();
    if (revealTopPadding > 0) {
      final scrollable = find
          .ancestor(of: ensureVisibleFinder, matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(
        (position.pixels - revealTopPadding).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      await tester.pump();
    }
    if (minimumTopClearance != null) {
      final appBarBottom = tester.getBottomLeft(find.byType(AppBar).first).dy;
      final targetTop = tester.getTopLeft(ensureVisibleFinder).dy;
      expect(
        targetTop,
        greaterThanOrEqualTo(appBarBottom + minimumTopClearance),
        reason: 'Captured target must be fully framed below the app bar.',
      );
    }
  }
  await captureBoundaryToArtifacts(tester, boundaryKey, fileName);
}

Future<void> captureCollectionLimitVisualEvidence(
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
        initialRoute: AppRoutes.collection,
        dependencies: dependencies,
        themeMode: ThemeMode.light,
      ),
    ),
  );
  await pumpLiveData(tester);
  await tester.dragUntilVisible(
    find.text('Free plan is at capacity'),
    find.byType(ListView).first,
    const Offset(0, -300),
  );
  await tester.pump();
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
  final primaryFinder = find.widgetWithText(FilledButton, actionLabel);
  final outlinedFinder = find.widgetWithText(OutlinedButton, actionLabel);
  final finder = tester.any(primaryFinder)
      ? primaryFinder
      : tester.any(outlinedFinder)
      ? outlinedFinder
      : find.text(actionLabel);
  await tapVisible(tester, finder);
  await pumpLiveData(tester);
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
    find.widgetWithText(FilledButton, 'Choose a supporting photo'),
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
  await tapVisible(tester, find.text('Save confirmed details'));
  await pumpLiveData(tester);
  await tester.runAsync(
    () async => Future<void>.delayed(const Duration(milliseconds: 500)),
  );
  await tester.pump();
  await waitForFinder(tester, find.text('Draft review'), attempts: 60);
  await tester.ensureVisible(find.text('Draft review'));
  await tester.pump();

  await captureBoundaryToArtifacts(tester, boundaryKey, fileName);
}

Future<void> captureCsvImportPreviewVisualEvidence(
  WidgetTester tester, {
  required AppDependencies dependencies,
  required String csvPath,
  required String fileName,
  Finder? ensureVisibleFinder,
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
    find.widgetWithText(OutlinedButton, 'Load from path'),
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
  await tester.ensureVisible(ensureVisibleFinder ?? find.text('Start over'));
  await tester.pump();

  await captureBoundaryToArtifacts(tester, boundaryKey, fileName);
}

Future<void> captureCsvImportMappingVisualEvidence(
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
    find.widgetWithText(OutlinedButton, 'Load from path'),
  );
  await waitForFinder(
    tester,
    find.byKey(const ValueKey('csv-mapping-Work Name')),
  );
  await tester.ensureVisible(find.text('Match each column'));
  await tester.pump();

  await captureBoundaryToArtifacts(tester, boundaryKey, fileName);
}

Future<void> captureCsvImportCancelVisualEvidence(
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
    find.widgetWithText(OutlinedButton, 'Load from path'),
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
  await tapVisible(tester, find.text('Start over'));
  await waitForFinder(tester, find.text('Choose spreadsheet'));
  await tester.ensureVisible(find.text('Choose spreadsheet'));
  await tester.pump();

  await captureBoundaryToArtifacts(tester, boundaryKey, fileName);
}

Future<void> captureCsvImportSuccessVisualEvidence(
  WidgetTester tester, {
  required AppDependencies dependencies,
  required String successFileName,
  String? importedDraftFileName,
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
    find.widgetWithText(FilledButton, 'Choose spreadsheet'),
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
  await tapVisible(tester, find.text('Add anyway'));
  await pressAsyncButton(
    tester,
    find.widgetWithText(FilledButton, 'Add to collection'),
  );
  await waitForFinder(tester, find.text('Open first record'));
  await tester.ensureVisible(find.text('Open first record'));
  await tester.pump();

  await captureBoundaryToArtifacts(
    tester,
    boundaryKey,
    successFileName,
    resetAfterCapture: importedDraftFileName == null,
  );
  if (importedDraftFileName != null) {
    await tapVisible(tester, find.text('Open first record'));
    await pumpLiveData(tester);
    await waitForFinder(tester, find.text('Add evidence photos next'));
    await tester.ensureVisible(find.text('Primary image preview unavailable'));
    await tester.pump();
    await captureBoundaryToArtifacts(
      tester,
      boundaryKey,
      importedDraftFileName,
    );
  }
}

Future<void> captureBoundaryToArtifacts(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String fileName, {
  bool resetAfterCapture = true,
}) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await captureRenderedBoundaryToArtifacts(tester, boundary, fileName);

  if (resetAfterCapture) {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }
}

Future<void> captureRenderedBoundaryToArtifacts(
  WidgetTester tester,
  RenderRepaintBoundary boundary,
  String fileName,
) async {
  boundary.markNeedsPaint();
  await tester.pump();
  final bytes = await tester.runAsync<Uint8List>(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return byteData!.buffer.asUint8List();
  });

  final outputDirectory = Directory(p.join('artifacts', 'visual'));
  outputDirectory.createSync(recursive: true);
  final screenshotFile = File(p.join(outputDirectory.path, fileName));
  screenshotFile.parent.createSync(recursive: true);
  screenshotFile.writeAsBytesSync(bytes!);
}

Future<void> warmBoundaryRaster(
  WidgetTester tester,
  GlobalKey boundaryKey,
) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    image.dispose();
  });
}

Future<void> _captureIssue136OnDeviceAiImportState(
  WidgetTester tester, {
  required OnDeviceAiDraftProvider provider,
  required String expectedTitle,
  required String fileName,
}) async {
  final fixture = await tester.runAsync(
    () async =>
        _LiveDependencyFixture.create(onDeviceAiDraftProvider: provider),
  );
  expect(fixture, isNotNull);
  final liveFixture = fixture!;
  addTearDown(() async => tester.runAsync(liveFixture.dispose));

  final sourceImage = await tester.runAsync(
    () => liveFixture.writePngSource(p.basename(fileName)),
  );

  await _configureMobileViewport(tester);

  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: ArchivaleApp(
        initialRoute: AppRoutes.import,
        dependencies: liveFixture.dependenciesWithPicker(
          _SingleImagePicker(sourceImage!),
        ),
      ),
    ),
  );
  await pumpLiveData(tester);

  await chooseArtworkPhotoForTest(tester);
  await waitForFinder(tester, find.text(expectedTitle));

  await captureBoundaryToArtifacts(tester, boundaryKey, fileName);
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
    SupportingDocumentPicker? supportingDocumentPicker,
    AttachmentViewerGateway? attachmentViewer,
    CsvImportFilePicker csvImportFilePicker = const _NoCsvPicker(),
    AppFeatureFlags featureFlags = const AppFeatureFlags(),
    EntitlementService entitlementService = const StaticEntitlementService(),
    BillingManagementService? billingManagementService,
    OnlineResearchClient? onlineResearchClient,
  }) {
    return AppDependencies(
      artworkRepository: repository,
      attachmentStore: attachmentStore,
      imagePicker: imagePicker ?? _NoLostImagePicker(),
      supportingDocumentPicker:
          supportingDocumentPicker ?? const _NoSupportingDocumentPicker(),
      attachmentViewer: attachmentViewer ?? const _NoAttachmentViewer(),
      csvImportFilePicker: csvImportFilePicker,
      featureFlags: featureFlags,
      entitlementService: entitlementService,
      billingManagementService: billingManagementService,
      onDeviceAiDraftProvider: onDeviceAiDraftProvider,
      onlineResearchClient:
          onlineResearchClient ??
          (featureFlags.localResearchCapabilityEnabled
              ? FixtureProfessionalSourceResearchClient()
              : null),
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

  Future<File> writePdfSource(String fileName) async {
    final file = File(p.join(tempDir.path, fileName));
    await file.writeAsBytes(_tinyPdfBytes);
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

class _PendingImagePicker implements ArtworkImagePicker {
  final Map<ArtworkImagePickMode, Completer<XFile?>> _completers = {
    ArtworkImagePickMode.gallery: Completer<XFile?>(),
    ArtworkImagePickMode.camera: Completer<XFile?>(),
  };

  @override
  Future<XFile?> pick(ArtworkImagePickMode mode) {
    return _completers[mode]!.future;
  }

  void complete(ArtworkImagePickMode mode, XFile? file) {
    final completer = _completers[mode]!;
    if (!completer.isCompleted) {
      completer.complete(file);
    }
  }

  @override
  Future<XFile?> retrieveLostImage() async => null;
}

class _FakeBillingManagementService implements BillingManagementService {
  _FakeBillingManagementService({this.productsValue = const []});

  EntitlementState state = const EntitlementState(
    plan: EntitlementPlans.free,
    billingStatus: EntitlementBillingStatus.available,
  );
  List<PlayProduct> productsValue;
  final StreamController<EntitlementState> _stateChanges =
      StreamController<EntitlementState>.broadcast();

  @override
  Stream<EntitlementState> get stateChanges => _stateChanges.stream;

  @override
  Future<bool> canRecover() async => true;

  void publish(EntitlementState next) {
    state = next;
    _stateChanges.add(next);
  }

  @override
  Future<bool> acceptBillingDisclosure() async => true;

  @override
  Future<EntitlementState> currentState() async => state;

  @override
  void handleAccountChange() {
    state = const EntitlementState(plan: EntitlementPlans.free);
  }

  @override
  Future<bool> purchase(EntitlementPlan plan) async => true;

  @override
  Future<List<PlayProduct>> products() async => productsValue;

  @override
  Future<void> refreshForForeground() async {}

  @override
  Future<void> restore() async {}
}

class _NoCsvPicker implements CsvImportFilePicker {
  const _NoCsvPicker();

  @override
  Future<CsvImportFileSelection?> pickCsvFile() async => null;
}

class _SingleDocumentPicker implements SupportingDocumentPicker {
  const _SingleDocumentPicker(this.file);

  final File file;

  @override
  Future<XFile?> pickDocument() async {
    return XFile(
      file.path,
      name: p.basename(file.path),
      mimeType: 'application/pdf',
    );
  }
}

class _QueuedDocumentPicker implements SupportingDocumentPicker {
  _QueuedDocumentPicker(this._responses);

  final List<Object> _responses;

  @override
  Future<XFile?> pickDocument() async {
    if (_responses.isEmpty) {
      return null;
    }
    final response = _responses.removeAt(0);
    if (response is Exception) {
      throw response;
    }
    final file = response as File;
    return XFile(
      file.path,
      name: p.basename(file.path),
      mimeType: 'application/pdf',
    );
  }
}

class _NoSupportingDocumentPicker implements SupportingDocumentPicker {
  const _NoSupportingDocumentPicker();

  @override
  Future<XFile?> pickDocument() async => null;
}

class _RecordingAttachmentViewer implements AttachmentViewerGateway {
  final openedUris = <Uri>[];

  @override
  Future<void> open({required Uri scopedUri, required String mimeType}) async {
    openedUris.add(scopedUri);
  }
}

class _NoAttachmentViewer implements AttachmentViewerGateway {
  const _NoAttachmentViewer();

  @override
  Future<void> open({required Uri scopedUri, required String mimeType}) async {}
}

final _tinyPdfBytes = _validPdfBytes();

List<int> _validPdfBytes() {
  const header = '%PDF-1.4\n';
  const catalog = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n';
  const pages = '2 0 obj\n<< /Type /Pages /Count 0 /Kids [] >>\nendobj\n';
  final catalogOffset = header.length;
  final pagesOffset = catalogOffset + catalog.length;
  final xrefOffset = pagesOffset + pages.length;
  final source = StringBuffer(header)
    ..write(catalog)
    ..write(pages)
    ..write('xref\n0 3\n')
    ..write('0000000000 65535 f \n')
    ..write('${catalogOffset.toString().padLeft(10, '0')} 00000 n \n')
    ..write('${pagesOffset.toString().padLeft(10, '0')} 00000 n \n')
    ..write('trailer\n<< /Size 3 /Root 1 0 R >>\n')
    ..write('startxref\n$xrefOffset\n%%EOF\n');
  return latin1.encode(source.toString());
}

class _ThrowingResearchClient implements OnlineResearchClient {
  _ThrowingResearchClient(this._error);

  final Object _error;

  @override
  Future<ResearchJob> research(OnlineResearchRequest request) async {
    throw _error;
  }
}

class _PendingResearchClient implements OnlineResearchClient {
  @override
  Future<ResearchJob> research(OnlineResearchRequest request) =>
      Completer<ResearchJob>().future;
}

class _RetrySequenceResearchClient implements RetryableOnlineResearchClient {
  int researchCalls = 0;
  int retryCalls = 0;
  OnlineResearchRequest? initialRequest;
  OnlineResearchRequest? retryRequest;

  @override
  Future<ResearchJob> research(OnlineResearchRequest request) async {
    researchCalls += 1;
    initialRequest = request;
    throw BrokerResearchFailureException.fromFailure(
      const BrokerClientFailure(
        code: 'request_in_flight',
        message: 'A research request is already in progress.',
        retryable: true,
      ),
      requestId: '11111111-1111-4111-8111-111111111111',
    );
  }

  @override
  Future<ResearchJob> retry(
    OnlineResearchRequest request,
    String requestId,
  ) async {
    retryCalls += 1;
    retryRequest = request;
    return _researchJob(artworkId: request.artworkId);
  }

  @override
  Future<void> cancel(String requestId) async {}
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
  Future<OnDeviceAiCapability> downloadModel() async {
    return checkAvailability();
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

class _StaticCapabilityAiDraftProvider implements OnDeviceAiDraftProvider {
  const _StaticCapabilityAiDraftProvider({required this.capability});

  final OnDeviceAiCapability capability;

  @override
  Future<OnDeviceAiCapability> checkAvailability() async => capability;

  @override
  Future<OnDeviceAiCapability> downloadModel() async => capability;

  @override
  Future<OnDeviceAiDraftResult> createDraft(
    OnDeviceAiDraftRequest request,
  ) async {
    throw StateError(
      'createDraft must not run when status is ${capability.availability}',
    );
  }
}

enum _DownloadFlowPhase { downloadable, downloading, available, failed }

class _DownloadFlowAiDraftProvider implements OnDeviceAiDraftProvider {
  _DownloadFlowAiDraftProvider();

  _DownloadFlowPhase _phase = _DownloadFlowPhase.downloadable;
  int createDraftCount = 0;

  @override
  Future<OnDeviceAiCapability> checkAvailability() async {
    if (_phase == _DownloadFlowPhase.downloading) {
      _phase = _DownloadFlowPhase.available;
    }

    return switch (_phase) {
      _DownloadFlowPhase.downloadable => const OnDeviceAiCapability(
        availability: OnDeviceAiAvailability.downloadable,
        deviceModel: 'Pixel test device',
        message: 'Gemini Nano support is downloadable but not ready yet.',
      ),
      _DownloadFlowPhase.downloading => const OnDeviceAiCapability(
        availability: OnDeviceAiAvailability.downloading,
        deviceModel: 'Pixel test device',
        message:
            'Gemini Nano support is still downloading. Try again after it finishes.',
      ),
      _DownloadFlowPhase.available => const OnDeviceAiCapability(
        availability: OnDeviceAiAvailability.available,
        deviceModel: 'Pixel test device',
      ),
      _DownloadFlowPhase.failed => const OnDeviceAiCapability(
        availability: OnDeviceAiAvailability.downloadFailed,
        deviceModel: 'Pixel test device',
        message:
            'On-device AI download could not finish yet. Try again after checking AICore.',
      ),
    };
  }

  @override
  Future<OnDeviceAiCapability> downloadModel() async {
    _phase = _DownloadFlowPhase.downloading;
    return const OnDeviceAiCapability(
      availability: OnDeviceAiAvailability.downloading,
      deviceModel: 'Pixel test device',
      message:
          'Gemini Nano support is still downloading. Try again after it finishes.',
    );
  }

  @override
  Future<OnDeviceAiDraftResult> createDraft(
    OnDeviceAiDraftRequest request,
  ) async {
    createDraftCount += 1;
    expect(_phase, _DownloadFlowPhase.available);
    return const OnDeviceAiDraftResult(
      visualSummary: 'Visible lower-right signature on a framed artwork.',
      signatureNotes: 'May read E. Test.',
      mediumHint: 'Print or lithograph on paper',
      searchTerms: ['E. Test framed artwork'],
    );
  }
}

class _DownloadFailureAiDraftProvider implements OnDeviceAiDraftProvider {
  _DownloadFailureAiDraftProvider();

  _DownloadFlowPhase _phase = _DownloadFlowPhase.downloadable;

  @override
  Future<OnDeviceAiCapability> checkAvailability() async {
    return switch (_phase) {
      _DownloadFlowPhase.downloadable => const OnDeviceAiCapability(
        availability: OnDeviceAiAvailability.downloadable,
        deviceModel: 'Pixel test device',
        message: 'Gemini Nano support is downloadable but not ready yet.',
      ),
      _DownloadFlowPhase.failed => const OnDeviceAiCapability(
        availability: OnDeviceAiAvailability.downloadFailed,
        deviceModel: 'Pixel test device',
        message:
            'On-device AI download could not finish yet. Try again after checking AICore.',
      ),
      _ => const OnDeviceAiCapability(
        availability: OnDeviceAiAvailability.unavailable,
        deviceModel: 'Pixel test device',
      ),
    };
  }

  @override
  Future<OnDeviceAiCapability> downloadModel() async {
    _phase = _DownloadFlowPhase.failed;
    return const OnDeviceAiCapability(
      availability: OnDeviceAiAvailability.downloadFailed,
      deviceModel: 'Pixel test device',
      message:
          'On-device AI download could not finish yet. Try again after checking AICore.',
    );
  }

  @override
  Future<OnDeviceAiDraftResult> createDraft(
    OnDeviceAiDraftRequest request,
  ) async {
    throw StateError('createDraft must not run after a failed download');
  }
}

ArtworkRecord _collectionQueryRecord({
  required String id,
  required String title,
  required String artist,
  required String notes,
  required String location,
  required ArtworkRecordState state,
  ArtworkLifecycleStatus lifecycleStatus = ArtworkLifecycleStatus.active,
}) {
  final now = DateTime.utc(2026, 7, 4, 12);
  return ArtworkRecord(
    id: id,
    recordState: state,
    lifecycleStatus: lifecycleStatus,
    createdAt: now,
    updatedAt: now,
    fields: {
      for (final entry in {
        ArtworkFieldKeys.title: title,
        ArtworkFieldKeys.artist: artist,
        ArtworkFieldKeys.notes: notes,
        ArtworkFieldKeys.currentLocation: location,
      }.entries)
        entry.key: ArtworkFieldValue(
          value: entry.value,
          source: ArtworkFieldSource.userConfirmed,
          note: 'User-entered collection query fixture.',
        ),
    },
  );
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
      ...overrides,
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
  String fileName = 'primary.png',
}) {
  return AttachmentRecord(
    id: id,
    artworkId: artworkId,
    type: AttachmentType.photo,
    fileName: fileName,
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
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAACXBIWXMAAAABAAAAAQBPJcTWAAAADklEQVR4nGNkAAMWCAUAADgABkRoBWYAAAAASUVORK5CYII=',
);
