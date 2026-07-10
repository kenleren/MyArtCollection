import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:my_art_collection/app/intake/artwork_image_picker.dart';
import 'package:my_art_collection/app/intake/artwork_intake_service.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/attachment_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:my_art_collection/app/storage/local_attachment_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tempDir;
  late String databasePath;
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
      'my_art_collection_intake_test_',
    );
    databasePath = p.join(tempDir.path, 'records.db');
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(databasePath),
    );
    attachmentStore = await LocalAttachmentStore.openAt(
      Directory(p.join(tempDir.path, 'private_files')),
    );
    picker = _FakeArtworkImagePicker();
    idCounter = 0;
  });

  tearDown(() async {
    await repository.close();
    await tempDir.delete(recursive: true);
  });

  ArtworkIntakeService service() {
    return ArtworkIntakeService(
      picker: picker,
      repository: repository,
      attachmentStore: attachmentStore,
      now: () => DateTime.utc(2026, 7, 4, 12),
      idFactory: () => (++idCounter).toString().padLeft(3, '0'),
    );
  }

  test(
    'imports image into app-private storage and creates draft record',
    () async {
      final source = await _imageFile(tempDir, 'selected.jpg');
      picker.galleryResults.add(
        XFile(source.path, name: 'selected.jpg', mimeType: 'image/jpeg'),
      );

      final result = await service().importImage();

      expect(result.record.id, 'artwork-001');
      expect(result.primaryImage.id, 'attachment-002');
      expect(result.record.recordState, ArtworkRecordState.needsReview);
      expect(result.record.primaryImageAttachmentId, result.primaryImage.id);
      expect(
        result.record.field(ArtworkFieldKeys.title)?.value,
        'Untitled artwork',
      );
      expect(
        result.record.field(ArtworkFieldKeys.title)?.source,
        ArtworkFieldSource.unknown,
      );

      final reloaded = await repository.get(result.record.id);
      expect(reloaded, isNotNull);
      expect(reloaded!.primaryImageAttachmentId, result.primaryImage.id);

      await repository.close();
      repository = LocalArtworkRepository.forDatabase(
        await LocalArtworkRepository.openAt(databasePath),
      );

      final listedAfterRestart = await repository.list();
      expect(listedAfterRestart.single.id, result.record.id);
      expect(
        listedAfterRestart.single.primaryImageAttachmentId,
        result.primaryImage.id,
      );

      final attachments = await repository.attachmentsForArtwork(
        result.record.id,
      );
      expect(attachments, hasLength(1));
      expect(attachments.single.type, AttachmentType.photo);
      expect(attachments.single.role, AttachmentRole.primaryArtworkPhoto);
      expect(await attachmentStore.exists(attachments.single), isTrue);
      expect(attachments.single.relativePath, isNot(contains('selected')));
    },
  );

  test('reports cancelled import without creating a record', () async {
    picker.galleryResults.add(null);

    await expectLater(
      service().importImage(),
      throwsA(
        isA<ArtworkIntakeException>().having(
          (error) => error.failure,
          'failure',
          ArtworkIntakeFailure.cancelled,
        ),
      ),
    );
    expect(await repository.list(), isEmpty);
  });

  test('reports missing selected image without creating a record', () async {
    picker.galleryResults.add(
      XFile(
        p.join(tempDir.path, 'missing.jpg'),
        name: 'missing.jpg',
        mimeType: 'image/jpeg',
      ),
    );

    await expectLater(
      service().importImage(),
      throwsA(
        isA<ArtworkIntakeException>().having(
          (error) => error.failure,
          'failure',
          ArtworkIntakeFailure.sourceUnavailable,
        ),
      ),
    );
    expect(await repository.list(), isEmpty);
  });

  test('recovers lost image into a local draft', () async {
    final source = await _imageFile(tempDir, 'lost.png');
    picker.lostImage = XFile(
      source.path,
      name: 'lost.png',
      mimeType: 'image/png',
    );

    final result = await service().recoverLostImage();

    expect(result, isNotNull);
    expect(result!.wasRecovered, isTrue);
    expect(result.record.primaryImageAttachmentId, result.primaryImage.id);
    expect(result.primaryImage.notes, contains('Recovered'));
  });
}

Future<File> _imageFile(Directory tempDir, String fileName) async {
  final file = File(p.join(tempDir.path, fileName));
  await file.writeAsBytes(
    fileName.toLowerCase().endsWith('.png') ? _pngBytes : _jpegBytes,
  );
  return file;
}

final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAACXBIWXMAAAABAAAAAQBPJcTWAAAADklEQVR4nGNkAAMWCAUAADgABkRoBWYAAAAASUVORK5CYII=',
);
final _jpegBytes = base64Decode(
  '/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYyLjI4LjEwMQD/2wBDAAgEBAQEBAUFBQUFBQYGBgYGBgYGBgYGBgYHBwcICAgHBwcGBgcHCAgICAkJCQgICAgJCQoKCgwMCwsODg4RERT/xABLAAEBAAAAAAAAAAAAAAAAAAAACAEBAAAAAAAAAAAAAAAAAAAAABABAAAAAAAAAAAAAAAAAAAAABEBAAAAAAAAAAAAAAAAAAAAAP/AABEIAAIAAgMBIgACEQADEQD/2gAMAwEAAhEDEQA/AJ/AB//Z',
);

class _FakeArtworkImagePicker implements ArtworkImagePicker {
  final galleryResults = <XFile?>[];
  final cameraResults = <XFile?>[];
  XFile? lostImage;

  @override
  Future<XFile?> pick(ArtworkImagePickMode mode) async {
    final queue = mode == ArtworkImagePickMode.gallery
        ? galleryResults
        : cameraResults;
    return queue.isEmpty ? null : queue.removeAt(0);
  }

  @override
  Future<XFile?> retrieveLostImage() async => lostImage;
}
