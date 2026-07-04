import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:my_art_collection/app/ai/on_device_ai_draft_service.dart';
import 'package:my_art_collection/app/app.dart';
import 'package:my_art_collection/app/app_dependencies.dart';
import 'package:my_art_collection/app/app_routes.dart';
import 'package:my_art_collection/app/config/app_feature_flags.dart';
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
        MyArtCollectionApp(
          initialRoute: AppRoutes.collection,
          locale: entry.key,
        ),
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
    expect(find.text('Evidence photo checklist'), findsOneWidget);
    expect(find.textContaining('prints or lithographs'), findsOneWidget);
    expect(find.textContaining('Receipts, certificates'), findsOneWidget);
    expect(find.text('Choose from system picker'), findsOneWidget);
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
      MyArtCollectionApp(
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
      MyArtCollectionApp(
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
      MyArtCollectionApp(
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

    expect(find.text('Verified by you'), findsWidgets);
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
      MyArtCollectionApp(
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
      MyArtCollectionApp(
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
      MyArtCollectionApp(
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
        MyArtCollectionApp(
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

      await tapVisible(tester, find.text('Sold'));
      await pumpLiveData(tester);
      expect(
        find.text('This artwork is retained in your records but marked sold.'),
        findsOneWidget,
      );

      ArtworkRecord? saved = await tester.runAsync<ArtworkRecord?>(
        () => fixture.repository.get('lifecycle-ui'),
      );
      expect(saved?.lifecycleStatus, ArtworkLifecycleStatus.sold);

      await tapVisible(tester, find.text('Lost'));
      await pumpLiveData(tester);
      saved = await tester.runAsync<ArtworkRecord?>(
        () => fixture.repository.get('lifecycle-ui'),
      );
      expect(saved?.lifecycleStatus, ArtworkLifecycleStatus.lost);

      await tapVisible(tester, find.text('Stolen'));
      await pumpLiveData(tester);
      saved = await tester.runAsync<ArtworkRecord?>(
        () => fixture.repository.get('lifecycle-ui'),
      );
      expect(saved?.lifecycleStatus, ArtworkLifecycleStatus.stolen);

      await tapVisible(tester, find.text('Removed'));
      expect(find.text('Remove from current holdings?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await pumpReady(tester);
      saved = await tester.runAsync<ArtworkRecord?>(
        () => fixture.repository.get('lifecycle-ui'),
      );
      expect(saved?.lifecycleStatus, ArtworkLifecycleStatus.stolen);

      await tapVisible(tester, find.text('Removed'));
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
        MyArtCollectionApp(
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
      MyArtCollectionApp(
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
      find.text('Sold Incomplete Artwork needs supporting documents'),
      findsNothing,
    );
    expect(find.textContaining('Removed Incomplete Artwork'), findsNothing);
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
      MyArtCollectionApp(
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
      MyArtCollectionApp(
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
      find.text('8 of 8 core fields are user-confirmed or reviewed.'),
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
      MyArtCollectionApp(
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
      MyArtCollectionApp(
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
      MyArtCollectionApp(
        initialRoute: AppRoutes.artworkDraft('no-comparable-draft'),
        dependencies: fixture.dependencies,
      ),
    );
    await pumpLiveData(tester);

    expect(find.text('No source-backed match yet'), findsOneWidget);
    await tester.ensureVisible(find.text('Comparable source signals'));
    await tester.pump();

    expect(find.text('Comparable source signals'), findsOneWidget);
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
      MyArtCollectionApp(
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
      MyArtCollectionApp(
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
    AppFeatureFlags featureFlags = const AppFeatureFlags(),
  }) {
    return AppDependencies(
      artworkRepository: repository,
      attachmentStore: attachmentStore,
      imagePicker: imagePicker ?? _NoLostImagePicker(),
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

final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
);
