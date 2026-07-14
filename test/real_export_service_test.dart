import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:my_art_collection/app/app_dependencies.dart';
import 'package:my_art_collection/app/export/archive_export_service.dart';
import 'package:my_art_collection/app/export/export_artifact_store.dart';
import 'package:my_art_collection/app/export/export_destination_gateway.dart';
import 'package:my_art_collection/app/export/pdf_report_service.dart';
import 'package:my_art_collection/app/intake/artwork_image_picker.dart';
import 'package:my_art_collection/app/screens/prototype_flow.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/attachment_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:my_art_collection/app/storage/local_attachment_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory temp;
  late LocalArtworkRepository repository;
  late LocalAttachmentStore attachmentStore;
  late ExportArtifactStore artifactStore;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('archivale_export_test_');
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(p.join(temp.path, 'records.db')),
    );
    attachmentStore = await LocalAttachmentStore.openAt(
      Directory(p.join(temp.path, 'attachments')),
    );
    artifactStore = await ExportArtifactStore.openAt(
      Directory(p.join(temp.path, 'generated')),
    );
    await repository.create(_artwork());
  });

  tearDown(() async {
    await repository.close();
    await temp.delete(recursive: true);
  });

  test(
    'archive v1 contains canonical records and verified original bytes',
    () async {
      final source = File(p.join(temp.path, 'receipt.pdf'));
      await source.writeAsBytes(_pdfBytes);
      final attachment = await attachmentStore.saveImportedAttachment(
        artworkId: 'artwork-1',
        attachmentId: 'attachment-1',
        sourceFile: source,
        originalFileName: 'Gallery receipt.pdf',
        mimeType: 'application/pdf',
        type: AttachmentType.receipt,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 14, 8),
      );
      await repository.addAttachment(attachment);

      ExportProgress? lastProgress;
      final artifact = await ArchiveExportService(
        repository: repository,
        attachmentStore: attachmentStore,
        artifactStore: artifactStore,
        clock: () => DateTime.utc(2026, 7, 14, 9),
      ).generate(onProgress: (progress) => lastProgress = progress);

      final archive = ZipDecoder().decodeBytes(
        await artifact.file.readAsBytes(),
      );
      expect(
        archive.files.map((file) => file.name),
        containsAll(<String>[
          'manifest.json',
          'records/artworks.json',
          'records/external_references.json',
          'records/attachments.json',
          'attachments/attachment-1/payload.pdf',
        ]),
      );
      final manifest = _jsonEntry(archive, 'manifest.json');
      expect(manifest['contract'], ArchiveExportService.contract);
      expect(manifest['version'], 1);
      expect(manifest['archive_status'], 'complete');
      expect(
        (manifest['files'] as List<Object?>).cast<Map<String, Object?>>().map(
          (entry) => entry['path'],
        ),
        contains('attachments/attachment-1/payload.pdf'),
      );
      expect(lastProgress!.completedItems, lastProgress!.totalItems);
      expect(lastProgress!.fraction, 1);
      expect(jsonEncode(manifest), isNot(contains(temp.path)));
      final attachmentIndex = _jsonEntry(archive, 'records/attachments.json');
      final row =
          (attachmentIndex['attachments'] as List<Object?>).single
              as Map<String, Object?>;
      expect(row['archive_status'], 'included');
      expect(row['payload_path'], 'attachments/attachment-1/payload.pdf');
      expect(row, isNot(contains('relative_path')));
      expect(
        archive.findFile('attachments/attachment-1/payload.pdf')!.content,
        _pdfBytes,
      );
    },
  );

  test('missing payload is a truthful allowlisted exclusion', () async {
    final source = File(p.join(temp.path, 'receipt.pdf'));
    await source.writeAsBytes(_pdfBytes);
    final attachment = await attachmentStore.saveImportedAttachment(
      artworkId: 'artwork-1',
      attachmentId: 'attachment-missing',
      sourceFile: source,
      originalFileName: 'private-name.pdf',
      mimeType: 'application/pdf',
      type: AttachmentType.receipt,
      source: ArtworkFieldSource.userConfirmed,
      importedAt: DateTime.utc(2026, 7, 14, 8),
    );
    await repository.addAttachment(attachment);
    await attachmentStore.fileFor(attachment).delete();

    final artifact = await ArchiveExportService(
      repository: repository,
      attachmentStore: attachmentStore,
      artifactStore: artifactStore,
      clock: () => DateTime.utc(2026, 7, 14, 9),
    ).generate();
    final archive = ZipDecoder().decodeBytes(await artifact.file.readAsBytes());
    final manifest = _jsonEntry(archive, 'manifest.json');
    expect(manifest['archive_status'], 'with_warnings');
    final attachmentIndex = _jsonEntry(archive, 'records/attachments.json');
    final row =
        (attachmentIndex['attachments'] as List<Object?>).single
            as Map<String, Object?>;
    expect(row, {
      'attachment_id': 'attachment-missing',
      'artwork_id': 'artwork-1',
      'attachment_type': 'receipt',
      'attachment_role': 'supporting_document',
      'lifecycle_status': 'active',
      'archive_status': 'excluded_missing',
    });
    expect(jsonEncode(attachmentIndex), isNot(contains('private-name')));
  });

  test(
    'unavailable originals stay excluded and derivatives stay out',
    () async {
      final source = File(p.join(temp.path, 'original.pdf'));
      await source.writeAsBytes(_pdfBytes);
      final original = await attachmentStore.saveImportedAttachment(
        artworkId: 'artwork-1',
        attachmentId: 'attachment-original',
        sourceFile: source,
        originalFileName: 'original.pdf',
        mimeType: 'application/pdf',
        type: AttachmentType.receipt,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 14, 8),
      );
      await repository.addAttachment(original);
      final derivative = await attachmentStore.saveImportedAttachment(
        artworkId: 'artwork-1',
        attachmentId: 'attachment-derivative',
        sourceFile: source,
        originalFileName: 'derivative.pdf',
        mimeType: 'application/pdf',
        type: AttachmentType.receipt,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 14, 8, 1),
        derivedFromAttachmentId: original.id,
        transformSummary: 'App-generated test derivative.',
      );
      await repository.addAttachment(derivative);
      await repository.updateAttachmentLifecycle(
        attachmentId: original.id,
        lifecycleStatus: AttachmentLifecycleStatus.unavailable,
        updatedAt: DateTime.utc(2026, 7, 14, 8, 2),
      );

      final artifact = await ArchiveExportService(
        repository: repository,
        attachmentStore: attachmentStore,
        artifactStore: artifactStore,
        clock: () => DateTime.utc(2026, 7, 14, 9),
      ).generate();
      final archive = ZipDecoder().decodeBytes(
        await artifact.file.readAsBytes(),
      );
      final attachmentIndex = _jsonEntry(archive, 'records/attachments.json');
      final rows = (attachmentIndex['attachments'] as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(rows, hasLength(1));
      expect(rows.single['attachment_id'], original.id);
      expect(rows.single['archive_status'], 'excluded_missing');
      expect(
        archive.findFile('attachments/${derivative.id}/payload.pdf'),
        isNull,
      );
    },
  );

  test('cancellation keeps no partial archive', () async {
    final token = ExportCancellationToken()..cancel();
    final service = ArchiveExportService(
      repository: repository,
      attachmentStore: attachmentStore,
      artifactStore: artifactStore,
      clock: () => DateTime.utc(2026, 7, 14, 9),
    );
    await expectLater(
      service.generate(cancellationToken: token),
      throwsA(isA<ExportCancelledException>()),
    );
    final partials = await Directory(p.join(temp.path, 'generated'))
        .list(recursive: true)
        .where((entry) => entry.path.endsWith('.partial'))
        .toList();
    expect(partials, isEmpty);
  });

  test('PDF is real and filters unconfirmed fields', () async {
    final confirmed = confirmedFieldsForReport(_artwork());
    expect(confirmed.map((entry) => entry.key), [
      ArtworkFieldKeys.artist,
      ArtworkFieldKeys.insuranceValue,
    ]);

    final artifact = await PdfReportService(
      repository: repository,
      attachmentStore: attachmentStore,
      artifactStore: artifactStore,
      clock: () => DateTime.utc(2026, 7, 14, 9),
    ).generate('artwork-1');
    final bytes = await artifact.file.readAsBytes();
    expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
    expect(bytes.length, greaterThan(1000));
    expect(await artifactStore.latest(ExportArtifactKind.report), isNotNull);
  });

  testWidgets('archive UI generates and keeps artifact after dismissed share', (
    tester,
  ) async {
    final gateway = _FakeDestinationGateway();
    final dependencies = AppDependencies(
      artworkRepository: repository,
      attachmentStore: attachmentStore,
      imagePicker: _NoImagePicker(),
      exportArtifactStore: artifactStore,
      exportDestinationGateway: gateway,
    );
    await tester.pumpWidget(
      AppDependencyScope(
        dependencies: dependencies,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ExportWorkflowPanel(kind: ExportArtifactKind.archive),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('generate-export-action')),
          )
          .onPressed!();
      for (var attempt = 0; attempt < 40; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (await artifactStore.latest(ExportArtifactKind.archive) != null) {
          break;
        }
      }
    });
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('export-workflow-message')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('export-workflow-message')))
          .data,
      'Generated locally and ready.',
    );
    expect(find.byKey(const ValueKey('open-export-action')), findsOneWidget);
    expect(find.byKey(const ValueKey('save-export-action')), findsOneWidget);
    expect(find.byKey(const ValueKey('share-export-action')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('share-export-action')));
    await tester.pumpAndSettle();
    expect(gateway.shareCalls, 1);
    expect(
      find.text(
        'No copy was saved or shared. The generated file remains available here.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('open-export-action')), findsOneWidget);

    final visualArtifact = await tester.runAsync(
      () => artifactStore.latest(ExportArtifactKind.archive),
    );
    expect(visualArtifact, isNotNull);

    for (final fixture in const [
      (size: Size(320, 700), dark: false, scale: 1.35),
      (size: Size(390, 700), dark: true, scale: 1.0),
    ]) {
      await tester.binding.setSurfaceSize(fixture.size);
      await tester.pumpWidget(
        AppDependencyScope(
          dependencies: dependencies,
          child: MaterialApp(
            theme: ThemeData.light(useMaterial3: true),
            darkTheme: ThemeData.dark(useMaterial3: true),
            themeMode: fixture.dark ? ThemeMode.dark : ThemeMode.light,
            home: MediaQuery(
              data: MediaQueryData(
                size: fixture.size,
                textScaler: TextScaler.linear(fixture.scale),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: ExportWorkflowPanel(
                    kind: ExportArtifactKind.archive,
                    initialArtifact: visualArtifact,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('share-export-action')), findsOneWidget);
    }
    await tester.binding.setSurfaceSize(null);
  });
}

Map<String, Object?> _jsonEntry(Archive archive, String name) =>
    jsonDecode(utf8.decode(archive.findFile(name)!.content))
        as Map<String, Object?>;

ArtworkRecord _artwork() => ArtworkRecord(
  id: 'artwork-1',
  recordState: ArtworkRecordState.verifiedByYou,
  lifecycleStatus: ArtworkLifecycleStatus.active,
  createdAt: DateTime.utc(2026, 7, 14, 7),
  updatedAt: DateTime.utc(2026, 7, 14, 8),
  fields: {
    ArtworkFieldKeys.title: const ArtworkFieldValue(
      value: 'AI guess that must not enter the PDF',
      source: ArtworkFieldSource.aiSuggested,
      note: 'Please confirm.',
    ),
    ArtworkFieldKeys.artist: ArtworkFieldValue(
      value: 'Collector confirmed artist',
      source: ArtworkFieldSource.userConfirmed,
      note: 'User confirmed.',
      lastConfirmedAt: DateTime.utc(2026, 7, 14, 8),
    ),
    ArtworkFieldKeys.insuranceValue: const ArtworkFieldValue(
      value: 'NOK 10,000',
      source: ArtworkFieldSource.userConfirmed,
      note: 'User provided.',
      moneyAmount: '10000',
      moneyCurrencyCode: 'NOK',
    ),
    ArtworkFieldKeys.year: const ArtworkFieldValue(
      value: 'Document guess',
      source: ArtworkFieldSource.documentExtracted,
      note: 'Needs review.',
    ),
  },
);

final _pdfBytes = _validPdfBytes();

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

class _NoImagePicker implements ArtworkImagePicker {
  @override
  Future<XFile?> pick(ArtworkImagePickMode mode) async => null;

  @override
  Future<XFile?> retrieveLostImage() async => null;
}

class _FakeDestinationGateway implements ExportDestinationGateway {
  int shareCalls = 0;

  @override
  Future<ExportDestinationResult> open(File file) async =>
      ExportDestinationResult.completed;

  @override
  Future<ExportDestinationResult> saveCopy(
    File file, {
    required String suggestedName,
    required String mimeType,
  }) async => ExportDestinationResult.completed;

  @override
  Future<ExportDestinationResult> share(
    File file, {
    required String displayName,
    required String mimeType,
  }) async {
    shareCalls++;
    return ExportDestinationResult.dismissed;
  }
}
