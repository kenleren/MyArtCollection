import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:my_art_collection/app/app.dart';
import 'package:my_art_collection/app/app_dependencies.dart';
import 'package:my_art_collection/app/app_routes.dart';
import 'package:my_art_collection/app/external_references/external_reference_launch_gateway.dart';
import 'package:my_art_collection/app/intake/artwork_image_picker.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/external_reference.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:my_art_collection/app/storage/local_attachment_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await _loadScreenshotFont();
  });

  testWidgets(
    'Documents route adds, validates, edits, deduplicates and deletes',
    (tester) async {
      final fixture = (await tester.runAsync(_UiFixture.create))!;
      addTearDown(() async => tester.runAsync(fixture.dispose));
      final boundaryKey = await _pumpDocuments(tester, fixture);

      expect(find.text('No external references yet.'), findsOneWidget);
      expect(
        find.text(
          'External references support context for this record. They do not prove authenticity, attribution, provenance, ownership, value, appraisal, or insurance approval.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Opens in your browser or another app.'),
        findsOneWidget,
      );
      await _capture(tester, boundaryKey, 'issue-213-empty-android.png');

      final addButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Add external reference'),
      );
      addButton.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _pumpLiveData(tester);
      expect(find.text('Add external reference'), findsWidgets);

      await tester.enterText(
        find.byKey(const ValueKey('external-reference-url-field')),
        'http://example.com/object',
      );
      var announcements = 0;
      tester.binding.defaultBinaryMessenger.setMockMessageHandler(
        SystemChannels.accessibility.name,
        (message) async {
          if (_isAnnouncement(message)) announcements++;
          return null;
        },
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await _pumpLiveData(tester);
      expect(find.text('Use a complete https:// address.'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('external-reference-url-field')),
            )
            .focusNode!
            .hasFocus,
        isTrue,
      );
      expect(announcements, 1);
      await _capture(tester, boundaryKey, 'issue-213-invalid-url-android.png');

      await tester.enterText(
        find.byKey(const ValueKey('external-reference-url-field')),
        'HTTPS://Gallery.Example:443/object',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await _pumpLiveData(tester);
      await _scrollToPanel(tester);
      expect(find.text('gallery.example'), findsOneWidget);
      expect(addButton.focusNode!.hasFocus, isTrue);
      await _capture(tester, boundaryKey, 'issue-213-added-android.png');

      await tester.tap(find.byTooltip('Edit external reference'));
      await _pumpLiveData(tester);
      await _capture(tester, boundaryKey, 'issue-213-edit-modal-android.png');
      final labelField = find.widgetWithText(TextField, 'Label (optional)');
      await tester.enterText(labelField, 'Collector label');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await _pumpLiveData(tester);
      await _waitForFinder(tester, _iconButton('Edit external reference'));
      expect(
        tester
            .widget<IconButton>(_iconButton('Edit external reference'))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      await _scrollToPanel(tester);
      expect(find.text('Collector label'), findsOneWidget);

      await tester.tap(
        find.widgetWithText(FilledButton, 'Add external reference'),
      );
      await _pumpLiveData(tester);
      await tester.enterText(
        find.byKey(const ValueKey('external-reference-url-field')),
        'https://gallery.example/object',
      );
      announcements = 0;
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await _pumpLiveData(tester);
      expect(
        find.text('This reference is already saved for the artwork.'),
        findsOneWidget,
      );
      expect(announcements, 1);
      await _capture(tester, boundaryKey, 'issue-213-duplicate-android.png');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _pumpLiveData(tester);
      await _scrollToPanel(tester);

      await tester.tap(find.byTooltip('Delete external reference'));
      await _pumpLiveData(tester);
      await _capture(
        tester,
        boundaryKey,
        'issue-213-delete-confirmation-android.png',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await _pumpLiveData(tester);
      await _scrollToPanel(tester);
      expect(find.text('No external references yet.'), findsOneWidget);
      final remaining = await tester.runAsync(
        () => fixture.repository.externalReferencesForArtwork(
          _UiFixture.artworkId,
        ),
      );
      expect(remaining, isEmpty);

      tester.binding.defaultBinaryMessenger.setMockMessageHandler(
        SystemChannels.accessibility.name,
        null,
      );
    },
  );

  testWidgets(
    'suggestion semantics, confirmation and reorder controls are deterministic',
    (tester) async {
      final fixture = (await tester.runAsync(_UiFixture.create))!;
      addTearDown(() async => tester.runAsync(fixture.dispose));
      await tester.runAsync(
        () => fixture.addSuggestion('suggested', label: 'Suggested source'),
      );
      await tester.runAsync(() => fixture.addManual('confirmed', label: null));
      final boundaryKey = await _pumpDocuments(
        tester,
        fixture,
        platform: TargetPlatform.linux,
      );
      final semantics = tester.ensureSemantics();

      final suggestedNode = tester.getSemantics(
        find.byKey(const ValueKey('external-reference-suggested')),
      );
      expect(
        suggestedNode.label,
        contains(
          'Gallery or artist, Suggested source, AI suggestion, Suggested, position 1 of 2',
        ),
      );
      for (final label in [
        'Open external reference',
        'Edit external reference',
        'Move external reference up',
        'Move external reference down',
        'Delete external reference',
      ]) {
        expect(find.byTooltip(label), findsWidgets);
        expect(
          tester.getSize(_iconButton(label).first).width,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester.getSize(_iconButton(label).first).height,
          greaterThanOrEqualTo(48),
        );
      }
      expect(
        tester
            .widget<IconButton>(_iconButton('Move external reference up').first)
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              _iconButton('Move external reference down').last,
            )
            .onPressed,
        isNull,
      );
      await _capture(
        tester,
        boundaryKey,
        'issue-213-suggested-reorder-boundaries.png',
      );

      await tester.tap(find.byTooltip('Confirm external reference'));
      await _pumpLiveData(tester);
      await _scrollToPanel(tester);
      final confirmed = await tester.runAsync(
        () => fixture.repository.getExternalReference('suggested'),
      );
      expect(confirmed!.origin, ExternalReferenceOrigin.aiSuggestion);
      expect(confirmed.reviewState, ExternalReferenceReviewState.confirmed);
      expect(find.byTooltip('Confirm external reference'), findsNothing);
      await _capture(tester, boundaryKey, 'issue-213-ai-origin-confirmed.png');

      final moveDown = tester.widget<IconButton>(
        _iconButton('Move external reference down').first,
      );
      moveDown.focusNode!.requestFocus();
      await tester.pump();
      expect(moveDown.focusNode!.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _pumpLiveData(tester);
      await _waitForFinder(tester, _iconButton('Open external reference'));
      await _waitForEnabledIconButton(tester, 'Open external reference');
      final movedOpen = tester.widget<IconButton>(
        _iconButton('Open external reference').last,
      );
      expect(movedOpen.focusNode!.canRequestFocus, isTrue);
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        'reference-suggested-open',
      );
      await _scrollToPanel(tester);
      final order = await tester.runAsync(
        () => fixture.repository.externalReferencesForArtwork(
          _UiFixture.artworkId,
        ),
      );
      expect(order!.map((row) => row.id), ['confirmed', 'suggested']);
      semantics.dispose();
    },
  );

  testWidgets('web and native launch failures use exact copy and announce once', (
    tester,
  ) async {
    for (final target in ExternalReferenceLaunchTarget.values) {
      for (final throws in [false, true]) {
        final fixture = (await tester.runAsync(_UiFixture.create))!;
        await tester.runAsync(
          () => fixture.addManual('launch', label: 'Offline reference'),
        );
        final gateway = _UiGateway(
          target: target,
          throws: throws,
          result: false,
        );
        final boundaryKey = await _pumpDocuments(
          tester,
          fixture,
          gateway: gateway,
        );
        var announcements = 0;
        tester.binding.defaultBinaryMessenger.setMockMessageHandler(
          SystemChannels.accessibility.name,
          (message) async {
            if (_isAnnouncement(message)) announcements++;
            return null;
          },
        );

        expect(
          gateway.uris,
          isEmpty,
          reason: 'local rows render without network or launch',
        );
        expect(
          find.text(
            target == ExternalReferenceLaunchTarget.web
                ? 'Opens in a new browser tab.'
                : 'Opens in your browser or another app.',
          ),
          findsOneWidget,
        );
        if (target == ExternalReferenceLaunchTarget.native && !throws) {
          await _capture(tester, boundaryKey, 'issue-213-offline.png');
        }
        await tester.tap(find.byTooltip('Open external reference'));
        await _pumpLiveData(tester);
        expect(gateway.uris, hasLength(1));
        expect(announcements, 1);
        expect(
          find.text(
            target == ExternalReferenceLaunchTarget.web
                ? 'Your browser couldn’t open this reference in a new tab.'
                : 'Couldn’t open this reference outside Archivale.',
          ),
          findsOneWidget,
        );
        await _capture(
          tester,
          boundaryKey,
          'issue-213-${target.name}-${throws ? 'exception' : 'false'}-launch.png',
        );
        if (target == ExternalReferenceLaunchTarget.native && !throws) {
          await _capture(
            tester,
            boundaryKey,
            'issue-213-native-unsupported-launch.png',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.dispose);
      }
    }
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      SystemChannels.accessibility.name,
      null,
    );
  });

  testWidgets(
    'Android iOS and Chrome visual accessibility matrix has no overflow',
    (tester) async {
      final fixture = (await tester.runAsync(_UiFixture.create))!;
      addTearDown(() async => tester.runAsync(fixture.dispose));
      await tester.runAsync(
        () => fixture.addSuggestion(
          'matrix-suggestion',
          label: 'A long collector reference label for scaling',
        ),
      );
      await tester.runAsync(
        () => fixture.addManual('matrix-confirmed', label: null),
      );

      final cases = <_MatrixCase>[
        for (final size in [const Size(360, 800), const Size(320, 568)])
          for (final scale in [1.0, 2.0])
            _MatrixCase(
              'android-${size.width.toInt()}x${size.height.toInt()}-scale$scale',
              size,
              scale,
              TargetPlatform.android,
              ExternalReferenceLaunchTarget.native,
            ),
        for (final size in [const Size(390, 844), const Size(320, 568)])
          for (final scale in [1.0, 2.0])
            _MatrixCase(
              'ios-${size.width.toInt()}x${size.height.toInt()}-scale$scale',
              size,
              scale,
              TargetPlatform.iOS,
              ExternalReferenceLaunchTarget.native,
            ),
        for (final viewport in [const Size(1280, 800), const Size(320, 800)])
          for (final zoom in [1.0, 2.0])
            _MatrixCase(
              'chrome-${viewport.width.toInt()}x${viewport.height.toInt()}-zoom${(zoom * 100).toInt()}',
              Size(viewport.width / zoom, viewport.height / zoom),
              1,
              TargetPlatform.linux,
              ExternalReferenceLaunchTarget.web,
            ),
      ];

      for (final matrix in cases) {
        final boundaryKey = await _pumpDocuments(
          tester,
          fixture,
          size: matrix.logicalSize,
          textScale: matrix.textScale,
          platform: matrix.platform,
          gateway: _UiGateway(target: matrix.launchTarget),
        );
        expect(tester.takeException(), isNull, reason: matrix.name);
        for (final label in [
          'Open external reference',
          'Edit external reference',
          'Move external reference up',
          'Move external reference down',
          'Delete external reference',
        ]) {
          expect(find.byTooltip(label), findsWidgets, reason: matrix.name);
        }
        expect(
          find.text(
            matrix.launchTarget == ExternalReferenceLaunchTarget.web
                ? 'Opens in a new browser tab.'
                : 'Opens in your browser or another app.',
          ),
          findsOneWidget,
        );
        await _capture(tester, boundaryKey, 'issue-213-${matrix.name}.png');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
}

Future<void> _loadScreenshotFont() async {
  const materialIconPath =
      '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
  final materialIconFile = File(materialIconPath);
  if (materialIconFile.existsSync()) {
    final iconBytes = await materialIconFile.readAsBytes();
    final iconLoader = FontLoader('MaterialIcons')
      ..addFont(Future<ByteData>.value(ByteData.sublistView(iconBytes)));
    await iconLoader.load();
  }

  for (final path in const [
    '/System/Library/Fonts/SFNS.ttf',
    '/Library/Fonts/Arial.ttf',
  ]) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final bytes = await file.readAsBytes();
    final loader = FontLoader('Roboto')
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
    return;
  }
}

Future<GlobalKey> _pumpDocuments(
  WidgetTester tester,
  _UiFixture fixture, {
  Size size = const Size(390, 844),
  double textScale = 1,
  TargetPlatform platform = TargetPlatform.android,
  ExternalReferenceLaunchGateway? gateway,
}) async {
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundaryKey,
      child: ArchivaleApp(
        initialRoute: AppRoutes.artworkDocuments(_UiFixture.artworkId),
        dependencies: fixture.dependencies(gateway: gateway),
        platform: platform,
      ),
    ),
  );
  await _pumpLiveData(tester);
  await _scrollToPanel(tester);
  return boundaryKey;
}

Future<void> _scrollToPanel(WidgetTester tester) async {
  final panel = find.byKey(const ValueKey('external-references-panel'));
  for (var attempt = 0; attempt < 30 && panel.evaluate().isEmpty; attempt++) {
    await _pumpLiveData(tester);
  }
  expect(panel, findsOneWidget);
  final scrollable = find.byType(Scrollable).first;
  expect(scrollable, findsOneWidget);
  await tester.scrollUntilVisible(panel, 240, scrollable: scrollable);
  await _pumpLiveData(tester);
}

Finder _iconButton(String tooltip) => find.ancestor(
  of: find.byTooltip(tooltip),
  matching: find.byType(IconButton),
);

bool _isAnnouncement(ByteData? message) {
  final event = const StandardMessageCodec().decodeMessage(message);
  return event is Map<Object?, Object?> && event['type'] == 'announce';
}

Future<void> _waitForFinder(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 30 && finder.evaluate().isEmpty; attempt++) {
    await _pumpLiveData(tester);
  }
  expect(finder, findsWidgets);
}

Future<void> _waitForEnabledIconButton(
  WidgetTester tester,
  String tooltip,
) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    final finder = _iconButton(tooltip);
    if (finder.evaluate().isNotEmpty &&
        tester.widget<IconButton>(finder.last).onPressed != null) {
      await tester.pump();
      return;
    }
    await _pumpLiveData(tester);
  }
  fail('$tooltip did not become enabled.');
}

Future<void> _pumpLiveData(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () async => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundaryKey,
  String fileName,
) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  boundary.markNeedsPaint();
  await tester.pump();
  final bytes = await tester.runAsync<Uint8List>(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  final output = Directory(p.join('artifacts', 'visual'));
  output.createSync(recursive: true);
  File(p.join(output.path, fileName)).writeAsBytesSync(bytes!);
}

class _UiFixture {
  _UiFixture(this.tempDirectory, this.repository, this.attachmentStore);

  static const artworkId = 'external-reference-artwork';
  final Directory tempDirectory;
  final LocalArtworkRepository repository;
  final LocalAttachmentStore attachmentStore;

  static Future<_UiFixture> create() async {
    final temp = await Directory.systemTemp.createTemp(
      'external-reference-ui-',
    );
    final repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(p.join(temp.path, 'records.db')),
    );
    final store = await LocalAttachmentStore.openAt(
      Directory(p.join(temp.path, 'attachments')),
    );
    await repository.create(
      ArtworkRecord(
        id: artworkId,
        recordState: ArtworkRecordState.verifiedByYou,
        createdAt: DateTime.utc(2026, 7, 13),
        updatedAt: DateTime.utc(2026, 7, 13),
        fields: const {
          ArtworkFieldKeys.title: ArtworkFieldValue(
            value: 'External Reference Study',
            source: ArtworkFieldSource.userConfirmed,
            note: 'Confirmed by collector',
          ),
        },
      ),
    );
    return _UiFixture(temp, repository, store);
  }

  AppDependencies dependencies({ExternalReferenceLaunchGateway? gateway}) =>
      AppDependencies(
        artworkRepository: repository,
        attachmentStore: attachmentStore,
        imagePicker: const _NoImagePicker(),
        externalReferenceLaunchGateway: gateway,
      );

  Future<void> addManual(String id, {required String? label}) async {
    await repository.addManualExternalReference(
      referenceId: id,
      artworkId: artworkId,
      type: ExternalReferenceType.galleryOrArtist,
      label: label,
      url: 'https://example.com/$id',
      transactionTime: DateTime.utc(2026, 7, 13, 8, id.length),
    );
  }

  Future<void> addSuggestion(String id, {required String? label}) async {
    await repository.saveExternalReferenceSuggestion(
      referenceId: id,
      artworkId: artworkId,
      type: ExternalReferenceType.galleryOrArtist,
      label: label,
      url: 'https://example.com/$id',
      transactionTime: DateTime.utc(2026, 7, 13, 8, id.length),
    );
  }

  Future<void> dispose() async {
    await repository.close();
    await tempDirectory.delete(recursive: true);
  }
}

class _NoImagePicker implements ArtworkImagePicker {
  const _NoImagePicker();

  @override
  Future<XFile?> pick(ArtworkImagePickMode mode) async => null;

  @override
  Future<XFile?> retrieveLostImage() async => null;
}

class _UiGateway implements ExternalReferenceLaunchGateway {
  _UiGateway({required this.target, this.result = true, this.throws = false});

  @override
  final ExternalReferenceLaunchTarget target;
  final bool result;
  final bool throws;
  final List<Uri> uris = [];

  @override
  Future<bool> launchExternal(Uri uri) async {
    uris.add(uri);
    if (throws) throw StateError('launch failed');
    return result;
  }
}

class _MatrixCase {
  const _MatrixCase(
    this.name,
    this.logicalSize,
    this.textScale,
    this.platform,
    this.launchTarget,
  );

  final String name;
  final Size logicalSize;
  final double textScale;
  final TargetPlatform platform;
  final ExternalReferenceLaunchTarget launchTarget;
}
