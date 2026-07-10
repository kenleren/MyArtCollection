import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:my_art_collection/app/intake/artwork_image_picker.dart';
import 'package:my_art_collection/app/intake/attachment_viewer_gateway.dart';
import 'package:my_art_collection/app/intake/artwork_intake_service.dart';
import 'package:my_art_collection/app/intake/supporting_document_picker.dart';
import 'package:my_art_collection/app/intake/supporting_attachment_service.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/attachment_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:my_art_collection/app/storage/local_attachment_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDir;
  late LocalArtworkRepository repository;
  late LocalAttachmentStore attachmentStore;
  late _FakeArtworkImagePicker picker;
  late _FakeSupportingDocumentPicker documentPicker;
  late _FakeAttachmentViewer viewer;
  late int idCounter;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'my_art_collection_supporting_attachment_test_',
    );
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(p.join(tempDir.path, 'records.db')),
    );
    attachmentStore = await LocalAttachmentStore.openAt(
      Directory(p.join(tempDir.path, 'private_files')),
    );
    picker = _FakeArtworkImagePicker();
    documentPicker = _FakeSupportingDocumentPicker();
    viewer = _FakeAttachmentViewer();
    idCounter = 0;
    await repository.upsert(_record('artwork-001'));
  });

  tearDown(() async {
    await repository.close();
    await tempDir.delete(recursive: true);
  });

  SupportingAttachmentService service() {
    return SupportingAttachmentService(
      picker: picker,
      documentPicker: documentPicker,
      viewer: viewer,
      repository: repository,
      attachmentStore: attachmentStore,
      now: () => DateTime.utc(2026, 7, 5, 10),
      idFactory: () => (++idCounter).toString().padLeft(3, '0'),
    );
  }

  test(
    'imports a supporting photo without changing the primary image',
    () async {
      final source = await _imageFile(tempDir, 'signature.png');
      picker.galleryResults.add(
        XFile(source.path, name: 'signature.png', mimeType: 'image/png'),
      );

      final result = await service().importSupportingPhoto('artwork-001');

      expect(result.record.id, 'artwork-001');
      expect(result.record.primaryImageAttachmentId, 'primary-001');
      expect(result.attachment.id, 'attachment-001');
      expect(result.attachment.type, AttachmentType.photo);
      expect(result.attachment.role, AttachmentRole.supportingPhoto);
      expect(result.attachment.source, ArtworkFieldSource.userConfirmed);
      expect(result.attachment.capturedAt, isNull);
      expect(result.attachment.notes, contains('Supporting photo'));

      final reloaded = await repository.get('artwork-001');
      expect(reloaded!.primaryImageAttachmentId, 'primary-001');

      final attachments = await repository.attachmentsForArtwork('artwork-001');
      expect(attachments, hasLength(1));
      expect(attachments.single.role, AttachmentRole.supportingPhoto);
      expect(await attachmentStore.exists(attachments.single), isTrue);
    },
  );

  test(
    'imports an original PDF supporting document through the document picker',
    () async {
      final source = await _pdfFile(tempDir, 'receipt.pdf');
      documentPicker.results.add(
        XFile(source.path, name: 'receipt.pdf', mimeType: 'application/pdf'),
      );

      final result = await service().importSupportingDocument(
        artworkId: 'artwork-001',
        type: AttachmentType.receipt,
      );

      expect(result.attachment.type, AttachmentType.receipt);
      expect(result.attachment.role, AttachmentRole.supportingDocument);
      expect(
        result.attachment.lifecycleStatus,
        AttachmentLifecycleStatus.active,
      );
      expect(await attachmentStore.exists(result.attachment), isTrue);
      expect(result.attachment.relativePath, isNot(contains('receipt.pdf')));
    },
  );

  test(
    'opens a verified document through the injected scoped viewer',
    () async {
      final source = await _pdfFile(tempDir, 'receipt.pdf');
      documentPicker.results.add(
        XFile(source.path, name: 'receipt.pdf', mimeType: 'application/pdf'),
      );
      final result = await service().importSupportingDocument(
        artworkId: 'artwork-001',
        type: AttachmentType.receipt,
      );

      await service().openSupportingDocument(result.attachment.id);

      expect(viewer.openedUris, hasLength(1));
      expect(viewer.openedUris.single.scheme, 'file');
      expect(viewer.openedUris.single.path, contains('payload.pdf'));
    },
  );

  test('keeps a verified document recoverable when its viewer fails', () async {
    final source = await _pdfFile(tempDir, 'receipt.pdf');
    documentPicker.results.add(
      XFile(source.path, name: 'receipt.pdf', mimeType: 'application/pdf'),
    );
    final result = await service().importSupportingDocument(
      artworkId: 'artwork-001',
      type: AttachmentType.receipt,
    );
    viewer.failure = const AttachmentViewerException('Viewer unavailable.');

    await expectLater(
      service().openSupportingDocument(result.attachment.id),
      throwsA(
        isA<ArtworkIntakeException>().having(
          (error) => error.failure,
          'failure',
          ArtworkIntakeFailure.pickerUnavailable,
        ),
      ),
    );

    expect(
      (await repository.getAttachment(result.attachment.id))!.lifecycleStatus,
      AttachmentLifecycleStatus.active,
    );
  });

  test('does not write a document when selection is cancelled', () async {
    documentPicker.results.add(null);

    await expectLater(
      service().importSupportingDocument(
        artworkId: 'artwork-001',
        type: AttachmentType.receipt,
      ),
      throwsA(
        isA<ArtworkIntakeException>().having(
          (error) => error.failure,
          'failure',
          ArtworkIntakeFailure.cancelled,
        ),
      ),
    );

    expect(await repository.attachmentsForArtwork('artwork-001'), isEmpty);
  });

  test(
    'rejects malformed document bytes without committing metadata or staging',
    () async {
      final source = File(p.join(tempDir.path, 'malformed.pdf'));
      await source.writeAsBytes(const [0x25, 0x50, 0x44, 0x46, 0x2d]);
      documentPicker.results.add(
        XFile(source.path, name: 'malformed.pdf', mimeType: 'application/pdf'),
      );

      await expectLater(
        service().importSupportingDocument(
          artworkId: 'artwork-001',
          type: AttachmentType.receipt,
        ),
        throwsA(
          isA<ArtworkIntakeException>().having(
            (error) => error.failure,
            'failure',
            ArtworkIntakeFailure.unsupportedFile,
          ),
        ),
      );

      expect(await repository.allAttachmentsForArtwork('artwork-001'), isEmpty);
      expect(
        await Directory(
          p.join(attachmentStore.storageRoot.path, '.staging'),
        ).exists(),
        isTrue,
      );
      expect(
        await Directory(
          p.join(attachmentStore.storageRoot.path, '.staging'),
        ).list().toList(),
        isEmpty,
      );
    },
  );

  test(
    'replaces and removes documents as soft lifecycle transitions',
    () async {
      final original = await _pdfFile(tempDir, 'original.pdf');
      final replacement = await _pdfFile(tempDir, 'replacement.pdf');
      documentPicker.results.addAll([
        XFile(original.path, name: 'original.pdf', mimeType: 'application/pdf'),
        XFile(
          replacement.path,
          name: 'replacement.pdf',
          mimeType: 'application/pdf',
        ),
      ]);
      final initial = await service().importSupportingDocument(
        artworkId: 'artwork-001',
        type: AttachmentType.receipt,
      );

      final updated = await service().replaceSupportingDocument(
        attachmentId: initial.attachment.id,
        type: AttachmentType.receipt,
      );
      final allAfterReplace = await repository.allAttachmentsForArtwork(
        'artwork-001',
      );
      final superseded = allAfterReplace.singleWhere(
        (attachment) => attachment.id == initial.attachment.id,
      );
      expect(superseded.lifecycleStatus, AttachmentLifecycleStatus.superseded);
      expect(superseded.supersededByAttachmentId, updated.attachment.id);
      expect(await attachmentStore.exists(superseded), isTrue);
      expect(
        await repository.attachmentsForArtwork('artwork-001'),
        hasLength(1),
      );

      await service().removeSupportingDocument(updated.attachment.id);
      final removed = await repository.getAttachment(updated.attachment.id);
      expect(removed!.lifecycleStatus, AttachmentLifecycleStatus.removed);
      expect(await attachmentStore.exists(removed), isTrue);
      expect(await repository.attachmentsForArtwork('artwork-001'), isEmpty);
    },
  );

  test(
    'marks a missing document unavailable without opening a viewer',
    () async {
      final source = await _pdfFile(tempDir, 'receipt.pdf');
      documentPicker.results.add(
        XFile(source.path, name: 'receipt.pdf', mimeType: 'application/pdf'),
      );
      final result = await service().importSupportingDocument(
        artworkId: 'artwork-001',
        type: AttachmentType.receipt,
      );
      await attachmentStore.fileFor(result.attachment).delete();

      await expectLater(
        service().openSupportingDocument(result.attachment.id),
        throwsA(
          isA<ArtworkIntakeException>().having(
            (error) => error.failure,
            'failure',
            ArtworkIntakeFailure.sourceUnavailable,
          ),
        ),
      );

      expect(viewer.openedUris, isEmpty);
      expect(
        (await repository.getAttachment(result.attachment.id))!.lifecycleStatus,
        AttachmentLifecycleStatus.unavailable,
      );
    },
  );

  test('captures a supporting photo with capturedAt metadata', () async {
    final source = await _imageFile(tempDir, 'back.jpg');
    picker.cameraResults.add(
      XFile(source.path, name: 'back.jpg', mimeType: 'image/jpeg'),
    );

    final result = await service().captureSupportingPhoto('artwork-001');

    expect(result.attachment.type, AttachmentType.photo);
    expect(result.attachment.role, AttachmentRole.supportingPhoto);
    expect(result.attachment.capturedAt, DateTime.utc(2026, 7, 5, 10));

    final reloaded = await repository.get('artwork-001');
    expect(reloaded!.primaryImageAttachmentId, 'primary-001');
  });

  test('reports cancelled import without writing an attachment', () async {
    picker.galleryResults.add(null);

    await expectLater(
      service().importSupportingPhoto('artwork-001'),
      throwsA(
        isA<ArtworkIntakeException>().having(
          (error) => error.failure,
          'failure',
          ArtworkIntakeFailure.cancelled,
        ),
      ),
    );

    final reloaded = await repository.get('artwork-001');
    expect(reloaded!.primaryImageAttachmentId, 'primary-001');
    expect(await repository.attachmentsForArtwork('artwork-001'), isEmpty);
  });

  test(
    'reports missing selected image without writing an attachment',
    () async {
      picker.galleryResults.add(
        XFile(
          p.join(tempDir.path, 'missing.png'),
          name: 'missing.png',
          mimeType: 'image/png',
        ),
      );

      await expectLater(
        service().importSupportingPhoto('artwork-001'),
        throwsA(
          isA<ArtworkIntakeException>().having(
            (error) => error.failure,
            'failure',
            ArtworkIntakeFailure.sourceUnavailable,
          ),
        ),
      );

      final reloaded = await repository.get('artwork-001');
      expect(reloaded!.primaryImageAttachmentId, 'primary-001');
      expect(await repository.attachmentsForArtwork('artwork-001'), isEmpty);
    },
  );
}

Future<File> _imageFile(Directory tempDir, String fileName) async {
  final file = File(p.join(tempDir.path, fileName));
  await file.writeAsBytes(
    fileName.toLowerCase().endsWith('.png') ? _pngBytes : _jpegBytes,
  );
  return file;
}

final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
);
const _jpegBytes = <int>[
  0xff,
  0xd8,
  0xff,
  0xe0,
  0x00,
  0x10,
  0x4a,
  0x46,
  0x49,
  0x46,
  0x00,
  0x01,
  0x01,
  0x00,
  0x00,
  0x01,
  0x00,
  0x01,
  0x00,
  0x00,
  0xff,
  0xc0,
  0x00,
  0x0b,
  0x08,
  0x00,
  0x01,
  0x00,
  0x01,
  0x01,
  0x01,
  0x11,
  0x00,
  0xff,
  0xda,
  0x00,
  0x08,
  0x01,
  0x01,
  0x00,
  0x00,
  0x3f,
  0x00,
  0x00,
  0xff,
  0xd9,
];
const _pdfBytes = <int>[
  0x25,
  0x50,
  0x44,
  0x46,
  0x2d,
  0x31,
  0x2e,
  0x34,
  0x0a,
  0x31,
  0x20,
  0x30,
  0x20,
  0x6f,
  0x62,
  0x6a,
  0x0a,
  0x3c,
  0x3c,
  0x3e,
  0x3e,
  0x0a,
  0x65,
  0x6e,
  0x64,
  0x6f,
  0x62,
  0x6a,
  0x0a,
  0x73,
  0x74,
  0x61,
  0x72,
  0x74,
  0x78,
  0x72,
  0x65,
  0x66,
  0x0a,
  0x30,
  0x0a,
  0x25,
  0x25,
  0x45,
  0x4f,
  0x46,
];

Future<File> _pdfFile(Directory tempDir, String fileName) async {
  final file = File(p.join(tempDir.path, fileName));
  await file.writeAsBytes(_pdfBytes);
  return file;
}

class _FakeSupportingDocumentPicker implements SupportingDocumentPicker {
  final results = <XFile?>[];

  @override
  Future<XFile?> pickDocument() async => results.removeAt(0);
}

class _FakeAttachmentViewer implements AttachmentViewerGateway {
  final openedUris = <Uri>[];
  AttachmentViewerException? failure;

  @override
  Future<void> open({required Uri scopedUri, required String mimeType}) async {
    final failure = this.failure;
    if (failure != null) {
      throw failure;
    }
    openedUris.add(scopedUri);
  }
}

ArtworkRecord _record(String id) {
  return ArtworkRecord(
    id: id,
    recordState: ArtworkRecordState.verifiedByYou,
    primaryImageAttachmentId: 'primary-001',
    createdAt: DateTime.utc(2026, 7, 5, 9),
    updatedAt: DateTime.utc(2026, 7, 5, 9),
    fields: const {
      ArtworkFieldKeys.title: ArtworkFieldValue(
        value: 'Supporting Fixture',
        source: ArtworkFieldSource.userConfirmed,
        note: 'Confirmed in test.',
      ),
    },
  );
}

class _FakeArtworkImagePicker implements ArtworkImagePicker {
  final galleryResults = <XFile?>[];
  final cameraResults = <XFile?>[];

  @override
  Future<XFile?> pick(ArtworkImagePickMode mode) async {
    final queue = mode == ArtworkImagePickMode.gallery
        ? galleryResults
        : cameraResults;
    return queue.isEmpty ? null : queue.removeAt(0);
  }

  @override
  Future<XFile?> retrieveLostImage() async => null;
}
