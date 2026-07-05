import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:my_art_collection/app/intake/artwork_image_picker.dart';
import 'package:my_art_collection/app/intake/artwork_intake_service.dart';
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
  await file.writeAsBytes([1, 2, 3, 4]);
  return file;
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
