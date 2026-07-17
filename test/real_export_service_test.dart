import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:my_art_collection/app/app_dependencies.dart';
import 'package:my_art_collection/app/export/archive_export_service.dart';
import 'package:my_art_collection/app/export/archive_v1_codec.dart';
import 'package:my_art_collection/app/export/archive_v2_codec.dart';
import 'package:my_art_collection/app/export/external_reference_export_codec.dart';
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

  test('v1 artwork golden remains frozen while the service emits v2', () async {
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
    final archive = ZipDecoder().decodeBytes(await artifact.file.readAsBytes());
    final manifestGolden = await File(
      'test/fixtures/archive_v1/manifest.golden.json',
    ).readAsString();
    expect(
      _jsonEntry(archive, 'manifest.json')['contract'],
      'ARCHIVALE_ARCHIVE_V2',
    );
    expect(archive.findFile('records/groupings.json'), isNotNull);
    expect(
      () => codec.decodeManifest(
        Uint8List.fromList(utf8.encode(manifestGolden.trimRight())),
      ),
      returnsNormally,
    );
  });

  test(
    'archive v2 contains canonical records, groupings, and verified original bytes',
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
          'records/groupings.json',
          'attachments/attachment-1/payload.pdf',
        ]),
      );
      final manifest = _jsonEntry(archive, 'manifest.json');
      expect(manifest['contract'], ArchiveExportService.contract);
      expect(manifest['version'], 2);
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
      final bytes = Uint8List.fromList(await artifact.file.readAsBytes());
      final decoded = const ArchivaleArchiveV2Codec().decodeArchive(bytes);
      final artworks = const ArchivaleArchiveV1Codec().decodeArtworks(
        Uint8List.fromList(archive.findFile('records/artworks.json')!.content),
      );
      final references = const ExternalReferenceExportCodec().decodeStandalone(
        Uint8List.fromList(
          archive.findFile('records/external_references.json')!.content,
        ),
      );
      final outcomes = const ArchivaleArchiveV1Codec().decodeAttachmentOutcomes(
        Uint8List.fromList(
          archive.findFile('records/attachments.json')!.content,
        ),
      );
      expect(decoded.groupings.groups, isEmpty);
      expect(artworks, hasLength(1));
      expect(artworks.single.id, 'artwork-1');
      expect(artworks.single.lifecycleStatus, ArtworkLifecycleStatus.active);
      expect(
        artworks.single.fields.keys.toSet(),
        _artwork().fields.keys.toSet(),
      );
      for (final entry in _artwork().fields.entries) {
        final roundTripped = artworks.single.fields[entry.key]!;
        expect(roundTripped.value, entry.value.value);
        expect(roundTripped.source, entry.value.source);
        expect(roundTripped.note, entry.value.note);
        expect(roundTripped.lastConfirmedAt, entry.value.lastConfirmedAt);
        expect(roundTripped.moneyAmount, entry.value.moneyAmount);
        expect(roundTripped.moneyCurrencyCode, entry.value.moneyCurrencyCode);
      }
      expect(references.single.id, 'reference-1');
      expect(references.single.label, 'Gallery record');
      expect(outcomes.single, row);
    },
  );

  test(
    'archive v2 round-trips non-empty local organization canonically',
    () async {
      await repository.createGroup(id: 'group-studio', name: ' Studio ');
      await repository.replaceArtworkGroupMemberships(
        artworkId: 'artwork-1',
        groupIds: {'group-studio'},
        now: DateTime.utc(2026, 7, 14, 8),
      );
      await repository.setFavorite(
        artworkId: 'artwork-1',
        isFavorite: true,
        now: DateTime.utc(2026, 7, 14, 8),
      );
      final artifact = await ArchiveExportService(
        repository: repository,
        attachmentStore: attachmentStore,
        artifactStore: artifactStore,
        clock: () => DateTime.utc(2026, 7, 14, 9),
      ).generate();
      final decoded = const ArchivaleArchiveV2Codec().decodeArchive(
        Uint8List.fromList(await artifact.file.readAsBytes()),
      );
      expect(decoded.groupings.groups.single.name, 'Studio');
      expect(decoded.groupings.memberships.single['group_id'], 'group-studio');
      expect(decoded.groupings.preferences.single['is_favorite'], 1);
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
    final decoded = const ArchivaleArchiveV2Codec().decodeArchive(
      Uint8List.fromList(await artifact.file.readAsBytes()),
    );
    final statuses = {
      for (final row
          in const ArchivaleArchiveV1Codec().decodeAttachmentOutcomes(
            Uint8List.fromList(
              ZipDecoder()
                  .decodeBytes(await artifact.file.readAsBytes())
                  .findFile('records/attachments.json')!
                  .content,
            ),
          ))
        row['attachment_id']: row['archive_status'],
    };
    expect(statuses, {
      'attachment-corrupt': 'excluded_checksum_mismatch',
      'attachment-removed': 'excluded_user_removed',
      'attachment-superseded': 'excluded_superseded',
    });
    expect(decoded.groupings.groups, isEmpty);
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
    'same-inode rewrite and restore across archive read passes fails closed',
    () async {
      final originalBytes = _validPdfBytes(
        prefixComments: List<String>.filled(32 * 1024, '% padding'),
      );
      final source = File(p.join(temp.path, 'large-original.pdf'));
      await source.writeAsBytes(originalBytes, flush: true);
      final attachment = await attachmentStore.saveImportedAttachment(
        artworkId: 'artwork-1',
        attachmentId: 'attachment-rewrite-restore',
        sourceFile: source,
        originalFileName: 'large-original.pdf',
        mimeType: 'application/pdf',
        type: AttachmentType.receipt,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: DateTime.utc(2026, 7, 14, 8),
      );
      await repository.addAttachment(attachment);
      final payload = attachmentStore.fileFor(attachment);
      final mutated = List<int>.from(originalBytes)..[160 * 1024] ^= 0x01;
      final service = ArchiveExportService(
        repository: repository,
        attachmentStore: attachmentStore,
        artifactStore: artifactStore,
        clock: () => DateTime.utc(2026, 7, 14, 9),
        attachmentReadPassHookForTest: (record, pass) {
          if (record.id != attachment.id) return;
          if (pass == 1) payload.writeAsBytesSync(mutated, flush: true);
          if (pass == 2) payload.writeAsBytesSync(originalBytes, flush: true);
        },
      );

      await expectLater(
        service.generate(),
        throwsA(isA<ExportIntegrityException>()),
      );
      expect(await artifactStore.latest(ExportArtifactKind.archive), isNull);
      expect(await payload.readAsBytes(), originalBytes);
      expect(await _partialFiles(artifactStore.root), isEmpty);
    },
  );

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
        throwsA(isA<StateError>()),
      );
      expect(await artifactStore.latest(ExportArtifactKind.archive), isNull);
      expect(await _partialFiles(artifactStore.root), isEmpty);
    },
  );

  test('committed metadata and latest bind exact payload bytes', () async {
    final artifact = await ArchiveExportService(
      repository: repository,
      attachmentStore: attachmentStore,
      artifactStore: artifactStore,
      clock: () => DateTime.utc(2026, 7, 14, 9),
    ).generate();
    final metadata =
        jsonDecode(await File('${artifact.file.path}.json').readAsString())
            as Map<String, Object?>;
    expect(metadata.keys.toList(), [
      'metadata_version',
      'state',
      'artifact_id',
      'kind',
      'subject_id',
      'file_name',
      'mime_type',
      'byte_size',
      'checksum_sha256',
      'created_at',
      'warnings',
    ]);
    expect(metadata['state'], 'complete');
    expect(metadata['byte_size'], artifact.byteSize);
    expect(metadata['checksum_sha256'], artifact.checksumSha256);

    final bytes = await artifact.file.readAsBytes();
    bytes[bytes.length ~/ 2] ^= 0xff;
    await artifact.file.writeAsBytes(bytes, flush: true);
    expect(await artifact.revalidate(), isNull);
    expect(await artifactStore.latest(ExportArtifactKind.archive), isNull);
  });

  test(
    'artifact metadata requires a semantic canonical UTC timestamp',
    () async {
      final artifact = await ArchiveExportService(
        repository: repository,
        attachmentStore: attachmentStore,
        artifactStore: artifactStore,
        clock: () => DateTime.utc(2026, 7, 14, 9),
      ).generate();
      final metadataFile = File('${artifact.file.path}.json');
      final original =
          jsonDecode(await metadataFile.readAsString()) as Map<String, Object?>;
      const invalid = [
        '2026-99-14T09:00:00.000Z',
        '2026-02-30T09:00:00.000Z',
        '2026-07-14T24:00:00.000Z',
        '2026-07-14T09:60:00.000Z',
        '2026-07-14T09:00:00+00:00',
        '2026-07-14T09:00:00Z',
        '2026-07-14T09:00:00.123000Z',
        '2026-07-14T09:00:00.000000Z',
        '2026-07-14T09:00:00.0000000Z',
      ];
      for (final value in invalid) {
        await metadataFile.writeAsString(
          jsonEncode({...original, 'created_at': value}),
          flush: true,
        );
        expect(await artifact.revalidate(), isNull, reason: value);
      }

      final microsecondArtifact = await ArchiveExportService(
        repository: repository,
        attachmentStore: attachmentStore,
        artifactStore: artifactStore,
        clock: () => DateTime.utc(2026, 7, 14, 9, 0, 1, 123, 456),
      ).generate();
      expect(await microsecondArtifact.revalidate(), isNotNull);
    },
  );

  test(
    'latest rejects metadata, staging, arbitrary files, and symlinks',
    () async {
      final archiveDirectory = Directory(
        p.join(artifactStore.root.path, 'archives'),
      );
      await archiveDirectory.create(recursive: true);
      await File(
        p.join(archiveDirectory.path, 'archive-fake.zip'),
      ).writeAsBytes([1]);
      await File(
        p.join(archiveDirectory.path, 'archive-fake.zip.partial'),
      ).writeAsBytes([2]);
      await File(
        p.join(archiveDirectory.path, 'archive-fake.zip.json'),
      ).writeAsString('{}');
      expect(await artifactStore.latest(ExportArtifactKind.archive), isNull);

      final artifact = await ArchiveExportService(
        repository: repository,
        attachmentStore: attachmentStore,
        artifactStore: artifactStore,
        clock: () => DateTime.utc(2026, 7, 14, 10),
      ).generate();
      final linkId = 'archive-202607141001';
      final link = File(p.join(archiveDirectory.path, '$linkId.zip'));
      await Link(link.path).create(artifact.file.path);
      final linkedMetadata =
          jsonDecode(await File('${artifact.file.path}.json').readAsString())
              as Map<String, Object?>;
      linkedMetadata['artifact_id'] = linkId;
      linkedMetadata['file_name'] = '$linkId.zip';
      await File('${link.path}.json').writeAsString(jsonEncode(linkedMetadata));
      await artifact.file.delete();
      expect(await artifactStore.latest(ExportArtifactKind.archive), isNull);
    },
  );

  test(
    'concurrent same-id commit has one exact winner and no orphan',
    () async {
      final createdAt = DateTime.utc(2026, 7, 14, 11);
      final id = 'archive-${createdAt.microsecondsSinceEpoch}';
      final first = await artifactStore.stagingFile(
        ExportArtifactKind.archive,
        id,
      );
      final second = await artifactStore.stagingFile(
        ExportArtifactKind.archive,
        id,
      );
      await first.writeAsBytes([1, 2, 3], flush: true);
      await second.writeAsBytes([4, 5, 6], flush: true);
      final results = await Future.wait([
        _captureCommit(artifactStore, id, createdAt, first),
        _captureCommit(artifactStore, id, createdAt, second),
      ]);
      expect(results.whereType<ExportArtifact>(), hasLength(1));
      expect(
        results.whereType<Object>().where((value) => value is! ExportArtifact),
        hasLength(1),
      );
      final winner = results.whereType<ExportArtifact>().single;
      expect(
        await winner.file.readAsBytes(),
        anyOf(equals([1, 2, 3]), equals([4, 5, 6])),
      );
      expect(await _partialFiles(artifactStore.root), isEmpty);
      final claims = Directory(p.join(artifactStore.root.path, '.claims'));
      expect(await claims.list().toList(), isEmpty);
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
        () => const ArchivaleArchiveV2Codec().decodeArchive(bytes),
        throwsA(isA<ArchiveV2FormatException>()),
      );
    },
  );

  test(
    'archive v2 rejects extra, malformed, unreferenced, and missing payloads',
    () async {
      await _addPdfAttachment(
        temp: temp,
        repository: repository,
        attachmentStore: attachmentStore,
        id: 'attachment-strict',
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

      final extra = _archiveEntries(source)
        ..['attachments/unreferenced/payload.pdf'] = Uint8List.fromList([1]);
      expect(
        () => const ArchivaleArchiveV2Codec().decodeArchive(
          _v2ArchiveWithEntries(extra),
        ),
        throwsA(isA<ArchiveV2FormatException>()),
      );

      final malformed = _archiveEntries(source)
        ..['attachments/unreferenced/payload.exe'] = Uint8List.fromList([1]);
      expect(
        () => const ArchivaleArchiveV2Codec().decodeArchive(
          _v2ArchiveWithEntries(malformed),
        ),
        throwsA(isA<ArchiveV2FormatException>()),
      );

      final missing = _archiveEntries(source)
        ..remove('attachments/attachment-strict/payload.pdf');
      expect(
        () => const ArchivaleArchiveV2Codec().decodeArchive(
          _v2ArchiveWithEntries(missing),
        ),
        throwsA(isA<ArchiveV2FormatException>()),
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

    const ArchivaleArchiveV2Codec().decodeArchive(
      Uint8List.fromList(await artifact.file.readAsBytes()),
    );
    final archive = ZipDecoder().decodeBytes(await artifact.file.readAsBytes());
    final artworks = const ArchivaleArchiveV1Codec().decodeArtworks(
      Uint8List.fromList(archive.findFile('records/artworks.json')!.content),
    );
    expect(artworks, hasLength(202));
    expect(artworks.first.id, 'artwork-1');
    expect(artworks.last.id, 'artwork-99');
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

  test('PDF rewrite and restore during exact-byte read fails closed', () async {
    final source = File(p.join(temp.path, 'artwork.png'));
    await source.writeAsBytes(_pngBytes, flush: true);
    final attachment = await attachmentStore.saveImportedAttachment(
      artworkId: 'artwork-1',
      attachmentId: 'attachment-pdf-rewrite',
      sourceFile: source,
      originalFileName: 'artwork.png',
      mimeType: 'image/png',
      type: AttachmentType.photo,
      source: ArtworkFieldSource.userConfirmed,
      importedAt: DateTime.utc(2026, 7, 14, 8),
    );
    await repository.addAttachment(attachment);
    final payload = attachmentStore.fileFor(attachment);
    final service = PdfReportService(
      repository: repository,
      attachmentStore: attachmentStore,
      artifactStore: artifactStore,
      clock: () => DateTime.utc(2026, 7, 14, 9),
      imageBytesReaderForTest: (file) async {
        final original = await file.readAsBytes();
        final mutated = Uint8List.fromList(original)
          ..[original.length - 1] ^= 1;
        await file.writeAsBytes(mutated, flush: true);
        final consumed = await file.readAsBytes();
        await file.writeAsBytes(original, flush: true);
        return consumed;
      },
    );

    await expectLater(
      service.generate('artwork-1'),
      throwsA(isA<ExportIntegrityException>()),
    );
    expect(
      await artifactStore.latest(
        ExportArtifactKind.report,
        subjectId: 'artwork-1',
      ),
      isNull,
    );
    expect(await payload.readAsBytes(), _pngBytes);
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
        child: MaterialApp(
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

  testWidgets('archive destination requires just-in-time confirmation', (
    tester,
  ) async {
    final artifact = (await tester.runAsync(
      () => ArchiveExportService(
        repository: repository,
        attachmentStore: attachmentStore,
        artifactStore: artifactStore,
        clock: () => DateTime.utc(2026, 7, 14, 9),
      ).generate(),
    ))!;
    final gateway = _FakeDestinationGateway();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              key: const ValueKey('start-archive-destination'),
              onPressed: () async {
                if (await showEntireCollectionExportConfirmation(
                  context,
                  EntireCollectionDestinationAction.share,
                )) {
                  await gateway.share(artifact);
                }
              },
              child: const Text('Share archive'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('start-archive-destination')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('archive-destination-confirmation')),
      findsOneWidget,
    );
    expect(find.textContaining('every local artwork record'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cancel-archive-destination')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(gateway.shareCalls, 0);

    await tester.tap(find.byKey(const ValueKey('start-archive-destination')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('confirm-archive-destination')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(gateway.shareCalls, 1);
    expect(await tester.runAsync(artifact.revalidate), isNotNull);
  });
}

Map<String, Object?> _jsonEntry(Archive archive, String name) =>
    jsonDecode(utf8.decode(archive.findFile(name)!.content))
        as Map<String, Object?>;

Map<String, Uint8List> _archiveEntries(Archive archive) => {
  for (final file in archive.files)
    if (file.name != 'manifest.json')
      file.name: Uint8List.fromList(file.content as List<int>),
};

Uint8List _v2ArchiveWithEntries(Map<String, Uint8List> entries) {
  const structured = [
    'records/artworks.json',
    'records/external_references.json',
    'records/attachments.json',
    'records/groupings.json',
  ];
  final payloads =
      entries.keys.where((path) => path.startsWith('attachments/')).toList()
        ..sort();
  final ordered = [...structured, ...payloads];
  final manifest = <String, Object?>{
    'contract': ArchivaleArchiveV2Codec.archiveContract,
    'version': ArchivaleArchiveV2Codec.version,
    'created_at': '2026-07-14T09:00:00.000Z',
    'archive_status': 'complete',
    'trust_notice':
        'Values are user-provided or source-labeled. Supporting records do not prove authenticity, attribution, provenance, value, ownership, or insurance acceptance.',
    'counts': {
      'artworks': 1,
      'external_references': 0,
      'attachments_included': 1,
      'attachments_excluded': 0,
      'groups': 0,
      'memberships': 0,
      'preferences': 0,
    },
    'warnings': <Object?>[],
    'files': [
      for (final path in ordered)
        {
          'path': path,
          'size_bytes': entries[path]!.length,
          'checksum_sha256': sha256.convert(entries[path]!).toString(),
        },
    ],
    'exclusions': [
      'generated_reports_and_exports',
      'ai_and_research_job_caches',
      'telemetry',
      'billing_state',
      'credentials_and_device_paths',
    ],
  };
  final archive = Archive()
    ..addFile(ArchiveFile.string('manifest.json', jsonEncode(manifest)));
  for (final path in ordered) {
    final content = entries[path]!;
    archive.addFile(ArchiveFile(path, content.length, content));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Future<List<FileSystemEntity>> _partialFiles(Directory root) => root
    .list(recursive: true)
    .where((entry) => entry.path.endsWith('.partial'))
    .toList();

Future<Object> _captureCommit(
  ExportArtifactStore store,
  String id,
  DateTime createdAt,
  File staging,
) async {
  try {
    return await store.commit(
      kind: ExportArtifactKind.archive,
      id: id,
      staging: staging,
      createdAt: createdAt,
      warnings: const [],
    );
  } on Object catch (error) {
    return error;
  }
}

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
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

List<int> _validPdfBytes({List<String> prefixComments = const []}) {
  const header = '%PDF-1.4\n';
  const catalog = '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n';
  const pages = '2 0 obj\n<< /Type /Pages /Count 0 /Kids [] >>\nendobj\n';
  final comments = prefixComments.map((comment) => '$comment\n').join();
  final catalogOffset = header.length + comments.length;
  final pagesOffset = catalogOffset + catalog.length;
  final xrefOffset = pagesOffset + pages.length;
  final source = StringBuffer(header)
    ..write(comments)
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
  int openCalls = 0;
  int saveCalls = 0;

  @override
  Future<ExportDestinationResult> open(ExportArtifact artifact) async {
    openCalls++;
    return ExportDestinationResult.completed;
  }

  @override
  Future<ExportDestinationResult> saveCopy(ExportArtifact artifact) async {
    saveCalls++;
    return ExportDestinationResult.completed;
  }

  @override
  Future<ExportDestinationResult> share(ExportArtifact artifact) async {
    shareCalls++;
    return ExportDestinationResult.dismissed;
  }
}
