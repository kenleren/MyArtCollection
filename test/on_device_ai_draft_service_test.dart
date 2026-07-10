import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:my_art_collection/app/ai/on_device_ai_draft_service.dart';
import 'package:my_art_collection/app/storage/ai_research_record.dart';
import 'package:my_art_collection/app/storage/artwork_record.dart';
import 'package:my_art_collection/app/storage/attachment_record.dart';
import 'package:my_art_collection/app/storage/local_artwork_repository.dart';
import 'package:my_art_collection/app/storage/local_attachment_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('maps unavailable native provider to fixed safe copy', () async {
    const privateNativeDiagnostic =
        '/data/user/0/app/files/Portrait of Ada.png native provider is not bundled';
    final service = OnDeviceAiDraftService(
      repository: repository,
      attachmentStore: attachmentStore,
      provider: const _UnavailableProvider(message: privateNativeDiagnostic),
      now: _clock(),
      idFactory: _fixedId('native-missing'),
    );

    final job = await service.createDraftForPrimaryImage(
      record: record,
      primaryImage: primaryImage,
    );

    expect(job.status, AiDraftJobStatus.unavailable);
    expect(job.errorMessage, contains('ON_DEVICE_AI_UNAVAILABLE'));
    expect(job.errorMessage, isNot(contains(privateNativeDiagnostic)));
    expect(job.visualSummary, isNull);
  });

  test(
    'persists downloadable state as not-ready without creating draft',
    () async {
      final service = OnDeviceAiDraftService(
        repository: repository,
        attachmentStore: attachmentStore,
        provider: const _UnavailableProvider(
          availability: OnDeviceAiAvailability.downloadable,
        ),
        now: _clock(),
        idFactory: _fixedId('downloadable'),
      );

      final job = await service.createDraftForPrimaryImage(
        record: record,
        primaryImage: primaryImage,
      );

      expect(job.status, AiDraftJobStatus.unavailable);
      expect(job.errorMessage, contains('downloadable'));
    },
  );

  test(
    'persists downloading state as not-ready without creating draft',
    () async {
      final service = OnDeviceAiDraftService(
        repository: repository,
        attachmentStore: attachmentStore,
        provider: const _UnavailableProvider(
          availability: OnDeviceAiAvailability.downloading,
        ),
        now: _clock(),
        idFactory: _fixedId('downloading'),
      );

      final job = await service.createDraftForPrimaryImage(
        record: record,
        primaryImage: primaryImage,
      );

      expect(job.status, AiDraftJobStatus.unavailable);
      expect(job.errorMessage, contains('downloading'));
    },
  );

  test('persists download-failed state as sanitized not-ready copy', () async {
    const privateDownloadDiagnostic =
        'AICore download failed for /data/user/0/app/files/private-image.png';
    final service = OnDeviceAiDraftService(
      repository: repository,
      attachmentStore: attachmentStore,
      provider: const _UnavailableProvider(
        availability: OnDeviceAiAvailability.downloadFailed,
        message: privateDownloadDiagnostic,
      ),
      now: _clock(),
      idFactory: _fixedId('download-failed'),
    );

    final job = await service.createDraftForPrimaryImage(
      record: record,
      primaryImage: primaryImage,
    );

    expect(job.status, AiDraftJobStatus.unavailable);
    expect(job.errorMessage, contains('ON_DEVICE_AI_DOWNLOAD_FAILED'));
    expect(job.errorMessage, isNot(contains(privateDownloadDiagnostic)));
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

  test(
    'stores a safe fixed error when available provider throws private text',
    () async {
      const privatePath =
          '/Users/kenleren/Private/Ken/MyArtCollection/private_files/artworks/artwork-001/Portrait of Ada.png';
      const privateTitle = 'Portrait of Ada with insurance note';
      const privateModelOutput =
          '{"visualSummary":"private model dump for Portrait of Ada"}';
      final service = OnDeviceAiDraftService(
        repository: repository,
        attachmentStore: attachmentStore,
        provider: const _ThrowingAvailableProvider(
          message: '$privatePath $privateTitle $privateModelOutput',
        ),
        now: _clock(),
        idFactory: _fixedId('private-error'),
      );

      final job = await service.createDraftForPrimaryImage(
        record: record,
        primaryImage: primaryImage,
      );

      expect(job.status, AiDraftJobStatus.failed);
      expect(job.errorMessage, contains('ON_DEVICE_AI_DRAFT_FAILED'));
      expect(job.errorMessage, contains('No photo was sent online'));
      expect(job.errorMessage, isNot(contains(privatePath)));
      expect(job.errorMessage, isNot(contains(privateTitle)));
      expect(job.errorMessage, isNot(contains(privateModelOutput)));

      final stored = await repository.getAiDraftJob('ai-draft-private-error');
      expect(stored, isNotNull);
      expect(stored!.errorMessage, job.errorMessage);
      final displayedBody = '${stored.errorMessage} You can continue manually.';
      expect(displayedBody, isNot(contains(privatePath)));
      expect(displayedBody, isNot(contains(privateTitle)));
      expect(displayedBody, isNot(contains(privateModelOutput)));
    },
  );

  test(
    'passes the app-private local image path to available provider',
    () async {
      final provider = _CapturingAvailableProvider(
        expectedPrivateRoot: attachmentStore.storageRoot.path,
      );
      final service = OnDeviceAiDraftService(
        repository: repository,
        attachmentStore: attachmentStore,
        provider: provider,
        now: _clock(),
        idFactory: _fixedId('private-path'),
      );

      final job = await service.createDraftForPrimaryImage(
        record: record,
        primaryImage: primaryImage,
      );

      expect(job.status, AiDraftJobStatus.completed);
      expect(provider.lastRequest, isNotNull);
      expect(
        p.isWithin(
          attachmentStore.storageRoot.path,
          provider.lastRequest!.primaryImagePath,
        ),
        isTrue,
      );
    },
  );

  test(
    'method-channel provider maps downloadable and downloading states',
    () async {
      final channel = MethodChannel(
        'my_art_collection_on_device_ai_test_${DateTime.now().microsecondsSinceEpoch}',
      );
      final provider = MethodChannelOnDeviceAiDraftProvider(
        channel: channel,
        isEnabled: true,
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final statuses = <String>['downloadable', 'downloading'];
      var index = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'checkAvailability');
        return <String, Object?>{
          'availability': statuses[index++],
          'deviceModel': 'Pixel test device',
          'message': 'native status ${statuses[index - 1]}',
        };
      });

      final downloadable = await provider.checkAvailability();
      final downloading = await provider.checkAvailability();

      expect(downloadable.availability, OnDeviceAiAvailability.downloadable);
      expect(downloading.availability, OnDeviceAiAvailability.downloading);
      expect(downloadable.canRunDraft, isFalse);
      expect(downloading.canRunDraft, isFalse);
    },
  );

  test('method-channel createDraft sends only primary image path', () async {
    final channel = MethodChannel(
      'my_art_collection_on_device_ai_test_${DateTime.now().microsecondsSinceEpoch}',
    );
    final provider = MethodChannelOnDeviceAiDraftProvider(
      channel: channel,
      isEnabled: true,
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const privateImagePath = '/app-private/artworks/artwork-001/source.png';
    Object? outboundArguments;

    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'createDraft');
      outboundArguments = call.arguments;
      return <String, Object?>{
        'visualSummary': 'Local-only draft.',
        'searchTerms': <String>['local draft'],
      };
    });

    final draft = await provider.createDraft(
      const OnDeviceAiDraftRequest(primaryImagePath: privateImagePath),
    );

    expect(draft.visualSummary, 'Local-only draft.');
    expect(outboundArguments, isA<Map<Object?, Object?>>());
    final outboundMap = Map<Object?, Object?>.from(
      outboundArguments! as Map<Object?, Object?>,
    );
    expect(
      outboundMap,
      equals(<Object?, Object?>{'primaryImagePath': privateImagePath}),
    );
    expect(outboundMap.containsKey('artworkId'), isFalse);
    expect(outboundMap.containsKey('primaryImageAttachmentId'), isFalse);
  });

  test('method-channel downloadModel maps download-failed state', () async {
    final channel = MethodChannel(
      'my_art_collection_on_device_ai_test_${DateTime.now().microsecondsSinceEpoch}',
    );
    final provider = MethodChannelOnDeviceAiDraftProvider(
      channel: channel,
      isEnabled: true,
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'downloadModel');
      return <String, Object?>{
        'availability': 'download_failed',
        'deviceModel': 'Pixel test device',
        'message': 'native status download_failed',
      };
    });

    final capability = await provider.downloadModel();

    expect(capability.availability, OnDeviceAiAvailability.downloadFailed);
    expect(capability.canRunDraft, isFalse);
    expect(capability.canStartDownload, isTrue);
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

class _UnavailableProvider implements OnDeviceAiDraftProvider {
  const _UnavailableProvider({
    this.availability = OnDeviceAiAvailability.unavailable,
    this.message,
  });

  final OnDeviceAiAvailability availability;
  final String? message;

  @override
  Future<OnDeviceAiCapability> checkAvailability() async {
    return OnDeviceAiCapability(
      availability: availability,
      deviceModel: 'Pixel not-ready device',
      message: message,
    );
  }

  @override
  Future<OnDeviceAiCapability> downloadModel() async {
    return checkAvailability();
  }

  @override
  Future<OnDeviceAiDraftResult> createDraft(OnDeviceAiDraftRequest request) {
    throw StateError('createDraft must not run when status is $availability');
  }
}

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
  Future<OnDeviceAiCapability> downloadModel() async {
    return checkAvailability();
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

class _ThrowingAvailableProvider implements OnDeviceAiDraftProvider {
  const _ThrowingAvailableProvider({required this.message});

  final String message;

  @override
  Future<OnDeviceAiCapability> checkAvailability() async {
    return const OnDeviceAiCapability(
      availability: OnDeviceAiAvailability.available,
      deviceModel: 'Pixel local-only device',
    );
  }

  @override
  Future<OnDeviceAiCapability> downloadModel() async {
    return checkAvailability();
  }

  @override
  Future<OnDeviceAiDraftResult> createDraft(OnDeviceAiDraftRequest request) {
    throw PlatformException(
      code: 'NATIVE_PRIVATE_DIAGNOSTIC',
      message: message,
      details: <String, Object?>{
        'primaryImagePath': request.primaryImagePath,
        'modelOutput': message,
      },
    );
  }
}

class _CapturingAvailableProvider implements OnDeviceAiDraftProvider {
  _CapturingAvailableProvider({required this.expectedPrivateRoot});

  final String expectedPrivateRoot;
  OnDeviceAiDraftRequest? lastRequest;

  @override
  Future<OnDeviceAiCapability> checkAvailability() async {
    return const OnDeviceAiCapability(
      availability: OnDeviceAiAvailability.available,
      deviceModel: 'Pixel local-only device',
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
    lastRequest = request;
    expect(p.isWithin(expectedPrivateRoot, request.primaryImagePath), isTrue);
    return const OnDeviceAiDraftResult(
      visualSummary: 'Local-only image analysis draft.',
    );
  }
}

final _tinyPngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAACXBIWXMAAAABAAAAAQBPJcTWAAAADklEQVR4nGNkAAMWCAUAADgABkRoBWYAAAAASUVORK5CYII=',
);
