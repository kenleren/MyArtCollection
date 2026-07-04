import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:my_art_collection/app/ai/on_device_ai_draft_service.dart';
import 'package:my_art_collection/app/storage/ai_research_record.dart';
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
  late ArtworkRecord record;
  late AttachmentRecord primaryImage;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'my_art_collection_on_device_ai_test_',
    );
    repository = LocalArtworkRepository.forDatabase(
      await LocalArtworkRepository.openAt(p.join(tempDir.path, 'records.db')),
    );
    attachmentStore = await LocalAttachmentStore.openAt(
      Directory(p.join(tempDir.path, 'private_files')),
    );

    record = _record();
    await repository.upsert(record);
    primaryImage = await _primaryImage(
      tempDir: tempDir,
      attachmentStore: attachmentStore,
    );
    await repository.addAttachment(primaryImage);
  });

  tearDown(() async {
    await repository.close();
    await tempDir.delete(recursive: true);
  });

  test('persists unavailable job when on-device AI is disabled', () async {
    final service = OnDeviceAiDraftService(
      repository: repository,
      attachmentStore: attachmentStore,
      provider: const DisabledOnDeviceAiDraftProvider(),
      now: _clock(),
      idFactory: _fixedId('disabled'),
    );

    final job = await service.createDraftForPrimaryImage(
      record: record,
      primaryImage: primaryImage,
    );

    expect(job.status, AiDraftJobStatus.unavailable);
    expect(job.errorMessage, contains('disabled'));

    final stored = await repository.getAiDraftJob('ai-draft-disabled');
    expect(stored, isNotNull);
    expect(stored!.status, AiDraftJobStatus.unavailable);

    final artwork = await repository.get(record.id);
    expect(
      artwork!.field(ArtworkFieldKeys.title)!.source,
      ArtworkFieldSource.aiSuggested,
    );
  });

  test('persists completed private draft without confirming fields', () async {
    final service = OnDeviceAiDraftService(
      repository: repository,
      attachmentStore: attachmentStore,
      provider: const _AvailableFakeProvider(),
      now: _clock(),
      idFactory: _fixedId('completed'),
    );

    final job = await service.createDraftForPrimaryImage(
      record: record,
      primaryImage: primaryImage,
    );

    expect(job.status, AiDraftJobStatus.completed);
    expect(job.visualSummary, contains('framed print'));
    expect(job.signatureNotes, contains('J. Example'));
    expect(job.searchTerms, contains('J. Example framed print'));

    final stored = await repository.getAiDraftJob('ai-draft-completed');
    expect(stored, isNotNull);
    expect(stored!.status, AiDraftJobStatus.completed);
    expect(stored.mediumHint, 'Print on paper');

    final artwork = await repository.get(record.id);
    expect(
      artwork!.field(ArtworkFieldKeys.title)!.source,
      ArtworkFieldSource.aiSuggested,
    );
    expect(
      artwork.field(ArtworkFieldKeys.artist)!.source,
      ArtworkFieldSource.unknown,
    );
  });
}

ArtworkRecord _record() {
  final now = DateTime.utc(2026, 7, 4, 12);
  return ArtworkRecord(
    id: 'artwork-001',
    recordState: ArtworkRecordState.needsReview,
    primaryImageAttachmentId: 'primary-image',
    createdAt: now,
    updatedAt: now,
    fields: const {
      ArtworkFieldKeys.title: ArtworkFieldValue(
        value: 'Untitled artwork',
        source: ArtworkFieldSource.aiSuggested,
        note: 'Draft title placeholder.',
      ),
      ArtworkFieldKeys.artist: ArtworkFieldValue(
        value: 'Unknown',
        source: ArtworkFieldSource.unknown,
        note: 'Add the artist when known.',
      ),
    },
  );
}

Future<AttachmentRecord> _primaryImage({
  required Directory tempDir,
  required LocalAttachmentStore attachmentStore,
}) async {
  final source = File(p.join(tempDir.path, 'source.png'));
  await source.writeAsBytes(_tinyPngBytes);
  return attachmentStore.saveImportedAttachment(
    artworkId: 'artwork-001',
    attachmentId: 'primary-image',
    sourceFile: source,
    originalFileName: 'source.png',
    mimeType: 'image/png',
    type: AttachmentType.photo,
    source: ArtworkFieldSource.userConfirmed,
    importedAt: DateTime.utc(2026, 7, 4, 12),
  );
}

DateTime Function() _clock() {
  var tick = 0;
  return () => DateTime.utc(2026, 7, 4, 12, tick++);
}

String Function() _fixedId(String id) =>
    () => id;

class _AvailableFakeProvider implements OnDeviceAiDraftProvider {
  const _AvailableFakeProvider();

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
    expect(request.primaryImagePath, endsWith('.png'));
    return const OnDeviceAiDraftResult(
      visualSummary: 'A framed print with a visible lower-right signature.',
      signatureNotes: 'May read J. Example.',
      subjectMatter: 'Abstract interior',
      mediumHint: 'Print on paper',
      conditionNotes: 'No obvious tears visible in the photo.',
      searchTerms: ['J. Example framed print'],
    );
  }
}

final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=',
);
