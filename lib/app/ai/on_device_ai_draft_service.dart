import 'package:flutter/services.dart';

import '../storage/ai_research_record.dart';
import '../storage/attachment_record.dart';
import '../storage/artwork_record.dart';
import '../storage/local_artwork_repository.dart';
import '../storage/local_attachment_store.dart';

enum OnDeviceAiAvailability {
  disabled('disabled'),
  available('available'),
  downloadable('downloadable'),
  unavailable('unavailable');

  const OnDeviceAiAvailability(this.storageValue);

  final String storageValue;

  static OnDeviceAiAvailability fromStorage(String value) {
    return OnDeviceAiAvailability.values.firstWhere(
      (availability) => availability.storageValue == value,
      orElse: () => OnDeviceAiAvailability.unavailable,
    );
  }
}

class OnDeviceAiCapability {
  const OnDeviceAiCapability({
    required this.availability,
    this.deviceModel,
    this.message,
  });

  final OnDeviceAiAvailability availability;
  final String? deviceModel;
  final String? message;

  bool get canRunDraft => availability == OnDeviceAiAvailability.available;
}

class OnDeviceAiDraftRequest {
  const OnDeviceAiDraftRequest({
    required this.artworkId,
    required this.primaryImagePath,
    required this.primaryImageAttachmentId,
  });

  final String artworkId;
  final String primaryImagePath;
  final String primaryImageAttachmentId;
}

class OnDeviceAiDraftResult {
  const OnDeviceAiDraftResult({
    this.visualSummary,
    this.signatureNotes,
    this.subjectMatter,
    this.mediumHint,
    this.stylePeriodHint,
    this.conditionNotes,
    this.searchTerms = const [],
  });

  final String? visualSummary;
  final String? signatureNotes;
  final String? subjectMatter;
  final String? mediumHint;
  final String? stylePeriodHint;
  final String? conditionNotes;
  final List<String> searchTerms;
}

abstract interface class OnDeviceAiDraftProvider {
  Future<OnDeviceAiCapability> checkAvailability();

  Future<OnDeviceAiDraftResult> createDraft(OnDeviceAiDraftRequest request);
}

class DisabledOnDeviceAiDraftProvider implements OnDeviceAiDraftProvider {
  const DisabledOnDeviceAiDraftProvider();

  @override
  Future<OnDeviceAiCapability> checkAvailability() async {
    return const OnDeviceAiCapability(
      availability: OnDeviceAiAvailability.disabled,
      message: 'On-device AI is disabled for this build.',
    );
  }

  @override
  Future<OnDeviceAiDraftResult> createDraft(OnDeviceAiDraftRequest request) {
    throw const OnDeviceAiUnavailableException(
      'On-device AI is disabled for this build.',
    );
  }
}

class MethodChannelOnDeviceAiDraftProvider implements OnDeviceAiDraftProvider {
  MethodChannelOnDeviceAiDraftProvider({
    MethodChannel? channel,
    this.isEnabled = const bool.fromEnvironment('MY_ART_ON_DEVICE_AI_ENABLED'),
  }) : _channel =
           channel ??
           const MethodChannel('com.kenleren.my_art_collection/on_device_ai');

  final MethodChannel _channel;
  final bool isEnabled;

  @override
  Future<OnDeviceAiCapability> checkAvailability() async {
    if (!isEnabled) {
      return const DisabledOnDeviceAiDraftProvider().checkAvailability();
    }

    final response = await _channel.invokeMapMethod<String, Object?>(
      'checkAvailability',
    );
    return _capabilityFromMap(response);
  }

  @override
  Future<OnDeviceAiDraftResult> createDraft(
    OnDeviceAiDraftRequest request,
  ) async {
    if (!isEnabled) {
      return const DisabledOnDeviceAiDraftProvider().createDraft(request);
    }

    final response = await _channel
        .invokeMapMethod<String, Object?>('createDraft', {
          'artworkId': request.artworkId,
          'primaryImagePath': request.primaryImagePath,
          'primaryImageAttachmentId': request.primaryImageAttachmentId,
        });
    return _draftResultFromMap(response);
  }

  static OnDeviceAiCapability _capabilityFromMap(
    Map<String, Object?>? response,
  ) {
    final availability = OnDeviceAiAvailability.fromStorage(
      response?['availability']?.toString() ?? 'unavailable',
    );
    return OnDeviceAiCapability(
      availability: availability,
      deviceModel: response?['deviceModel']?.toString(),
      message: response?['message']?.toString(),
    );
  }

  static OnDeviceAiDraftResult _draftResultFromMap(
    Map<String, Object?>? response,
  ) {
    final rawSearchTerms = response?['searchTerms'];
    final searchTerms = rawSearchTerms is List
        ? rawSearchTerms.map((value) => value.toString()).toList()
        : const <String>[];

    return OnDeviceAiDraftResult(
      visualSummary: response?['visualSummary']?.toString(),
      signatureNotes: response?['signatureNotes']?.toString(),
      subjectMatter: response?['subjectMatter']?.toString(),
      mediumHint: response?['mediumHint']?.toString(),
      stylePeriodHint: response?['stylePeriodHint']?.toString(),
      conditionNotes: response?['conditionNotes']?.toString(),
      searchTerms: searchTerms,
    );
  }
}

class OnDeviceAiDraftService {
  OnDeviceAiDraftService({
    required this.repository,
    required this.attachmentStore,
    required this.provider,
    DateTime Function()? now,
    String Function()? idFactory,
  }) : _now = now ?? DateTime.now,
       _idFactory = idFactory ?? _timestampId;

  static const promptVersion = 'on-device-artwork-draft-v1';

  final LocalArtworkRepository repository;
  final LocalAttachmentStore attachmentStore;
  final OnDeviceAiDraftProvider provider;
  final DateTime Function() _now;
  final String Function() _idFactory;

  Future<AiDraftJob> createDraftForPrimaryImage({
    required ArtworkRecord record,
    required AttachmentRecord primaryImage,
  }) async {
    final startedAt = _now();
    final jobId = 'ai-draft-${_idFactory()}';

    Future<AiDraftJob> persist(AiDraftJob job) async {
      await repository.upsertAiDraftJob(job);
      return job;
    }

    try {
      final capability = await provider.checkAvailability();
      if (!capability.canRunDraft) {
        final now = _now();
        return persist(
          AiDraftJob(
            id: jobId,
            artworkId: record.id,
            primaryImageAttachmentId: primaryImage.id,
            status: AiDraftJobStatus.unavailable,
            createdAt: startedAt,
            updatedAt: now,
            deviceModel: capability.deviceModel,
            promptVersion: promptVersion,
            searchTerms: const [],
            errorMessage: _availabilityMessage(capability),
          ),
        );
      }

      final imageFile = attachmentStore.fileFor(primaryImage);
      final draft = await provider.createDraft(
        OnDeviceAiDraftRequest(
          artworkId: record.id,
          primaryImagePath: imageFile.path,
          primaryImageAttachmentId: primaryImage.id,
        ),
      );
      final completedAt = _now();

      return persist(
        AiDraftJob(
          id: jobId,
          artworkId: record.id,
          primaryImageAttachmentId: primaryImage.id,
          status: AiDraftJobStatus.completed,
          createdAt: startedAt,
          updatedAt: completedAt,
          completedAt: completedAt,
          deviceModel: capability.deviceModel,
          promptVersion: promptVersion,
          visualSummary: draft.visualSummary,
          signatureNotes: draft.signatureNotes,
          subjectMatter: draft.subjectMatter,
          mediumHint: draft.mediumHint,
          stylePeriodHint: draft.stylePeriodHint,
          conditionNotes: draft.conditionNotes,
          searchTerms: draft.searchTerms,
        ),
      );
    } on Exception catch (error) {
      final now = _now();
      return persist(
        AiDraftJob(
          id: jobId,
          artworkId: record.id,
          primaryImageAttachmentId: primaryImage.id,
          status: AiDraftJobStatus.failed,
          createdAt: startedAt,
          updatedAt: now,
          promptVersion: promptVersion,
          errorMessage: 'Private AI draft could not run: $error',
        ),
      );
    }
  }

  static String _availabilityMessage(OnDeviceAiCapability capability) {
    return switch (capability.availability) {
      OnDeviceAiAvailability.disabled =>
        capability.message ?? 'On-device AI is disabled for this build.',
      OnDeviceAiAvailability.downloadable =>
        capability.message ??
            'On-device AI support is downloadable but not ready yet.',
      OnDeviceAiAvailability.unavailable =>
        capability.message ??
            'On-device AI is not available on this device or build.',
      OnDeviceAiAvailability.available => capability.message ?? 'Available.',
    };
  }

  static String _timestampId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
}

class OnDeviceAiUnavailableException implements Exception {
  const OnDeviceAiUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}
