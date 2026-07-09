import 'dart:io';

import 'package:image_picker/image_picker.dart';

import '../storage/attachment_record.dart';
import '../storage/artwork_record.dart';
import '../storage/local_artwork_repository.dart';
import '../storage/local_attachment_store.dart';
import 'artwork_image_picker.dart';

enum ArtworkIntakeFailure {
  cancelled,
  sourceUnavailable,
  unsupportedFile,
  fileTooLarge,
  pickerUnavailable,
}

class ArtworkIntakeException implements Exception {
  const ArtworkIntakeException(this.failure, this.message);

  final ArtworkIntakeFailure failure;
  final String message;

  @override
  String toString() => message;
}

class ArtworkIntakeResult {
  const ArtworkIntakeResult({
    required this.record,
    required this.primaryImage,
    required this.wasRecovered,
  });

  final ArtworkRecord record;
  final AttachmentRecord primaryImage;
  final bool wasRecovered;
}

class ArtworkIntakeService {
  ArtworkIntakeService({
    required this.picker,
    required this.repository,
    required this.attachmentStore,
    DateTime Function()? now,
    String Function()? idFactory,
  }) : _now = now ?? DateTime.now,
       _idFactory = idFactory ?? _timestampId;

  final ArtworkImagePicker picker;
  final LocalArtworkRepository repository;
  final LocalAttachmentStore attachmentStore;
  final DateTime Function() _now;
  final String Function() _idFactory;

  Future<ArtworkIntakeResult> importImage() async {
    final selected = await picker.pick(ArtworkImagePickMode.gallery);
    return _savePickedImage(
      selected,
      capturedAt: null,
      wasRecovered: false,
      emptyMessage: 'Photo import was cancelled.',
    );
  }

  Future<ArtworkIntakeResult> captureImage() async {
    final selected = await picker.pick(ArtworkImagePickMode.camera);
    final capturedAt = _now();
    return _savePickedImage(
      selected,
      capturedAt: capturedAt,
      wasRecovered: false,
      emptyMessage: 'Camera capture was cancelled.',
    );
  }

  Future<ArtworkIntakeResult?> recoverLostImage() async {
    final recovered = await picker.retrieveLostImage();
    if (recovered == null) {
      return null;
    }
    return _savePickedImage(
      recovered,
      capturedAt: null,
      wasRecovered: true,
      emptyMessage: 'No previous import was found.',
    );
  }

  Future<ArtworkIntakeResult> _savePickedImage(
    XFile? pickedFile, {
    required DateTime? capturedAt,
    required bool wasRecovered,
    required String emptyMessage,
  }) async {
    if (pickedFile == null) {
      throw ArtworkIntakeException(
        ArtworkIntakeFailure.cancelled,
        emptyMessage,
      );
    }

    final now = _now();
    final artworkId = 'artwork-${_idFactory()}';
    final attachmentId = 'attachment-${_idFactory()}';
    final mimeType = pickedFile.mimeType ?? _mimeTypeForPath(pickedFile.path);

    try {
      final attachment = await attachmentStore.saveImportedAttachment(
        artworkId: artworkId,
        attachmentId: attachmentId,
        sourceFile: File(pickedFile.path),
        originalFileName: pickedFile.name,
        mimeType: mimeType,
        type: AttachmentType.photo,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: now,
        capturedAt: capturedAt,
        notes: wasRecovered
            ? 'Recovered after Android interrupted the picker flow.'
            : 'Primary image selected on this device.',
      );

      final record = _draftRecord(
        artworkId: artworkId,
        primaryImageAttachmentId: attachment.id,
        now: now,
      );

      await repository.upsert(record);
      await repository.addAttachment(attachment);

      return ArtworkIntakeResult(
        record: record,
        primaryImage: attachment,
        wasRecovered: wasRecovered,
      );
    } on AttachmentImportException catch (error) {
      throw ArtworkIntakeException(switch (error.failure) {
        AttachmentImportFailure.sourceMissing =>
          ArtworkIntakeFailure.sourceUnavailable,
        AttachmentImportFailure.unsupportedMimeType =>
          ArtworkIntakeFailure.unsupportedFile,
        AttachmentImportFailure.fileTooLarge =>
          ArtworkIntakeFailure.fileTooLarge,
      }, error.message);
    } on Exception catch (error) {
      throw ArtworkIntakeException(
        ArtworkIntakeFailure.pickerUnavailable,
        'Could not finish the photo intake: $error',
      );
    }
  }

  ArtworkRecord _draftRecord({
    required String artworkId,
    required String primaryImageAttachmentId,
    required DateTime now,
  }) {
    return ArtworkRecord(
      id: artworkId,
      recordState: ArtworkRecordState.needsReview,
      primaryImageAttachmentId: primaryImageAttachmentId,
      createdAt: now,
      updatedAt: now,
      fields: const {
        ArtworkFieldKeys.title: ArtworkFieldValue(
          value: 'Untitled artwork',
          source: ArtworkFieldSource.unknown,
          note: 'Local draft. Confirm or edit after review.',
        ),
        ArtworkFieldKeys.artist: ArtworkFieldValue(
          value: 'Unknown',
          source: ArtworkFieldSource.unknown,
          note: 'Add the artist when known.',
        ),
        ArtworkFieldKeys.conditionNotes: ArtworkFieldValue(
          value: 'Needs review',
          source: ArtworkFieldSource.unknown,
          note: 'Review the image before using this in a report.',
        ),
      },
    );
  }

  static String _mimeTypeForPath(String path) {
    final lowerPath = path.toLowerCase();
    if (lowerPath.endsWith('.png')) {
      return 'image/png';
    }
    if (lowerPath.endsWith('.heic')) {
      return 'image/heic';
    }
    if (lowerPath.endsWith('.heif')) {
      return 'image/heif';
    }
    return 'image/jpeg';
  }

  static String _timestampId() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
}
