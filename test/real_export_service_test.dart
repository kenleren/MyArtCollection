import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:my_art_collection/app/app_dependencies.dart';
import 'package:my_art_collection/app/export/archive_export_service.dart';
import 'package:my_art_collection/app/export/archive_v1_codec.dart';
import 'package:my_art_collection/app/export/export_artifact_store.dart';
import 'package:my_art_collection/app/export/export_destination_gateway.dart';
import 'package:my_art_collection/app/export/pdf_report_service.dart';
import 'package:my_art_collection/app/intake/artwork_image_picker.dart';
import 'package:my_art_collection/app/screens/prototype_flow.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/attachment_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:my_art_collection/app/storage/local_attachment_store.dart';
import 'package:my_art_collection/app/storage/external_reference.dart';
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
    'archive v1 root and artwork bytes match frozen golden fixtures',
    () async {
      final codec = const ArchivaleArchiveV1Codec();
      final artworkGolden = await File(
        'test/fixtures/archive_v1/artworks.golden.json',
      ).readAsString();
      expect(
        utf8.decode(codec.encodeArtworks([_artwork()])),
        artworkGolden.trimRight(),
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
      final manifestGolden = await File(
        'test/fixtures/archive_v1/manifest.golden.json',
      ).readAsString();
      expect(
        utf8.decode(archive.findFile('manifest.json')!.content),
        manifestGolden.trimRight(),
      );
      expect(
        () => codec.decodeManifest(
          Uint8List.fromList(utf8.encode(manifestGolden.trimRight())),
        ),
        returnsNormally,
      );
    },
  );

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
      await repository.addManualExternalReference(
        referenceId: 'reference-1',
        artworkId: 'artwork-1',
        type: ExternalReferenceType.galleryOrArtist,
        label: 'Gallery record',
        url: 'https://example.com/gallery-record',
        transactionTime: DateTime.utc(2026, 7, 14, 8, 30),
      );

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
      final decoded = const ArchivaleArchiveV1Codec().decodeArchive(
        Uint8List.fromList(await artifact.file.readAsBytes()),
      );
      expect(decoded.artworks, hasLength(1));
      expect(decoded.artworks.single.id, 'artwork-1');
      expect(
        decoded.artworks.single.lifecycleStatus,
        ArtworkLifecycleStatus.active,
      );
      expect(
        decoded.artworks.single.fields.keys.toSet(),
        _artwork().fields.keys.toSet(),
      );
      for (final entry in _artwork().fields.entries) {
        final roundTripped = decoded.artworks.single.fields[entry.key]!;
        expect(roundTripped.value, entry.value.value);
        expect(roundTripped.source, entry.value.source);
        expect(roundTripped.note, entry.value.note);
        expect(roundTripped.lastConfirmedAt, entry.value.lastConfirmedAt);
        expect(roundTripped.moneyAmount, entry.value.moneyAmount);
        expect(roundTripped.moneyCurrencyCode, entry.value.moneyCurrencyCode);
      }
      expect(decoded.externalReferences.single.id, 'reference-1');
      expect(decoded.externalReferences.single.label, 'Gallery record');
      expect(decoded.attachmentOutcomes.single, row);
      expect(
        decoded.payloads['attachments/attachment-1/payload.pdf'],
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

  test('archive v1 preserves every frozen exclusion outcome', () async {
    final corrupt = await _addPdfAttachment(
      temp: temp,
      repository: repository,
      attachmentStore: attachmentStore,
      id: 'attachment-corrupt',
    );
    await attachmentStore.fileFor(corrupt).writeAsBytes([..._pdfBytes, 0]);
    final superseded = await _addPdfAttachment(
      temp: temp,
      repository: repository,
      attachmentStore: attachmentStore,
      id: 'attachment-superseded',
    );
    await repository.updateAttachmentLifecycle(
      attachmentId: superseded.id,
      lifecycleStatus: AttachmentLifecycleStatus.superseded,
      updatedAt: DateTime.utc(2026, 7, 14, 8, 10),
    );
    final removed = await _addPdfAttachment(
      temp: temp,
      repository: repository,
      attachmentStore: attachmentStore,
      id: 'attachment-removed',
    );
    await repository.updateAttachmentLifecycle(
      attachmentId: removed.id,
      lifecycleStatus: AttachmentLifecycleStatus.removed,
      updatedAt: DateTime.utc(2026, 7, 14, 8, 11),
    );

    final artifact = await ArchiveExportService(
      repository: repository,
      attachmentStore: attachmentStore,
      artifactStore: artifactStore,
      clock: () => DateTime.utc(2026, 7, 14, 9),
    ).generate();
    final decoded = const ArchivaleArchiveV1Codec().decodeArchive(
      Uint8List.fromList(await artifact.file.readAsBytes()),
    );
    final statuses = {
      for (final row in decoded.attachmentOutcomes)
        row['attachment_id']: row['archive_status'],
    };
    expect(statuses, {
      'attachment-corrupt': 'excluded_checksum_mismatch',
      'attachment-removed': 'excluded_user_removed',
      'attachment-superseded': 'excluded_superseded',
    });
    expect(decoded.payloads, isEmpty);
  });

  test('mid-flight cancellation deletes staged and completed output', () async {
    await _addPdfAttachment(
      temp: temp,
      repository: repository,
      attachmentStore: attachmentStore,
      id: 'attachment-cancel',
    );
    final token = ExportCancellationToken();
    final service = ArchiveExportService(
      repository: repository,
      attachmentStore: attachmentStore,
      artifactStore: artifactStore,
      clock: () => DateTime.utc(2026, 7, 14, 9),
    );

    await expectLater(
      service.generate(
        cancellationToken: token,
        onProgress: (progress) {
          if (progress.completedItems == 4) token.cancel();
        },
      ),
      throwsA(isA<ExportCancelledException>()),
    );
    expect(await artifactStore.latest(ExportArtifactKind.archive), isNull);
    expect(await _partialFiles(artifactStore.root), isEmpty);
  });

  test('payload TOCTOU change after index creation fails closed', () async {
    final attachment = await _addPdfAttachment(
      temp: temp,
      repository: repository,
      attachmentStore: attachmentStore,
      id: 'attachment-toctou',
    );
    var changed = false;
    final service = ArchiveExportService(
      repository: repository,
      attachmentStore: attachmentStore,
      artifactStore: artifactStore,
      clock: () => DateTime.utc(2026, 7, 14, 9),
    );

    await expectLater(
      service.generate(
        onProgress: (progress) {
          if (!changed && progress.completedItems == 4) {
            changed = true;
            attachmentStore.fileFor(attachment).writeAsBytesSync([
              ..._pdfBytes,
              1,
            ]);
          }
        },
      ),
      throwsA(isA<ExportIntegrityException>()),
    );
    expect(await artifactStore.latest(ExportArtifactKind.archive), isNull);
    expect(await _partialFiles(artifactStore.root), isEmpty);
  });

  test(
    'artifact commit failure leaves no observable partial archive',
    () async {
      final createdAt = DateTime.utc(2026, 7, 14, 9);
      final collision = Directory(
        p.join(
          artifactStore.root.path,
          'archives',
          'archive-${createdAt.microsecondsSinceEpoch}.zip',
        ),
      );
      await collision.create(recursive: true);

      await expectLater(
        ArchiveExportService(
          repository: repository,
          attachmentStore: attachmentStore,
          artifactStore: artifactStore,
          clock: () => createdAt,
        ).generate(),
        throwsA(isA<FileSystemException>()),
      );
      expect(await artifactStore.latest(ExportArtifactKind.archive), isNull);
      expect(await _partialFiles(artifactStore.root), isEmpty);
    },
  );

  test(
    'archive decoder rejects a payload that no longer matches manifest',
    () async {
      await _addPdfAttachment(
        temp: temp,
        repository: repository,
        attachmentStore: attachmentStore,
        id: 'attachment-tamper',
      );
      final artifact = await ArchiveExportService(
        repository: repository,
        attachmentStore: attachmentStore,
        artifactStore: artifactStore,
        clock: () => DateTime.utc(2026, 7, 14, 9),
      ).generate();
      final source = ZipDecoder().decodeBytes(
        await artifact.file.readAsBytes(),
      );
      final tampered = Archive();
      for (final file in source.files) {
        final content = List<int>.from(file.content as List<int>);
        if (file.name == 'attachments/attachment-tamper/payload.pdf') {
          content.add(0);
        }
        tampered.addFile(ArchiveFile(file.name, content.length, content));
      }
      final bytes = Uint8List.fromList(ZipEncoder().encode(tampered));

      expect(
        () => const ArchivaleArchiveV1Codec().decodeArchive(bytes),
        throwsA(isA<ArchiveV1FormatException>()),
      );
    },
  );

  test('large collection remains deterministic and round-trips', () async {
    await repository.createAll([
      for (var index = 2; index <= 202; index++)
        _artworkWithId('artwork-$index'),
    ]);
    final artifact = await ArchiveExportService(
      repository: repository,
      attachmentStore: attachmentStore,
      artifactStore: artifactStore,
      clock: () => DateTime.utc(2026, 7, 14, 9),
    ).generate();

    final decoded = const ArchivaleArchiveV1Codec().decodeArchive(
      Uint8List.fromList(await artifact.file.readAsBytes()),
    );
    expect(decoded.artworks, hasLength(202));
    expect(decoded.artworks.first.id, 'artwork-1');
    expect(decoded.artworks.last.id, 'artwork-99');
  });

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
    await _addPdfAttachment(
      temp: temp,
      repository: repository,
      attachmentStore: attachmentStore,
      id: 'attachment-source-label',
    );
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
    final extracted = await Process.run('pdftotext', [artifact.file.path, '-']);
    expect(extracted.exitCode, 0, reason: extracted.stderr.toString());
    expect(extracted.stdout, contains('Kari Ødegård – blå'));
    expect(extracted.stdout, contains('Source: user-confirmed'));
    expect(extracted.stdout, isNot(contains(r'\u00d8')));
    expect(
      await artifactStore.latest(
        ExportArtifactKind.report,
        subjectId: 'artwork-1',
      ),
      isNotNull,
    );
  });

  testWidgets('report artifact identity never crosses artwork screens', (
    tester,
  ) async {
    final reportA = (await tester.runAsync(() async {
      await repository.create(_artworkWithId('artwork-2'));
      return PdfReportService(
        repository: repository,
        attachmentStore: attachmentStore,
        artifactStore: artifactStore,
        clock: () => DateTime.utc(2026, 7, 14, 9),
      ).generate('artwork-1');
    }))!;
    expect(reportA.subjectId, 'artwork-1');
    expect(
      await tester.runAsync(
        () => artifactStore.latest(
          ExportArtifactKind.report,
          subjectId: 'artwork-2',
        ),
      ),
      isNull,
    );
    final dependencies = AppDependencies(
      artworkRepository: repository,
      attachmentStore: attachmentStore,
      imagePicker: _NoImagePicker(),
      exportArtifactStore: artifactStore,
      exportDestinationGateway: _FakeDestinationGateway(),
    );
    await tester.pumpWidget(
      AppDependencyScope(
        dependencies: dependencies,
        child: const MaterialApp(
          home: Scaffold(
            body: ExportWorkflowPanel(
              kind: ExportArtifactKind.report,
              artworkId: 'artwork-2',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('open-export-action')), findsNothing);
    expect(
      find.byKey(const ValueKey('generate-export-action')),
      findsOneWidget,
    );

    await tester.runAsync(() async {
      final metadataFile = File('${reportA.file.path}.json');
      final metadata =
          jsonDecode(await metadataFile.readAsString()) as Map<String, Object?>;
      metadata['subject_id'] = 'artwork-2';
      await metadataFile.writeAsString(jsonEncode(metadata), flush: true);
    });
    expect(
      await tester.runAsync(
        () => artifactStore.latest(
          ExportArtifactKind.report,
          subjectId: 'artwork-1',
        ),
      ),
      isNull,
    );
    expect(
      await tester.runAsync(
        () => artifactStore.latest(
          ExportArtifactKind.report,
          subjectId: 'artwork-2',
        ),
      ),
      isNull,
    );
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

Future<List<FileSystemEntity>> _partialFiles(Directory root) => root
    .list(recursive: true)
    .where((entry) => entry.path.endsWith('.partial'))
    .toList();

Future<AttachmentRecord> _addPdfAttachment({
  required Directory temp,
  required LocalArtworkRepository repository,
  required LocalAttachmentStore attachmentStore,
  required String id,
}) async {
  final source = File(p.join(temp.path, '$id.pdf'));
  await source.writeAsBytes(_pdfBytes);
  final record = await attachmentStore.saveImportedAttachment(
    artworkId: 'artwork-1',
    attachmentId: id,
    sourceFile: source,
    originalFileName: '$id.pdf',
    mimeType: 'application/pdf',
    type: AttachmentType.receipt,
    source: ArtworkFieldSource.userConfirmed,
    importedAt: DateTime.utc(2026, 7, 14, 8),
  );
  await repository.addAttachment(record);
  return record;
}

ArtworkRecord _artworkWithId(String id) {
  final template = _artwork();
  return ArtworkRecord(
    id: id,
    recordState: template.recordState,
    lifecycleStatus: template.lifecycleStatus,
    createdAt: template.createdAt,
    updatedAt: template.updatedAt,
    fields: template.fields,
  );
}

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
      value: 'Kari Ødegård – blå',
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
