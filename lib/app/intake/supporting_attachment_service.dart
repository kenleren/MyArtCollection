import 'dart:io';

import 'package:image_picker/image_picker.dart';

import '../storage/attachment_record.dart';
import '../storage/artwork_record.dart';
import '../storage/local_artwork_repository.dart';
import '../storage/local_attachment_store.dart';
import 'artwork_intake_service.dart';
import 'artwork_image_picker.dart';

class SupportingAttachmentResult {
  const SupportingAttachmentResult({
    required this.record,
    required this.attachment,
  });

  final ArtworkRecord record;
  final AttachmentRecord attachment;
}

class SupportingAttachmentService {
  SupportingAttachmentService({
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

  Future<SupportingAttachmentResult> importSupportingPhoto(
    String artworkId,
  ) async {
    final selected = await picker.pick(ArtworkImagePickMode.gallery);
    return _savePickedPhoto(
      artworkId: artworkId,
      pickedFile: selected,
      capturedAt: null,
      emptyMessage: 'Supporting photo import was cancelled.',
    );
  }

  Future<SupportingAttachmentResult> captureSupportingPhoto(
    String artworkId,
  ) async {
    final selected = await picker.pick(ArtworkImagePickMode.camera);
    return _savePickedPhoto(
      artworkId: artworkId,
      pickedFile: selected,
      capturedAt: _now(),
      emptyMessage: 'Supporting photo capture was cancelled.',
    );
  }

  Future<SupportingAttachmentResult> _savePickedPhoto({
    required String artworkId,
    required XFile? pickedFile,
    required DateTime? capturedAt,
    required String emptyMessage,
  }) async {
    if (pickedFile == null) {
      throw ArtworkIntakeException(
        ArtworkIntakeFailure.cancelled,
        emptyMessage,
      );
    }

    final record = await repository.get(artworkId);
    if (record == null) {
      throw const ArtworkIntakeException(
        ArtworkIntakeFailure.sourceUnavailable,
        'The artwork record could not be found.',
      );
    }

    final now = _now();
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
        role: AttachmentRole.supportingPhoto,
        source: ArtworkFieldSource.userConfirmed,
        importedAt: now,
        capturedAt: capturedAt,
        notes:
            'Supporting photo added for labels, signatures, reverse-side details, condition, or other record evidence.',
      );

      await repository.addAttachment(attachment);

      return SupportingAttachmentResult(record: record, attachment: attachment);
    } on AttachmentImportException catch (error) {
      throw ArtworkIntakeException(switch (error.failure) {
        AttachmentImportFailure.sourceMissing =>
          ArtworkIntakeFailure.sourceUnavailable,
        AttachmentImportFailure.unsupportedMimeType =>
          ArtworkIntakeFailure.unsupportedFile,
        AttachmentImportFailure.fileTooLarge =>
          ArtworkIntakeFailure.fileTooLarge,
      }, error.message);
    } on ArtworkIntakeException {
      rethrow;
    } on Exception catch (error) {
      throw ArtworkIntakeException(
        ArtworkIntakeFailure.pickerUnavailable,
        'Could not finish the supporting photo intake: $error',
      );
    }
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
